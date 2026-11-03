//! The folder connector: a shared vault in `<root>/locket/` of any
//! directory another tool keeps in step between machines (Syncthing,
//! Dropbox, a network share). nomadfs.zig is this, pointed at NomadFS's
//! swarm folder.
//!
//! `root` must exist: Locket creates only its own `locket/` inside it, so
//! a sync folder that isn't there (an unmounted share) is reported, not
//! silently replaced by an empty local directory.
//! @atlas layer: sync

const std = @import("std");
const Connector = @import("connector.zig").Connector;
const isConflictCopy = @import("connector.zig").isConflictCopy;

/// Locket's own area inside the folder.
pub const area = "locket";

pub const Folder = struct {
    /// The shared folder (absolute).
    root: []const u8,
    /// How to name it for people ("Folder", "NomadFS swarm folder").
    label: []const u8 = "folder",
    /// Why `root` may be missing, when it is (a backend-specific hint).
    missing: anyerror = error.FolderMissing,

    pub fn connector(f: *Folder) Connector {
        return .{ .ptr = f, .vtable = &vtable };
    }

    const vtable: Connector.VTable = .{
        .check = check,
        .list = list,
        .read = read,
        .write = write,
        .remove = remove,
        .isCopyOf = isCopyOf,
        .describe = describe,
    };

    fn self(ptr: *anyopaque) *Folder {
        return @ptrCast(@alignCast(ptr));
    }

    fn check(ptr: *anyopaque, io: std.Io) anyerror!void {
        const f = self(ptr);
        if (!std.fs.path.isAbsolute(f.root)) return error.FolderNotAbsolute;
        const st = std.Io.Dir.cwd().statFile(io, f.root, .{}) catch |e| switch (e) {
            error.FileNotFound => return f.missing,
            else => return e,
        };
        if (st.kind != .directory) return error.FolderMissing;
    }

    fn areaPath(f: *Folder, gpa: std.mem.Allocator, name: ?[]const u8) ![]u8 {
        return if (name) |n| std.fs.path.join(gpa, &.{ f.root, area, n }) else std.fs.path.join(gpa, &.{ f.root, area });
    }

    fn list(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror![]const []const u8 {
        const f = self(ptr);
        try check(ptr, io);
        const path = try f.areaPath(gpa, null);
        defer gpa.free(path);
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };
        defer dir.close(io);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = dir.iterate();
        var seen: usize = 0;
        while (try it.next(io)) |entry| : (seen += 1) {
            if (seen >= 1024) break; // Locket's area holds a few files
            if (entry.kind != .file or entry.name[0] == '.') continue; // temp files are hidden
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        return names.toOwnedSlice(gpa);
    }

    fn read(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8) anyerror![]u8 {
        const f = self(ptr);
        try check(ptr, io);
        const path = try f.areaPath(gpa, name);
        defer gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    }

    /// A hidden temp file in the same folder, renamed over the target: the
    /// sync tool sees one complete file (NomadFS adds it as one edit).
    fn write(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, data: []const u8) anyerror!void {
        const f = self(ptr);
        try check(ptr, io);
        const cwd = std.Io.Dir.cwd();
        const dir = try f.areaPath(gpa, null);
        defer gpa.free(dir);
        try cwd.createDirPath(io, dir);
        var rnd: u32 = 0;
        io.random(std.mem.asBytes(&rnd));
        const tmp_name = try std.fmt.allocPrint(gpa, ".{s}.{x}.tmp", .{ name, rnd });
        defer gpa.free(tmp_name);
        const tmp = try std.fs.path.join(gpa, &.{ dir, tmp_name });
        defer gpa.free(tmp);
        const dest = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(dest);
        {
            const file = try cwd.createFile(io, tmp, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, data);
            try file.sync(io);
        }
        errdefer cwd.deleteFile(io, tmp) catch {};
        try cwd.rename(tmp, cwd, dest, io);
    }

    fn remove(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8) anyerror!void {
        const f = self(ptr);
        try check(ptr, io);
        const path = try f.areaPath(gpa, name);
        defer gpa.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    fn isCopyOf(_: *anyopaque, name: []const u8, base: []const u8) bool {
        return isConflictCopy(name, base);
    }

    fn describe(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror![]const u8 {
        const f = self(ptr);
        return std.fmt.allocPrint(gpa, "{s} at {s}", .{ f.label, f.root });
    }
};

test "a folder connector writes, lists, reads and removes, and refuses a missing folder" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);

    var f: Folder = .{ .root = root };
    const c = f.connector();
    try c.check(io);
    try t.expectEqual(@as(usize, 0), (try c.list(io, a)).len);
    try t.expect(try c.readOptional(io, a, "vault.enc") == null);
    try c.write(io, a, "vault.enc", "one");
    try c.write(io, a, "vault.enc", "two");
    try t.expectEqualStrings("two", try c.read(io, a, "vault.enc"));
    const names = try c.list(io, a);
    try t.expectEqual(@as(usize, 1), names.len); // the temp files are gone
    try c.remove(io, a, "vault.enc");
    try c.remove(io, a, "vault.enc"); // already gone: fine

    var missing: Folder = .{ .root = try std.fs.path.join(a, &.{ root, "nope" }) };
    try t.expectError(error.FolderMissing, missing.connector().check(io));
    try t.expectError(error.FolderMissing, missing.connector().write(io, a, "x", "y"));
    var relative: Folder = .{ .root = "relative/path" };
    try t.expectError(error.FolderNotAbsolute, relative.connector().check(io));
}
