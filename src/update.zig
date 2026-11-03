//! `locket update`: replaces this binary with the latest release's.
//!
//! Every release signs the command line binaries into `latest-cli.json`
//! (.github/workflows/release.yml) with the key whose public half is
//! built in. Oriel's updater engine fetches the manifest, checks the
//! Ed25519 signature and the download's SHA-256, and swaps the binary
//! atomically. The vault is never touched.
//! @atlas layer: front

const std = @import("std");
const core = @import("oriel_updater");
const build_info = @import("build_info");
const describe = @import("update_errors.zig").describe;

pub const app_id = "com.foreachdeveloper.locket.cli";
pub const manifest_url = "https://github.com/highercomve/locket/releases/latest/download/latest-cli.json";

pub const Options = struct {
    /// Only say whether there is a newer release.
    check: bool = false,
    /// Don't ask before installing.
    yes: bool = false,
};

/// `locket update [--check] [--yes]`; the process exit code.
pub fn run(io: std.Io, gpa: std.mem.Allocator, options: Options) !u8 {
    core.backend.cleanupStale(io, gpa);
    const current = build_info.version;
    var maybe = core.checkForUpdate(io, gpa, .{
        .app_id = app_id,
        .manifest_url = manifest_url,
        .current_version = current,
        .public_key_b64 = build_info.update_public_key,
    }) catch |err| {
        std.debug.print("locket: could not check for an update: {s}\n", .{describe(err)});
        return 1;
    };
    var update = maybe orelse {
        std.debug.print("locket {s} is the latest release\n", .{current});
        return 0;
    };
    maybe = null;
    defer update.deinit();

    if (options.check) {
        std.debug.print("locket {s} is available (this is {s}): run locket update\n", .{ update.version, current });
        return 0;
    }
    if (!options.yes and !try confirm(io, current, update.version)) return 0;

    std.debug.print("Downloading locket {s} ({d} KB)...\n", .{ update.version, update.size / 1024 });
    const path = core.download(io, gpa, update, .{}) catch |err| {
        std.debug.print("locket: could not install the update: {s}\n", .{describe(err)});
        return 1;
    };
    defer gpa.free(path);
    std.debug.print("Updated locket {s} -> {s} at {s}\n", .{ current, update.version, path });
    return 0;
}

/// Asks on the terminal; without one, --yes is required.
fn confirm(io: std.Io, current: []const u8, next: []const u8) !bool {
    const stdin = std.Io.File.stdin();
    if (!(stdin.isTty(io) catch false)) {
        std.debug.print("locket: not a terminal; add --yes to install locket {s}\n", .{next});
        return false;
    }
    std.debug.print("Install locket {s} -> {s}? [y/N] ", .{ current, next });
    var buf: [64]u8 = undefined;
    var reader = stdin.readerStreaming(io, &buf);
    const answer = std.mem.trim(u8, (reader.interface.takeDelimiter('\n') catch null) orelse "", " \t\r\n");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}
