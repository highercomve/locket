//! The settings page, and the window's syncing: at start, after every
//! edit, every 30 seconds and on "Sync now". The work runs in
//! sync_cmds.zig's commands; their answers come back through `resolved`.
//!
//! Not shared yet, the page offers NomadFS or a folder, probes the place
//! (is there a shared vault to join, or can one be set up?) and asks for
//! the passphrase: twice to share this vault, once to join one. Shared,
//! it shows where, how the last sync went, Sync now and Stop syncing.
//! @atlas layer: front

const std = @import("std");
const oriel = @import("oriel");
const build_info = @import("build_info");
const sync = @import("../sync.zig");
const st = @import("state.zig");
const w = @import("widgets.zig");
const view = @import("render.zig");
const update_ui = @import("update_ui.zig");

const ui = oriel.ui;
const sid = st.sid;

/// ui.invoke request ids (update_ui.zig uses 1-3).
pub const Request = enum(u32) { info = 10, now = 11, probe = 12, setup = 13, join = 14, stop = 15 };

pub fn owns(req_id: u32) bool {
    return std.enums.fromInt(Request, req_id) != null;
}

pub const sync_timer: u32 = 2;
const sync_every_ms = 30_000;

const Probe = enum { unknown, checking, shared, empty, unavailable };

/// The page's state. Strings from the last `sync_info` live in `arena`.
var arena: std.heap.ArenaAllocator = undefined;
var open = false;
/// The chosen backend: a connectors.kinds id (they're comptime strings).
var kind: []const u8 = sync.connectors.kinds[0].id;
var probe: Probe = .unknown;
/// The path the probe was for: a field edited since needs a new one.
var probed_buf: [std.fs.max_path_bytes]u8 = undefined;
var probed: []const u8 = "";
/// Connect was clicked before the probe answered: go on once it does.
var connect_after_probe = false;
var probe_message: []const u8 = "";
var info: struct {
    shared: bool = false,
    where: []const u8 = "",
    last_t: i64 = 0,
    last_ok: bool = false,
    last_message: []const u8 = "",
    device: []const u8 = "",
} = .{};
/// A request of each kind in flight (the next tick doesn't pile up).
var syncing = false;
var connecting = false;

pub fn start(e: *ui.Engine) !void {
    arena = .init(e.gpa);
    try invoke(e, .info, .{});
    e.backend.add_timer(e.backend.ctx, e, sync_timer, sync_every_ms);
}

/// Every 30 seconds, while the vault is shared.
pub fn tick(e: *ui.Engine) !void {
    e.backend.add_timer(e.backend.ctx, e, sync_timer, sync_every_ms);
    try requestSync(e);
}

/// After an edit is saved: share it now.
pub fn afterEdit(e: *ui.Engine) void {
    requestSync(e) catch {};
}

fn requestSync(e: *ui.Engine) !void {
    if (!info.shared or syncing) return;
    syncing = true;
    errdefer syncing = false; // never stuck "in flight" when the invoke fails
    try invoke(e, .now, .{});
}

// ------------------------------------------------------------------ clicks

pub fn openPage(e: *ui.Engine) !bool {
    open = true;
    try w.display(e, sid("main"), false);
    try w.display(e, sid("settings"), true);
    try w.label(e, sid("open-settings"), "Settings");
    var buf: [128]u8 = undefined;
    try w.text(e, sid("set-version"), try std.fmt.bufPrint(&buf, "Locket {s} ({s})", .{ build_info.version, build_info.commit }));
    if (fieldEmpty(e)) try setDefaultLocation(e);
    try paint(e);
    try invoke(e, .info, .{});
    if (!info.shared) try startProbe(e);
    return true;
}

pub fn closePage(e: *ui.Engine) !bool {
    open = false;
    try clearPassphrases(e);
    try w.display(e, sid("settings"), false);
    try w.display(e, sid("main"), true);
    e.tree.layout();
    return true;
}

/// How many backend buttons there are (one per connectors.kinds).
pub fn kindCount() usize {
    return sync.connectors.kinds.len;
}

/// A backend's button: that backend, at its default location.
pub fn chooseKind(e: *ui.Engine, index: usize) !bool {
    const k = sync.connectors.kinds[index];
    if (info.shared or std.mem.eql(u8, kind, k.id)) return true;
    kind = k.id;
    try setDefaultLocation(e);
    try startProbe(e);
    return true;
}

/// Enter in the path field: look at the place again.
pub fn pathEntered(e: *ui.Engine) !bool {
    try startProbe(e);
    return true;
}

pub fn connect(e: *ui.Engine) !bool {
    if (connecting or info.shared) return true;
    var fields = std.heap.ArenaAllocator.init(e.gpa);
    defer fields.deinit();
    const path = try w.field(e, fields.allocator(), sid("sync-path"));
    const pass = try fields.allocator().dupe(u8, w.fieldValue(e, sid("sync-pass")));
    defer std.crypto.secureZero(u8, pass);
    // The field changed since the place was looked at (or it never was):
    // look again, then go on with this click.
    const fresh = std.mem.eql(u8, path, probed);
    if (!fresh or (probe != .shared and probe != .empty)) {
        connect_after_probe = true;
        try startProbe(e);
        return true;
    }
    switch (probe) {
        .shared => {},
        .empty => {
            if (pass.len < sync.keywrap.min_passphrase) return statusFail(e, "The passphrase must be at least 8 characters.");
            if (!std.mem.eql(u8, pass, w.fieldValue(e, sid("sync-pass2")))) return statusFail(e, "The two passphrases differ.");
        },
        else => unreachable, // checked above
    }
    if (pass.len == 0) return statusFail(e, "Type the passphrase.");
    connecting = true;
    errdefer connecting = false;
    const joining = probe == .shared;
    try busyText(e, if (joining) "Unlocking the shared key and merging…" else "Wrapping the key and sharing the vault…");
    try invoke(e, if (joining) .join else .setup, .{ .kind = kind, .location = path, .passphrase = pass });
    try clearPassphrases(e);
    return true;
}

pub fn syncNow(e: *ui.Engine) !bool {
    if (syncing) return true;
    syncing = true;
    errdefer syncing = false;
    try busyText(e, "Syncing…");
    try invoke(e, .now, .{});
    return true;
}

pub fn stopSync(e: *ui.Engine) !bool {
    try invoke(e, .stop, .{});
    return true;
}

pub fn checkUpdates(e: *ui.Engine) !bool {
    return update_ui.clickVersion(e);
}

// ----------------------------------------------------------------- answers

pub fn resolved(e: *ui.Engine, req_id: u32, ok: bool, json: []const u8) !void {
    const req = std.enums.fromInt(Request, req_id) orelse return;
    if (!ok) return failed(e, req, json);
    switch (req) {
        .info => try takeInfo(e, json),
        .probe => {
            const P = struct { state: []const u8, message: []const u8 = "" };
            const p = try std.json.parseFromSlice(P, e.gpa, json, .{ .ignore_unknown_fields = true });
            defer p.deinit();
            probe = std.meta.stringToEnum(Probe, p.value.state) orelse .unavailable;
            probe_message = try arena.allocator().dupe(u8, p.value.message);
            try paint(e);
            // A click on Share / Join was waiting for this answer.
            if (connect_after_probe) {
                connect_after_probe = false;
                if (probe == .shared or probe == .empty) _ = try connect(e);
            }
        },
        .now, .setup, .join => {
            if (req == .now) syncing = false else connecting = false;
            const R = struct { shared: bool = true, skipped: bool = false, pulled: bool = false, copies: usize = 0 };
            const r = try std.json.parseFromSlice(R, e.gpa, json, .{ .ignore_unknown_fields = true });
            defer r.deinit();
            if (r.value.skipped) return;
            // The vault may have taken other machines' changes.
            if (r.value.pulled or req != .now) try view.render(e);
            if (req != .now) view.status(e, if (req == .setup) "This vault is shared: join it from your other machines." else "Joined: this machine now syncs with the shared vault.");
            if (r.value.copies > 0) view.status(e, "Synced: merged edits made on two machines at once.");
            try busyText(e, "");
            try invoke(e, .info, .{});
        },
        .stop => {
            view.status(e, "This machine no longer syncs; its vault stays as it is.");
            try invoke(e, .info, .{});
            try startProbe(e);
        },
    }
}

fn failed(e: *ui.Engine, req: Request, json: []const u8) !void {
    var msg_buf: [1024]u8 = undefined;
    const message = w.failureText(json, &msg_buf, "The sync failed.");
    switch (req) {
        .now => {
            syncing = false;
            try busyText(e, "");
            try invoke(e, .info, .{}); // the failure is in the recorded status
        },
        .setup, .join => {
            connecting = false;
            try busyText(e, "");
            view.status(e, message);
            try startProbe(e);
        },
        .probe => {
            connect_after_probe = false;
            probe = .unavailable;
            probe_message = try arena.allocator().dupe(u8, message);
            try paint(e);
        },
        else => view.status(e, message),
    }
}

fn takeInfo(e: *ui.Engine, json: []const u8) !void {
    const I = struct {
        shared: bool,
        connector: []const u8 = "",
        path: []const u8 = "",
        where: []const u8 = "",
        last_t: i64 = 0,
        last_ok: bool = false,
        last_message: []const u8 = "",
        device: []const u8 = "",
    };
    const p = try std.json.parseFromSlice(I, e.gpa, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    const was_shared = info.shared;
    info = .{
        .shared = p.value.shared,
        .where = try a.dupe(u8, p.value.where),
        .last_t = p.value.last_t,
        .last_ok = p.value.last_ok,
        .last_message = try a.dupe(u8, p.value.last_message),
        .device = try a.dupe(u8, p.value.device),
    };
    probe_message = "";
    if (p.value.shared) {
        if (sync.connectors.find(p.value.connector)) |k| kind = k.id;
    }
    // First word of a newly shared vault: sync now, so the window is current.
    if (info.shared and !was_shared and !syncing) {
        syncing = true;
        errdefer syncing = false;
        try invoke(e, .now, .{});
    }
    try paint(e);
}

// ------------------------------------------------------------------- paint

/// The page, from `info` and the probe.
fn paint(e: *ui.Engine) !void {
    var buf: [512]u8 = undefined;
    try w.text(e, sid("sync-badge"), if (info.shared) "ON" else "OFF");
    if (info.shared) {
        var ago_buf: [64]u8 = undefined;
        const last = if (info.last_t == 0) "never synced yet" else try std.fmt.bufPrint(&ago_buf, "last sync {s} {s}", .{ if (info.last_ok) "ok" else "FAILED", ago(&buf, info.last_t) });
        var state_buf: [768]u8 = undefined;
        try w.text(e, sid("sync-state"), try std.fmt.bufPrint(&state_buf, "Shared through the {s}.\n{s}: {s}.", .{ info.where, last, info.last_message }));
    } else {
        try w.text(e, sid("sync-state"), "This vault lives on this machine only. Share it through NomadFS's swarm folder or any synced folder; your other machines join with the passphrase and every edit reaches them within seconds.");
    }
    try w.display(e, sid("sync-form"), !info.shared);
    try w.display(e, sid("sync-connect"), !info.shared);
    try w.display(e, sid("sync-now"), info.shared);
    try w.display(e, sid("sync-stop"), info.shared);

    const k = sync.connectors.find(kind).?;
    try w.text(e, sid("conn-summary"), k.summary);
    try w.text(e, sid("path-label"), k.location_label);
    try paintKinds(e);

    const joining = probe == .shared;
    try w.display(e, sid("pass2-box"), !joining);
    try w.label(e, sid("sync-connect"), if (joining) "Join the shared vault" else "Share this vault");
    try w.text(e, sid("sync-probe"), switch (probe) {
        .unknown => "",
        .checking => "Looking…",
        .shared => "There's a shared vault here: join it with its passphrase.",
        .empty => "No shared vault here yet: this machine's vault will be the first.",
        .unavailable => probe_message,
    });
    try w.text(e, sid("pass-hint"), if (joining)
        "The passphrase set when this vault was first shared. This machine's secrets are merged into the shared vault, and it keeps the shared key from now on."
    else
        "It protects the vault's key in the shared folder: anyone with the folder but not the passphrase sees nothing. You'll type it once on each machine that joins, and it can't be recovered: keep it in your password manager.");
    var about: [512]u8 = undefined;
    try w.text(e, sid("set-about"), try std.fmt.bufPrint(&about, "Vault folder: {s}\nThis machine: {s}", .{ st.data_path, if (info.device.len > 0) info.device else "(no id yet)" }));
    e.tree.layout();
}

// ----------------------------------------------------------------- helpers

fn startProbe(e: *ui.Engine) !void {
    var fields = std.heap.ArenaAllocator.init(e.gpa);
    defer fields.deinit();
    const path = try w.field(e, fields.allocator(), sid("sync-path"));
    probe = .checking;
    probed = if (path.len <= probed_buf.len) blk: {
        @memcpy(probed_buf[0..path.len], path);
        break :blk probed_buf[0..path.len];
    } else "";
    try paint(e);
    if (path.len == 0) {
        probe = .unavailable;
        probe_message = "Type the folder's path.";
        return paint(e);
    }
    try invoke(e, .probe, .{ .kind = kind, .location = path });
}

fn invoke(e: *ui.Engine, req: Request, args: anytype) !void {
    const name = switch (req) {
        .info => "sync_info",
        .now => "sync_now",
        .probe => "sync_probe",
        .setup => "sync_setup",
        .join => "sync_join",
        .stop => "sync_stop",
    };
    try ui.invoke(e, @intFromEnum(req), name, args);
}

/// One button per backend (connectors.kinds), the chosen one lit.
fn paintKinds(e: *ui.Engine) !void {
    var ids: [sync.connectors.kinds.len]i64 = undefined;
    for (sync.connectors.kinds, 0..) |k, i| {
        ids[i] = try view.mountRow(st.ConnChoice, e, st.conn_rows, st.conn_styles, i, &.{});
        const btn = st.ConnChoice.id("btn", ids[i]);
        try w.label(e, btn, k.label);
        try w.choose(e, btn, std.mem.eql(u8, kind, k.id));
    }
    try view.stamp(e, sid("conn-choices"), &ids);
}

/// The location field: the chosen backend's default (empty when none).
fn setDefaultLocation(e: *ui.Engine) !void {
    var a = std.heap.ArenaAllocator.init(e.gpa);
    defer a.deinit();
    const location = try sync.connectors.defaultLocation(kind, st.home, a.allocator());
    try w.setField(e, sid("sync-path"), location orelse "");
}

fn fieldEmpty(e: *ui.Engine) bool {
    return w.fieldValue(e, sid("sync-path")).len == 0;
}

fn clearPassphrases(e: *ui.Engine) !void {
    try w.setField(e, sid("sync-pass"), "");
    try w.setField(e, sid("sync-pass2"), "");
}

fn busyText(e: *ui.Engine, text: []const u8) !void {
    try w.text(e, sid("sync-busy"), text);
    e.tree.layout();
}

fn statusFail(e: *ui.Engine, message: []const u8) !bool {
    view.status(e, message);
    return true;
}

/// "12 s ago", "5 min ago", "3 h ago".
fn ago(buf: []u8, t_ms: i64) []const u8 {
    const now = std.Io.Clock.real.now(st.io).toMilliseconds();
    const s = @max(0, @divTrunc(now - t_ms, 1000));
    return (if (s < 90)
        std.fmt.bufPrint(buf, "{d} s ago", .{s})
    else if (s < 90 * 60)
        std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(s, 60)})
    else
        std.fmt.bufPrint(buf, "{d} h ago", .{@divTrunc(s, 3600)})) catch "";
}
