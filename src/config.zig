//! `<data>/config.json`: this machine's settings, none of them secret.
//!
//!     { "device": "<16 hex digits>",
//!       "sync": { "connector": "nomadfs", "path": "/home/me/NomadFS/Swarm" } }
//!
//! `device` identifies this machine in the vault's stamps (store.zig); it
//! is made once, at random. `sync` is the connector the vault is shared
//! through (src/sync/), absent when it isn't shared. (How the last sync
//! went is sync-status.json: src/sync/engine.zig.)
//! Written like the vault (temp file, rename), under the vault's lock.
//! @atlas layer: core

const std = @import("std");
const builtin = @import("builtin");

pub const file = "config.json";

pub const Sync = struct {
    /// A connector's id (sync/connectors.zig): "nomadfs" or "folder".
    connector: []const u8,
    /// The folder the shared vault lives under (`<path>/locket/`).
    path: []const u8,
};

pub const Config = struct {
    device: []const u8 = "",
    sync: ?Sync = null,

    /// The device id; 0 when there is none yet.
    pub fn deviceId(c: Config) u64 {
        return std.fmt.parseInt(u64, c.device, 16) catch 0;
    }
};

/// The config in `dir_path`, or the defaults when there is none. Strings
/// are allocated in `arena`.
pub fn load(io: std.Io, arena: std.mem.Allocator, dir_path: []const u8) !Config {
    const path = try std.fs.path.join(arena, &.{ dir_path, file });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    return std.json.parseFromSliceLeaky(Config, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.CorruptConfig;
}

pub fn save(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, cfg: Config) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer gpa.free(json);
    const path = try std.fs.path.join(gpa, &.{ dir_path, file });
    defer gpa.free(path);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    {
        const f = try cwd.createFile(io, tmp, .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
        defer f.close(io);
        try f.writeStreamingAll(io, json);
        try f.sync(io);
    }
    try cwd.rename(tmp, cwd, path, io);
}

/// A new random device id, as config.json writes it.
pub fn newDevice(io: std.Io, buf: *[16]u8) []const u8 {
    var id: u64 = 0;
    while (id == 0) io.random(std.mem.asBytes(&id));
    return std.fmt.bufPrint(buf, "{x:0>16}", .{id}) catch unreachable;
}

test "config round-trips, and a missing file is the defaults" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const empty = try load(io, a, dir);
    try testing.expect(empty.sync == null);
    try testing.expectEqual(@as(u64, 0), empty.deviceId());

    var buf: [16]u8 = undefined;
    const dev = newDevice(io, &buf);
    try save(io, testing.allocator, dir, .{ .device = dev, .sync = .{ .connector = "nomadfs", .path = "/m/Swarm" } });
    const back = try load(io, a, dir);
    try testing.expectEqualStrings("nomadfs", back.sync.?.connector);
    try testing.expectEqualStrings("/m/Swarm", back.sync.?.path);
    try testing.expect(back.deviceId() != 0);
}
