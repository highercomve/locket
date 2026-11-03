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
//! @atlas layer: front

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const build_info = @import("build_info");
const describe = @import("../update_errors.zig").describe;

const updater = oriel.updater;
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
var busy: std.atomic.Value(bool) = .init(false);

pub const CheckResult = struct {
    available: bool,
    version: ?[]const u8 = null,
    can_install: bool,
};

pub const Commands = struct {
    pub const async_commands = .{ "update_check", "update_install", "update_restart" };

    pub fn update_check(arena: std.mem.Allocator) !CheckResult {
        const kind = installKind();
        var found = updater.checkForUpdate(io, gpa, config()) catch |err| {
            return oriel.ipc.fail("Couldn't check for updates: {s}.", .{describe(err)});
        };
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (pending) |*p| p.deinit();
        pending = null;
        if (found) |*f| {
            const v = try arena.dupe(u8, f.version);
            pending = f.*;
            return .{ .available = true, .version = v, .can_install = kind.canInstall() };
        }
        return .{ .available = false, .can_install = kind.canInstall() };
    }

    /// Downloads, verifies and installs the update the last check found;
    /// its version. A failed download keeps it, so it can be retried.
    pub fn update_install(arena: std.mem.Allocator) ![]const u8 {
        if (!installKind().canInstall()) return oriel.ipc.fail("This copy is installed by a package manager: update it there.", .{});
        if (busy.swap(true, .acq_rel)) return oriel.ipc.fail("An update is already downloading.", .{});
        defer busy.store(false, .release);

        mutex.lockUncancelable(io);
        var update = pending orelse {
            mutex.unlock(io);
            return oriel.ipc.fail("Check for updates first.", .{});
        };
        pending = null; // ours now: a check meanwhile won't free it
        mutex.unlock(io);

        const dest = updater.download(io, gpa, update, .{}) catch |err| {
            mutex.lockUncancelable(io);
            if (pending == null) pending = update else update.deinit();
            mutex.unlock(io);
            return oriel.ipc.fail("The update failed: {s}.", .{describe(err)});
        };
        defer update.deinit();
        gpa.free(dest);
        log.info("installed {s}; it runs after a restart", .{update.version});
        return arena.dupe(u8, update.version);
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
