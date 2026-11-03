//! The NomadFS connector: the shared vault in the swarm folder, the one
//! folder every device of a NomadFS swarm reads and writes
//! (https://nomadfs.foreachdeveloper.com). Locket keeps it in
//! `<mount>/Swarm/locket/`.
//!
//! Locket uses the swarm folder through NomadFS's mount: `~/NomadFS/Swarm`
//! by default on Linux and macOS, `<drive>:\Swarm` on Windows. A file
//! written there is added to the swarm as one edit when it's closed (the
//! folder connector writes a temp file and renames it), and reaches the
//! other devices within seconds. Two devices writing at once both keep
//! their version: NomadFS renames the other one
//! `vault (conflict from <device>).enc`, which the sync engine merges and
//! removes.
//!
//! When NomadFS isn't running or isn't mounted, `~/NomadFS` may exist
//! without `Swarm` in it: that is error.NomadFsNotMounted, never an empty
//! folder to write into.
//! @atlas layer: sync

const std = @import("std");
const builtin = @import("builtin");
const Folder = @import("folder.zig").Folder;
const Connector = @import("connector.zig").Connector;

pub const id = "nomadfs";
pub const label = "NomadFS swarm folder";

/// NomadFS's default mount's swarm folder, when the platform has one
/// (Windows mounts on a drive letter the user picks).
pub fn defaultPath(env: anytype, gpa: std.mem.Allocator) !?[]u8 {
    return defaultPathFor(builtin.os.tag, env, gpa);
}

fn defaultPathFor(os: std.Target.Os.Tag, env: anytype, gpa: std.mem.Allocator) !?[]u8 {
    if (os == .windows) return null;
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(gpa, &.{ home, "NomadFS", "Swarm" });
}

/// A connector to the swarm folder at `swarm` (`<mount>/Swarm`).
pub fn init(swarm: []const u8) Folder {
    return .{ .root = swarm, .label = label, .missing = error.NomadFsNotMounted };
}

test defaultPathFor {
    const Env = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "HOME")) "/home/me" else null;
        }
    };
    const a = std.testing.allocator;
    const p = (try defaultPathFor(.linux, Env{}, a)).?;
    defer a.free(p);
    std.mem.replaceScalar(u8, p, std.fs.path.sep, '/');
    try std.testing.expectEqualStrings("/home/me/NomadFS/Swarm", p);
    try std.testing.expect(try defaultPathFor(.windows, Env{}, a) == null);
}

test "an unmounted swarm folder is NomadFsNotMounted" {
    var f = init("/nonexistent/NomadFS/Swarm");
    try std.testing.expectError(error.NomadFsNotMounted, f.connector().check(std.testing.io));
}
