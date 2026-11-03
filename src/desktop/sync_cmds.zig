//! The window's sync commands: the sync engine (src/sync.zig) run on
//! Oriel's command pool, so a slow swarm folder or the passphrase's
//! Argon2id never freezes the window. sync_ui.zig invokes them and shows
//! the answers. One sync at a time: a sync asked for while one runs is
//! skipped (the next timer tick catches up).
//! @atlas layer: front

const std = @import("std");
const oriel = @import("oriel");
const sync = @import("../sync.zig");
const config = @import("../config.zig");
const st = @import("state.zig");

var busy: std.atomic.Value(bool) = .init(false);

pub const Result = struct {
    /// The vault is shared (false: nothing was done).
    shared: bool = true,
    /// Another sync was running: this one didn't run.
    skipped: bool = false,
    pulled: bool = false,
    pushed: bool = false,
    copies: usize = 0,
};

pub const Info = struct {
    shared: bool,
    connector: []const u8 = "",
    path: []const u8 = "",
    /// "NomadFS swarm folder at ..." when shared.
    where: []const u8 = "",
    /// The last sync, when there was one.
    last_t: i64 = 0,
    last_ok: bool = false,
    last_message: []const u8 = "",
    device: []const u8 = "",
};

pub const Probe = struct {
    /// "shared" (a vault to join), "empty" (one can be set up there) or
    /// "unavailable" (`message` says why).
    state: []const u8,
    message: []const u8 = "",
};

pub const Target = struct { kind: []const u8, path: []const u8 };
pub const Credentials = struct { kind: []const u8, path: []const u8, passphrase: []const u8 };

pub const Commands = struct {
    pub const async_commands = .{ "sync_info", "sync_now", "sync_probe", "sync_setup", "sync_join", "sync_stop" };

    pub fn sync_info(arena: std.mem.Allocator) !Info {
        const cfg = config.load(st.io, arena, st.data_path) catch config.Config{};
        var info: Info = .{ .shared = cfg.sync != null, .device = cfg.device };
        if (cfg.sync) |s| {
            info.connector = s.connector;
            info.path = s.path;
            const c = sync.connectors.make(arena, s.connector, s.path) catch null;
            info.where = if (c) |x| x.describe(arena) catch s.path else s.path;
        }
        if (sync.loadStatus(st.io, arena, st.data_path)) |status| {
            info.last_t = status.t;
            info.last_ok = status.ok;
            info.last_message = status.message;
        }
        return info;
    }

    pub fn sync_now(arena: std.mem.Allocator) !Result {
        if (busy.swap(true, .acq_rel)) return .{ .skipped = true };
        defer busy.store(false, .release);
        const report = sync.syncIfShared(st.io, arena, st.data_path) catch |err| return fail(err);
        const r = report orelse return .{ .shared = false };
        return .{ .pulled = r.pulled, .pushed = r.pushed, .copies = r.copies };
    }

    /// Whether there is a shared vault at a place (before setup or join).
    pub fn sync_probe(arena: std.mem.Allocator, args: Target) !Probe {
        const shared = sync.isShared(st.io, arena, args.kind, args.path) catch |err| {
            return .{ .state = "unavailable", .message = sync.describe(err) orelse @errorName(err) };
        };
        return .{ .state = if (shared) "shared" else "empty" };
    }

    pub fn sync_setup(arena: std.mem.Allocator, args: Credentials) !Result {
        if (busy.swap(true, .acq_rel)) return oriel.ipc.fail("A sync is running: try again in a moment.", .{});
        defer busy.store(false, .release);
        const r = sync.setup(st.io, arena, st.data_path, args.kind, args.path, args.passphrase) catch |err| return fail(err);
        return .{ .pulled = r.pulled, .pushed = r.pushed, .copies = r.copies };
    }

    pub fn sync_join(arena: std.mem.Allocator, args: Credentials) !Result {
        if (busy.swap(true, .acq_rel)) return oriel.ipc.fail("A sync is running: try again in a moment.", .{});
        defer busy.store(false, .release);
        const r = sync.join(st.io, arena, st.data_path, args.kind, args.path, args.passphrase) catch |err| return fail(err);
        return .{ .pulled = r.pulled, .pushed = r.pushed, .copies = r.copies };
    }

    pub fn sync_stop(arena: std.mem.Allocator) !void {
        sync.stop(st.io, arena, st.data_path) catch |err| return fail(err);
    }
};

fn fail(err: anyerror) error{CommandFailed} {
    std.log.info("sync: {s}", .{@errorName(err)});
    return oriel.ipc.fail("{s}", .{sync.describe(err) orelse @errorName(err)});
}
