//! The other half of the pair: `locket` and `locket-app` are installed side
//! by side (scripts/install-local.sh and the install scripts put both in
//! one folder; the Windows installer too), and they must move together, as
//! a newer one may write a vault format the older can't read. So each
//! updater updates its sibling as well: the app updates the `locket` next
//! to it, `locket update` the `locket-app` next to it.
//!
//! Only a sibling Locket may replace: in the same folder, not a package's
//! (deb/rpm, under /usr or /opt: the package manager updates both), and on
//! Linux the app only when it's an AppImage. macOS is left alone: the CLI
//! ships inside the .app and is updated with it.
//!
//! Every download is checked like a self-update: the signed manifest
//! (latest.json, latest-cli.json) and the file's SHA-256.
//! @atlas layer: front

const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");

pub const Kind = enum {
    cli,
    app,

    pub fn appId(k: Kind) []const u8 {
        return switch (k) {
            .cli => "com.foreachdeveloper.locket.cli",
            .app => "com.foreachdeveloper.locket",
        };
    }

    pub fn manifestUrl(k: Kind) []const u8 {
        return switch (k) {
            .cli => "https://github.com/highercomve/locket/releases/latest/download/latest-cli.json",
            .app => "https://github.com/highercomve/locket/releases/latest/download/latest.json",
        };
    }

    /// The program's file name.
    pub fn fileName(k: Kind) []const u8 {
        const exe = if (builtin.os.tag == .windows) ".exe" else "";
        return switch (k) {
            .cli => "locket" ++ exe,
            .app => "locket-app" ++ exe,
        };
    }
};

/// The sibling `kind` next to `self_path` (this program's file: the
/// AppImage, the exe), resolved, when it's there and Locket may replace it;
/// null otherwise. Caller frees.
pub fn find(io: std.Io, gpa: std.mem.Allocator, kind: Kind, self_path: []const u8) ?[:0]u8 {
    if (builtin.os.tag == .macos) return null;
    const dir = std.fs.path.dirname(self_path) orelse return null;
    const path = std.fs.path.join(gpa, &.{ dir, kind.fileName() }) catch return null;
    defer gpa.free(path);
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch return null;
    if (!replaceable(real) or (builtin.os.tag == .linux and kind == .app and !isAppImage(io, real))) {
        gpa.free(real);
        return null;
    }
    return real;
}

/// Not a package's file (the package manager updates those).
fn replaceable(path: []const u8) bool {
    if (builtin.os.tag == .windows) return true;
    return !std.mem.startsWith(u8, path, "/usr/") and !std.mem.startsWith(u8, path, "/opt/");
}

/// An AppImage (type 2): "AI\x02" at byte 8 of the ELF header.
pub fn isAppImage(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var head: [12]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return false;
    return n == head.len and std.mem.eql(u8, head[0..4], "\x7fELF") and std.mem.eql(u8, head[8..11], "AI\x02");
}

/// The version a `locket` binary reports (`locket version`), or null.
/// Caller frees.
pub fn cliVersion(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const r = std.process.run(gpa, io, .{
        .argv = &.{ path, "version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) return null;
    const v = parseVersion(r.stdout) orelse return null;
    return gpa.dupe(u8, v) catch null;
}

/// `locket 0.2.0 (abc123)` -> `0.2.0`.
fn parseVersion(out: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
    const name = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "locket")) return null;
    const v = it.next() orelse return null;
    _ = std.SemanticVersion.parse(v) catch return null;
    return v;
}

/// Checking and installing a sibling with Oriel's updater engine: the
/// CLI's `oriel_updater` module, or the app's `oriel.updater` (one engine,
/// imported the way each program has it).
pub fn Updater(comptime core: type) type {
    return struct {
        pub const Update = core.Update;

        /// The signed release of `kind` newer than `current`, or null.
        pub fn check(io: std.Io, gpa: std.mem.Allocator, kind: Kind, current: []const u8) !?core.Update {
            return core.checkForUpdate(io, gpa, .{
                .app_id = kind.appId(),
                .manifest_url = kind.manifestUrl(),
                .current_version = current,
                .public_key_b64 = build_info.update_public_key,
            });
        }

        /// Downloads, verifies and installs `update` over `path`.
        pub fn install(io: std.Io, gpa: std.mem.Allocator, update: core.Update, path: []const u8) !void {
            const dest = try core.download(io, gpa, update, .{ .dest_path = path });
            gpa.free(dest);
        }
    };
}

test parseVersion {
    try std.testing.expectEqualStrings("0.2.0", parseVersion("locket 0.2.0 (abc1234)\n").?);
    try std.testing.expect(parseVersion("something else 1.0.0") == null);
    try std.testing.expect(parseVersion("locket nonsense") == null);
}

test cliVersion {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "locket", .data = "#!/bin/sh\necho 'locket 0.0.9 (abc1234)'\n", .flags = .{ .permissions = .fromMode(0o755) } });
    var path_buf: [128]u8 = undefined;
    const dir = try std.Io.Dir.cwd().realPathFileAlloc(t.io, try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}), t.allocator);
    defer t.allocator.free(dir);
    const path = try std.fs.path.join(t.allocator, &.{ dir, "locket" });
    defer t.allocator.free(path);
    const v = cliVersion(t.io, t.allocator, path).?;
    defer t.allocator.free(v);
    try t.expectEqualStrings("0.0.9", v);
    try t.expect(cliVersion(t.io, t.allocator, "/nonexistent/locket") == null);
}

test find {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.allocator;
    var path_buf: [128]u8 = undefined;
    const dir = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    defer a.free(dir);
    const self_path = try std.fs.path.join(a, &.{ dir, "locket" });
    defer a.free(self_path);
    // No app next to it; then a plain ELF that isn't an AppImage; then one.
    try t.expect(find(io, a, .app, self_path) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "locket-app", .data = "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00" });
    try t.expect(find(io, a, .app, self_path) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "locket-app", .data = "\x7fELF\x02\x01\x01\x00AI\x02\x00" });
    const app = find(io, a, .app, self_path).?;
    defer a.free(app);
    try t.expect(std.mem.endsWith(u8, app, "/locket-app"));
}
