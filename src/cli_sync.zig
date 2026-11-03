//! `locket sync`: sharing the vault between machines (src/sync.zig).
//!
//!     locket sync status
//!     locket sync setup <backend> [LOCATION]    the first machine
//!     locket sync join <backend> [LOCATION]     every other machine
//!     locket sync now
//!     locket sync stop
//!     locket sync backends                      what <backend> can be
//!
//! The backends are sync/connectors.zig's (nomadfs, folder, ...); a
//! location left out is the backend's default (NomadFS: ~/.nomadfs).
//!
//! The passphrase is asked on the terminal without echo (twice for
//! setup); without a terminal, it's the first line of stdin.
//! @atlas layer: front

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync.zig");

const Sub = enum { status, setup, join, now, stop, backends };

/// Runs `locket sync <args>`; the exit code.
pub fn run(io: std.Io, arena: std.mem.Allocator, data_path: []const u8, env: anytype, args: []const []const u8) !u8 {
    if (args.len == 0) return status(io, arena, data_path);
    const sub = std.meta.stringToEnum(Sub, args[0]) orelse return error.Usage;
    switch (sub) {
        .status => return status(io, arena, data_path),
        .backends => {
            for (sync.connectors.kinds) |k| say(io, "{s:<9} {s}\n          location: {s}\n", .{ k.id, k.summary, k.location_hint });
            return 0;
        },
        .now => {
            const report = try sync.syncIfShared(io, arena, data_path) orelse return error.NotConfigured;
            say(io, "locket: {s}\n", .{sync.summary(report)});
            return 0;
        },
        .stop => {
            try sync.stop(io, arena, data_path);
            say(io, "locket: this machine no longer syncs; its vault stays as it is\n", .{});
            return 0;
        },
        .setup, .join => {
            if (args.len < 2 or args.len > 3) return error.Usage;
            const kind = sync.connectors.find(args[1]) orelse return error.UnknownConnector;
            const location = if (args.len == 3)
                args[2]
            else
                try sync.connectors.defaultLocation(kind.id, sync.connectors.homeDir(env), arena) orelse return error.Usage;
            const passphrase = try readPassphrase(io, arena, sub == .setup);
            defer std.crypto.secureZero(u8, passphrase);
            say(io, "locket: {s} the vault through {s} ({s})…\n", .{ if (sub == .setup) "sharing" else "joining", kind.label, location });
            const report = if (sub == .setup)
                try sync.setup(io, arena, data_path, kind.id, location, passphrase)
            else
                try sync.join(io, arena, data_path, kind.id, location, passphrase);
            say(io, "locket: {s}\n", .{sync.summary(report)});
            if (sub == .setup) say(io, "locket: on your other machines: locket sync join {s}{s}{s}\n", .{ kind.id, if (args.len == 3) " " else "", if (args.len == 3) location else "" });
            return 0;
        },
    }
}

/// Syncs before or after a command when the vault is shared. A failure
/// is a warning: the command goes on with this machine's copy.
pub fn auto(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8) void {
    _ = sync.syncIfShared(io, gpa, data_path) catch |err| {
        warn(io, "locket: sync: {s} (using this machine's copy)\n", .{sync.describe(err) orelse @errorName(err)});
    };
}

fn status(io: std.Io, arena: std.mem.Allocator, data_path: []const u8) !u8 {
    const c = try sync.configured(io, arena, data_path) orelse {
        say(io, "not shared: this vault lives on this machine only\n  share it: locket sync setup nomadfs   (or join one: locket sync join nomadfs)\n", .{});
        return 0;
    };
    say(io, "shared through the {s}\n", .{try c.describe(arena)});
    if (sync.loadStatus(io, arena, data_path)) |s| {
        const ago = @divTrunc(std.Io.Clock.real.now(io).toMilliseconds() - s.t, 1000);
        say(io, "last sync: {s}, {d} s ago: {s}\n", .{ if (s.ok) "ok" else "failed", ago, s.message });
    } else say(io, "last sync: never\n", .{});
    return 0;
}

/// The passphrase: typed without echo (twice to confirm a new one), or
/// the first line of stdin when it isn't a terminal.
fn readPassphrase(io: std.Io, arena: std.mem.Allocator, confirm: bool) ![]u8 {
    const stdin = std.Io.File.stdin();
    if (!(stdin.isTty(io) catch false)) return readLine(io, arena, stdin);
    const first = try prompt(io, arena, if (confirm) "New passphrase for the shared vault: " else "Passphrase of the shared vault: ");
    if (confirm) {
        const again = try prompt(io, arena, "Again: ");
        defer std.crypto.secureZero(u8, again);
        if (!std.mem.eql(u8, first, again)) return error.PassphrasesDiffer;
    }
    return first;
}

fn prompt(io: std.Io, arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const stdin = std.Io.File.stdin();
    warn(io, "{s}", .{text});
    const Echo = struct {
        saved: ?std.posix.termios = null,
        fn off() @This() {
            if (comptime builtin.os.tag == .windows) return .{};
            const t = std.posix.tcgetattr(std.Io.File.stdin().handle) catch return .{};
            var quiet = t;
            quiet.lflag.ECHO = false;
            std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, quiet) catch return .{};
            return .{ .saved = t };
        }
        fn on(e: @This()) void {
            if (comptime builtin.os.tag == .windows) return;
            if (e.saved) |t| std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {};
        }
    };
    if (comptime builtin.os.tag == .windows) warn(io, "(typed passphrases show on Windows) ", .{});
    const echo = Echo.off();
    defer {
        echo.on();
        warn(io, "\n", .{});
    }
    return readLine(io, arena, stdin);
}

fn readLine(io: std.Io, arena: std.mem.Allocator, file: std.Io.File) ![]u8 {
    var buf: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const line = (reader.interface.takeDelimiter('\n') catch return error.PassphraseTooLong) orelse "";
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    const out = try arena.dupe(u8, trimmed);
    std.crypto.secureZero(u8, &buf);
    return out;
}

fn say(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn warn(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}
