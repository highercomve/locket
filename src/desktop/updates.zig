//! Updates for locket-app: the commands the window invokes (on Oriel's
//! command pool, off the UI thread) to check the latest release, install
//! it and restart.
//!
//! Every release attaches a signed `latest.json` (Ed25519, the key whose
//! public half is built in: build.zig). How an update applies depends on
//! how this copy was installed:
//!
//! - The AppImage (scripts/install-local.sh, the release download), the
//!   Windows installer's exe, a macOS `.app`: replaced, then restarted.
//! - A deb/rpm package (/usr, /opt): the check says a new version is out;
//!   the package manager installs it.
//! - A development build (zig-out/bin): the check works; installing fails
//!   with FormatMismatch (the release ships an AppImage, not a bare exe).
//!
//! The `locket` next to the app is checked and updated with it
//! (sibling.zig): the two must move together. When only it is behind, the
//! update installs just it, and needs no restart.
//! @atlas layer: front

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const build_info = @import("build_info");
const describe = @import("../update_errors.zig").describe;
const sibling = @import("../sibling.zig");

const updater = oriel.updater;
const siblings = sibling.Updater(updater);
const log = std.log.scoped(.updates);
const gpa = std.heap.smp_allocator;

pub const app_id = "com.foreachdeveloper.locket";
pub const manifest_url = "https://github.com/highercomve/locket/releases/latest/download/latest.json";

var io: std.Io = undefined;

/// Call once from `main`, on the main thread.
pub fn init(actual_io: std.Io) void {
    io = actual_io;
}

/// How this copy was installed (decides how an update applies).
pub const InstallKind = enum {
    executable,
    appimage,
    macos_app,
    /// deb/rpm: updated by the package manager.
    package,

    pub fn canInstall(self: InstallKind) bool {
        return self != .package;
    }
};

pub fn installKind() InstallKind {
    if (builtin.os.tag == .windows) return .executable;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch return .executable;
    const exe = buf[0..n];
    if (builtin.os.tag == .macos and std.mem.indexOf(u8, exe, ".app/Contents/MacOS/") != null) return .macos_app;
    if (builtin.os.tag == .linux) {
        if (updater.runningAsAppImage(io, gpa) catch false) return .appimage;
        if (std.mem.startsWith(u8, exe, "/usr/") or std.mem.startsWith(u8, exe, "/opt/")) return .package;
    }
    return .executable;
}

fn config() updater.Config {
    return .{
        .app_id = app_id,
        .manifest_url = manifest_url,
        .current_version = build_info.version,
        .public_key_b64 = build_info.update_public_key,
    };
}

// The last verified update found, and whether one was installed. Commands
// run on worker threads, so these sit behind the mutex.
var mutex: std.Io.Mutex = .init;
var pending: ?updater.Update = null;
/// The `locket` next to the app, and its update, when it's behind.
var pending_cli: ?updater.Update = null;
var cli_path: ?[:0]u8 = null;
var busy: std.atomic.Value(bool) = .init(false);

pub const CheckResult = struct {
    available: bool,
    /// The app's new version; the CLI's when only it is behind.
    version: ?[]const u8 = null,
    can_install: bool,
    /// The app itself has an update (false: only the CLI).
    app: bool = false,
    /// The CLI's new version, when it has one.
    cli_version: ?[]const u8 = null,
};

pub const Installed = struct {
    version: []const u8,
    /// The app was replaced: restart to use it.
    restart: bool,
    /// The CLI's new version, when it was updated.
    cli_version: ?[]const u8 = null,
    /// Why updating the CLI failed (the app's update stands).
    cli_error: ?[]const u8 = null,
};

/// The `locket` next to this app and its update, when it's behind
/// `latest-cli.json`. The caller owns both.
const CliUpdate = struct { update: updater.Update, path: [:0]u8 };

fn checkCli() ?CliUpdate {
    const self_path = updater.resolveDestPath(io, gpa, null) catch return null;
    defer gpa.free(self_path);
    const path = sibling.find(io, gpa, .cli, self_path) orelse return null;
    // Its own word on its version; failing that, assume this app's.
    const reported = sibling.cliVersion(io, gpa, path);
    defer if (reported) |v| gpa.free(v);
    const found = siblings.check(io, gpa, .cli, reported orelse build_info.version) catch |err| blk: {
        log.info("checking {s}: {s}", .{ path, @errorName(err) });
        break :blk null;
    };
    const update = found orelse {
        gpa.free(path);
        return null;
    };
    log.info("{s} is {s}; {s} is available", .{ path, reported orelse "of unknown version", update.version });
    return .{ .update = update, .path = path };
}

pub const Commands = struct {
    pub const async_commands = .{ "update_check", "update_install", "update_restart" };

    pub fn update_check(arena: std.mem.Allocator) !CheckResult {
        const kind = installKind();
        var found = updater.checkForUpdate(io, gpa, config()) catch |err| {
            return oriel.ipc.fail("Couldn't check for updates: {s}.", .{describe(err)});
        };
        const cli = if (kind.canInstall()) checkCli() else null;
        const cli_version = if (cli) |c| arena.dupe(u8, c.update.version) catch null else null;
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (pending) |*p| p.deinit();
        pending = null;
        if (pending_cli) |*p| p.deinit();
        pending_cli = null;
        if (cli_path) |p| gpa.free(p);
        cli_path = null;
        if (cli) |c| {
            pending_cli = c.update;
            cli_path = c.path;
        }
        if (found) |*f| {
            const v = try arena.dupe(u8, f.version);
            pending = f.*;
            return .{ .available = true, .version = v, .can_install = kind.canInstall(), .app = true, .cli_version = cli_version };
        }
        if (cli_version) |v| return .{ .available = true, .version = v, .can_install = true, .cli_version = v };
        return .{ .available = false, .can_install = kind.canInstall() };
    }

    /// Downloads, verifies and installs what the last check found: the
    /// app's update and the CLI's. A failed app download keeps it, so it
    /// can be retried; a failed CLI update is reported, the app's stands.
    pub fn update_install(arena: std.mem.Allocator) !Installed {
        if (!installKind().canInstall()) return oriel.ipc.fail("This copy is installed by a package manager: update it there.", .{});
        if (busy.swap(true, .acq_rel)) return oriel.ipc.fail("An update is already downloading.", .{});
        defer busy.store(false, .release);

        mutex.lockUncancelable(io);
        const app_update = pending;
        pending = null; // ours now: a check meanwhile won't free them
        const cli_update = pending_cli;
        pending_cli = null;
        const cli_dest = if (cli_path) |p| try arena.dupe(u8, p) else null;
        mutex.unlock(io);
        if (app_update == null and cli_update == null) return oriel.ipc.fail("Check for updates first.", .{});

        var out: Installed = .{ .version = "", .restart = false };
        if (app_update) |u| {
            var update = u;
            const dest = updater.download(io, gpa, update, .{}) catch |err| {
                mutex.lockUncancelable(io);
                if (pending == null) pending = update else update.deinit();
                if (cli_update) |c| {
                    if (pending_cli == null) pending_cli = c else {
                        var cu = c;
                        cu.deinit();
                    }
                }
                mutex.unlock(io);
                return oriel.ipc.fail("The update failed: {s}.", .{describe(err)});
            };
            defer update.deinit();
            gpa.free(dest);
            log.info("installed {s}; it runs after a restart", .{update.version});
            out.version = try arena.dupe(u8, update.version);
            out.restart = true;
        }
        if (cli_update) |c| {
            var update = c;
            defer update.deinit();
            if (cli_dest) |dest| {
                if (siblings.install(io, gpa, update, dest)) {
                    log.info("updated {s} to {s}", .{ dest, update.version });
                    out.cli_version = try arena.dupe(u8, update.version);
                    if (out.version.len == 0) out.version = out.cli_version.?;
                } else |err| {
                    out.cli_error = try std.fmt.allocPrint(arena, "{s}: {s}", .{ dest, describe(err) });
                    if (!out.restart) return oriel.ipc.fail("Updating the command line failed: {s}.", .{out.cli_error.?});
                }
            }
        }
        return out;
    }

    /// Starts the installed version in place of this one.
    pub fn update_restart(_: std.mem.Allocator) !void {
        const dest = updater.resolveDestPath(io, gpa, null) catch |err| return oriel.ipc.fail("Can't restart: {s}.", .{@errorName(err)});
        defer gpa.free(dest);
        updater.restart(io, dest) catch |err| return oriel.ipc.fail("Can't restart: {s}.", .{@errorName(err)});
    }
};

test InstallKind {
    try std.testing.expect(InstallKind.appimage.canInstall());
    try std.testing.expect(!InstallKind.package.canInstall());
}
