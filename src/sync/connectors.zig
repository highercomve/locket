//! Every sync backend Locket knows, and how to make one from the settings
//! (config.json's `sync`: a backend id and a location).
//!
//! Adding a backend (S3, a database, a WebDAV server...):
//!
//!   1. a file implementing connector.zig's interface: a small store of
//!      named files under Locket's area, with versions when the backend
//!      has them (S3's ETags and conditional writes, a version column in
//!      MySQL, a version field in a Mongo document);
//!   2. an entry in `kinds` below: its id, how people see it, what its
//!      location is (a folder, `s3://bucket/prefix`, `mysql://host/db`),
//!      a default when there is one, and its constructor.
//!
//! Nothing else changes: the engine, the CLI (`locket sync setup <id>
//! <location>`) and the settings page (one button per kind) read this
//! list. A backend's own credentials (an S3 key, a database password) are
//! secrets: they don't belong in config.json; the first backend that needs
//! them gets a credential store sealed with this machine's vault key.
//! @atlas layer: sync

const std = @import("std");
const builtin = @import("builtin");
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
    /// What the location is, as a field's label.
    location_label: []const u8,
    /// An example location (a field's placeholder).
    location_hint: []const u8,
    /// The location suggested before the user picks one (null: none).
    /// `home` is the user's home folder.
    defaultLocation: *const fn (home: ?[]const u8, gpa: std.mem.Allocator) anyerror!?[]u8,
    /// A connector at `location`, living in `arena`.
    make: *const fn (arena: std.mem.Allocator, location: []const u8) anyerror!Connector,
};

pub const kinds = [_]Kind{
    .{
        .id = nomadfs.id,
        .label = "NomadFS",
        .summary = "The swarm folder every device of your NomadFS swarm reads and writes, through the running NomadFS (no mount needed).",
        .location_label = "NOMADFS FOLDER (WHERE ITS KEYS ARE)",
        .location_hint = "~/.nomadfs",
        .defaultLocation = nomadfs.defaultLocation,
        .make = nomadfs.make,
    },
    .{
        .id = "folder",
        .label = "Folder",
        .summary = "Any folder another tool keeps in step between machines: Syncthing, Dropbox, a network share, NomadFS's mount.",
        .location_label = "FOLDER",
        .location_hint = "/path/to/a/synced/folder",
        .defaultLocation = noDefault,
        .make = makeFolder,
    },
};

pub fn find(kind_id: []const u8) ?Kind {
    for (kinds) |k| if (std.mem.eql(u8, k.id, kind_id)) return k;
    return null;
}

/// A connector of `kind_id` at `location`. It lives in `arena`.
pub fn make(arena: std.mem.Allocator, kind_id: []const u8, location: []const u8) !Connector {
    const k = find(kind_id) orelse return error.UnknownConnector;
    return k.make(arena, location);
}

/// The location `kind_id` suggests (null: none). `home`: homeDir's.
pub fn defaultLocation(kind_id: []const u8, home: ?[]const u8, gpa: std.mem.Allocator) !?[]u8 {
    const k = find(kind_id) orelse return error.UnknownConnector;
    return k.defaultLocation(home, gpa);
}

/// The user's home folder, from the environment.
pub fn homeDir(env: anytype) ?[]const u8 {
    return env.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
}

fn noDefault(_: ?[]const u8, _: std.mem.Allocator) anyerror!?[]u8 {
    return null;
}

fn makeFolder(arena: std.mem.Allocator, location: []const u8) anyerror!Connector {
    const f = try arena.create(Folder);
    f.* = .{ .root = try arena.dupe(u8, location) };
    return f.connector();
}

test make {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try make(a, "folder", "/nonexistent/folder");
    try std.testing.expectError(error.FolderMissing, c.check(std.testing.io, a));
    try std.testing.expectError(error.UnknownConnector, make(a, "s3", "s3://bucket"));
    const n = try make(a, "nomadfs", "/nonexistent/.nomadfs");
    try std.testing.expect(n.versioned());
    const d = (try defaultLocation("nomadfs", "/home/me", a)).?;
    std.mem.replaceScalar(u8, d, std.fs.path.sep, '/');
    try std.testing.expectEqualStrings("/home/me/.nomadfs", d);
    try std.testing.expect(try defaultLocation("folder", "/home/me", a) == null);
}
