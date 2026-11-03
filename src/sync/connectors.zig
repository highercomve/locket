//! Every sync connector Locket knows, and how to make one from the
//! settings (config.json's `sync`). A new backend is a file implementing
//! connector.zig's interface and an entry in `kinds`.
//! @atlas layer: sync

const std = @import("std");
const Connector = @import("connector.zig").Connector;
const Folder = @import("folder.zig").Folder;
const nomadfs = @import("nomadfs.zig");

pub const Kind = struct {
    /// What config.json stores.
    id: []const u8,
    /// What people see.
    label: []const u8,
    /// One line on what it is.
    summary: []const u8,
};

pub const kinds = [_]Kind{
    .{ .id = nomadfs.id, .label = "NomadFS", .summary = "The swarm folder every device of your NomadFS swarm reads and writes." },
    .{ .id = "folder", .label = "Folder", .summary = "Any folder another tool keeps in step between machines (Syncthing, Dropbox, a network share)." },
};

pub fn find(kind_id: []const u8) ?Kind {
    for (kinds) |k| if (std.mem.eql(u8, k.id, kind_id)) return k;
    return null;
}

/// The path a connector suggests before the user picks one (null: none).
pub fn defaultPath(kind_id: []const u8, env: anytype, gpa: std.mem.Allocator) !?[]u8 {
    if (std.mem.eql(u8, kind_id, nomadfs.id)) return nomadfs.defaultPath(env, gpa);
    return null;
}

/// A connector of `kind_id` at `path`. It lives in `arena`.
pub fn make(arena: std.mem.Allocator, kind_id: []const u8, path: []const u8) !Connector {
    const f = try arena.create(Folder);
    if (std.mem.eql(u8, kind_id, nomadfs.id)) {
        f.* = nomadfs.init(try arena.dupe(u8, path));
    } else if (std.mem.eql(u8, kind_id, "folder")) {
        f.* = .{ .root = try arena.dupe(u8, path) };
    } else return error.UnknownConnector;
    return f.connector();
}

test make {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try make(arena.allocator(), "nomadfs", "/nonexistent/Swarm");
    try std.testing.expectError(error.NomadFsNotMounted, c.check(std.testing.io));
    try std.testing.expectError(error.UnknownConnector, make(arena.allocator(), "s3", "/x"));
    try std.testing.expect(find("folder") != null);
}
