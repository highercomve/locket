//! Sharing the vault between machines through a connector: setting it up
//! on the first machine, joining it from the others, and syncing.
//!
//! The shared area holds `key.json` (the vault key wrapped with the
//! passphrase: keywrap.zig) and `vault.enc` (the vault sealed with that
//! key, like the local one). Every machine keeps its own full vault and
//! syncs it:
//!
//!   1. read the shared vault and any conflict copies the backend made
//!      (no lock held: a slow network read never blocks the vault);
//!   2. lock the local vault, merge them all into it (store.merge),
//!      save it if it changed, unlock;
//!   3. if the shared vault isn't what was merged, write the merge back
//!      and remove the conflict copies, unless the shared vault changed
//!      meanwhile: then go round again (at most three times).
//!
//! Nothing is ever lost to a race: a write another machine made between
//! 1 and 3 is either seen by the re-check or kept by the backend as a
//! conflict copy, merged on the next sync.
//! @atlas layer: sync

const std = @import("std");
const vault = @import("../vault.zig");
const store = @import("../store.zig");
const config = @import("../config.zig");
const keywrap = @import("keywrap.zig");
const connectors = @import("connectors.zig");
const connector_mod = @import("connector.zig");
const Connector = connector_mod.Connector;
const Expect = connector_mod.Expect;
const Wiping = @import("../wiping.zig").Wiping;

pub const shared_vault = "vault.enc";
const status_file = "sync-status.json";
const max_rounds = 3;
/// Conflict copies merged per round: the rest wait for the next sync (a
/// shared folder full of "copies" can't exhaust memory).
const max_copies = 16;

pub const Report = struct {
    /// The local vault took changes from the shared one.
    pulled: bool = false,
    /// The shared vault was written.
    pushed: bool = false,
    /// Conflict copies merged and removed.
    copies: usize = 0,
};

/// What `locket sync status` and the settings page show.
pub const Status = struct {
    t: i64 = 0,
    ok: bool = false,
    message: []const u8 = "",
};

/// What the sync's errors mean, worded for people. Null for others.
pub fn describe(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NomadFsNotRunning => "NomadFS isn't running here, or is too old to have its local API: start or update NomadFS, then sync again",
        error.NomadFsNotSynced => "NomadFS hasn't synced with your other devices since it started: it'll be ready in a moment",
        error.NomadFsUnavailable => "the shared vault's data isn't reachable right now (the devices that hold it are offline)",
        error.NomadFsNoSwarm => "this NomadFS has no swarm folder, or its API answered something else",
        error.NomadFsBadAnswer => "NomadFS answered something Locket doesn't understand (update NomadFS?)",
        error.NomadFsTooLarge => "the vault is larger than NomadFS takes (8 MiB)",
        error.FolderMissing => "the sync folder doesn't exist (an unmounted share?)",
        error.FolderNotAbsolute => "the sync folder must be an absolute path",
        error.NotShared => "there's no shared vault there yet: set one up from a machine that has your secrets",
        error.AlreadyShared => "there's a shared vault there already: join it with its passphrase",
        error.WrongPassphrase => "that passphrase doesn't open the shared vault",
        error.WeakPassphrase => "the passphrase must be at least 8 characters",
        error.CorruptKeyFile => "the shared key file (key.json) is damaged",
        error.NewerKeyFile => "the shared key file (key.json) was written by a newer Locket: update Locket",
        error.KeyMismatch => "this machine's key doesn't open the shared vault: join it again with the passphrase",
        error.CorruptSharedVault => "the shared vault opens with this key but is damaged (or from a newer Locket): this machine's vault is untouched",
        error.NewerSharedVault => "another machine shares the vault from a newer Locket: update Locket here (this machine's vault is untouched)",
        error.SharedVaultWithoutKey => "there's a shared vault there without its key file (key.json): wait for it to sync, or remove that locket folder to start over",
        error.ObjectTooLarge => "a file in the shared area is larger than Locket reads (8 MiB)",
        error.FolderAreaNotDirectory => "the sync folder's locket entry isn't a directory (a link?): Locket won't follow it",
        error.FolderFileIsLink => "a file in the shared area is a link: Locket won't follow it",
        error.NotConfigured => "this vault isn't shared: set up or join a shared vault first",
        error.SyncBusy => "the shared vault kept changing while syncing: try again",
        error.UnknownConnector => "unknown sync connector",
        else => null,
    };
}

/// The connector the settings name, or null when the vault isn't shared.
pub fn configured(io: std.Io, arena: std.mem.Allocator, data_path: []const u8) !?Connector {
    const cfg = try config.load(io, arena, data_path);
    const s = cfg.sync orelse return null;
    return try connectors.make(arena, s.connector, s.location);
}

/// Syncs when the vault is shared, recording how it went; null when it
/// isn't shared. The error is returned too (callers warn and go on with
/// the local vault).
pub fn syncIfShared(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8) !?Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try configured(io, arena.allocator(), data_path) orelse return null;
    return try syncRecorded(io, gpa, data_path, c);
}

/// `sync`, with its outcome written to sync-status.json.
fn syncRecorded(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, c: Connector) !Report {
    const report = sync(io, gpa, data_path, c) catch |err| {
        recordStatus(io, gpa, data_path, false, describe(err) orelse @errorName(err));
        return err;
    };
    recordStatus(io, gpa, data_path, true, summary(report));
    return report;
}

/// A sync's outcome, in a few words.
pub fn summary(r: Report) []const u8 {
    if (r.copies > 0) return "synced; merged edits made on two machines at once";
    if (r.pulled and r.pushed) return "synced both ways";
    if (r.pulled) return "synced; took changes from other machines";
    if (r.pushed) return "synced; shared this machine's changes";
    return "up to date";
}

/// One sync with the shared vault (see the file's comment).
pub fn sync(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, c: Connector) !Report {
    // Every store decrypted or merged here holds every secret: zeroed when freed.
    var wiping: Wiping = .{ .child = gpa };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    try c.check(io, a);
    if (try c.readOptional(io, a, keywrap.file) == null) return error.NotShared;

    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const remote = try fetch(io, a, c);
        const merged = try mergeLocal(io, a, data_path, remote);
        const sealed = merged.push orelse return merged.report;
        if (!try push(io, a, c, remote, sealed)) continue; // written meanwhile: again
        for (merged.copies) |cp| {
            // A copy edited again since it was read stays for the next sync.
            c.remove(io, a, cp.name, expectOf(cp.version)) catch {};
        }
        var report = merged.report;
        report.pushed = true;
        report.copies = merged.copies.len;
        return report;
    }
    return error.SyncBusy;
}

/// A file of the shared area, as read.
const Copy = struct { name: []const u8, data: []const u8, version: ?[]const u8 };

/// The shared vault and the conflict copies, as one sync round read them.
const Remote = struct {
    main: ?Copy,
    copies: []const Copy,
};

/// 1. Reads the shared vault and its conflict copies (no lock held).
fn fetch(io: std.Io, a: std.mem.Allocator, c: Connector) !Remote {
    const main: ?Copy = if (try c.readOptional(io, a, shared_vault)) |o| .{ .name = shared_vault, .data = o.data, .version = o.version } else null;
    var copies: std.ArrayListUnmanaged(Copy) = .empty;
    for (try c.list(io, a)) |name| {
        if (!c.isCopyOf(name, shared_vault)) continue;
        if (copies.items.len >= max_copies) break;
        const obj = try c.readOptional(io, a, name) orelse continue;
        try copies.append(a, .{ .name = name, .data = obj.data, .version = obj.version });
    }
    return .{ .main = main, .copies = copies.items };
}

const Merged = struct {
    report: Report = .{},
    /// The merge, sealed, when the shared vault isn't it yet.
    push: ?[]u8 = null,
    /// The conflict copies merged (and so to remove once pushed).
    copies: []const Copy = &.{},
};

/// 2. Merges the remote copies into the local vault, under its lock.
fn mergeLocal(io: std.Io, a: std.mem.Allocator, data_path: []const u8, remote: Remote) !Merged {
    var v = try vault.open(io, a, data_path, .write);
    defer v.close();
    var out: Merged = .{};
    var merged = v.store;
    var main_digest: ?[32]u8 = null;
    if (remote.main) |m| {
        const s = vault.unseal(a, v.key, m.data) catch |e| return sharedError(e);
        main_digest = try store.digest(a, &s);
        merged = try store.merge(a, &merged, &s);
    }
    var copies: std.ArrayListUnmanaged(Copy) = .empty;
    for (remote.copies) |cp| {
        // A copy this key can't open isn't ours to merge: it stays, and so
        // do its edits (it's never removed).
        const s = vault.unseal(a, v.key, cp.data) catch continue;
        merged = try store.merge(a, &merged, &s);
        try copies.append(a, cp);
    }
    out.copies = copies.items;
    const merged_digest = try store.digest(a, &merged);
    if (!std.mem.eql(u8, &merged_digest, &(try store.digest(a, &v.store)))) {
        v.replaceStore(merged);
        try v.save();
        out.report.pulled = true;
    }
    const same = if (main_digest) |d| std.mem.eql(u8, &d, &merged_digest) else false;
    if (!same or out.copies.len > 0) out.push = try vault.seal(a, io, v.key, &v.store);
    return out;
}

/// 3. Writes the merge over the shared vault the round read; false when
/// someone wrote it meanwhile (a versioned backend checks atomically, a
/// plain folder by a re-read).
fn push(io: std.Io, a: std.mem.Allocator, c: Connector, remote: Remote, sealed: []const u8) !bool {
    if (c.versioned()) {
        const expect: Expect = if (remote.main) |m| expectOf(m.version) else .absent;
        c.write(io, a, shared_vault, sealed, expect) catch |e| switch (e) {
            error.Changed => return false,
            else => return e,
        };
        return true;
    }
    const now = try c.readOptional(io, a, shared_vault);
    if (!sameBytes(if (now) |o| o.data else null, if (remote.main) |m| m.data else null)) return false;
    try c.write(io, a, shared_vault, sealed, .any);
    return true;
}

/// The shared vault's unseal errors, as the sync's: a key that doesn't
/// open it, or a vault that opens but isn't one.
fn sharedError(err: anyerror) anyerror {
    return switch (err) {
        error.WrongKey => error.KeyMismatch,
        error.CorruptVault => error.CorruptSharedVault,
        error.NewerVault => error.NewerSharedVault,
        else => err,
    };
}

fn expectOf(version: ?[]const u8) Expect {
    return if (version) |ver| .{ .version = ver } else .any;
}

fn sameBytes(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

/// Shares this machine's vault at `path` through connector `kind`: the
/// vault key, wrapped with `passphrase`, and the vault. The first machine
/// does this; the others `join`.
pub fn setup(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, kind: []const u8, location: []const u8, passphrase: []const u8) !Report {
    var wiping: Wiping = .{ .child = gpa };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const c = try ready(io, a, kind, location);
    if (passphrase.len < keywrap.min_passphrase) return error.WeakPassphrase;
    if (try c.readOptional(io, a, keywrap.file) != null) return error.AlreadyShared;
    // A shared vault without its key: another machine's, half removed or
    // with key.json not synced yet. Never sealed over with a new key.
    if (try c.readOptional(io, a, shared_vault) != null) return error.SharedVaultWithoutKey;
    {
        var v = try vault.open(io, a, data_path, .write);
        defer v.close();
        const wrapped = try keywrap.wrap(io, a, v.key, passphrase, wrap_params);
        // Only where none is: two machines setting up at once can't both win.
        c.write(io, a, keywrap.file, wrapped, .absent) catch |e| return if (e == error.Changed) error.AlreadyShared else e;
        try saveSync(io, a, data_path, kind, location);
    }
    return syncRecorded(io, gpa, data_path, c);
}

/// Joins the vault shared at `path`: unwraps its key with `passphrase`,
/// merges this machine's vault into the shared one, and keeps the shared
/// key from now on (re-sealing the local vault with it).
pub fn join(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, kind: []const u8, location: []const u8, passphrase: []const u8) !Report {
    var wiping: Wiping = .{ .child = gpa };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const c = try ready(io, a, kind, location);
    const wrapped = try c.readOptional(io, a, keywrap.file) orelse return error.NotShared;
    var key = try keywrap.unwrap(io, a, wrapped.data, passphrase);
    defer std.crypto.secureZero(u8, &key);
    const main: ?[]const u8 = if (try c.readOptional(io, a, shared_vault)) |o| o.data else null;
    {
        var v = try vault.open(io, a, data_path, .write);
        defer v.close();
        if (!std.mem.eql(u8, &key, &v.key)) {
            if (main) |m| {
                const remote = vault.unseal(a, key, m) catch |e| return sharedError(e);
                v.replaceStore(try store.merge(a, &v.store, &remote));
            }
            try v.rekey(key);
        }
        try saveSync(io, a, data_path, kind, location);
    }
    return syncRecorded(io, gpa, data_path, c);
}

/// Stops syncing this machine. The shared vault, and the other machines,
/// are left as they are; this machine keeps its vault and the shared key.
pub fn stop(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var v = try vault.open(io, a, data_path, .write); // the lock, for config.json
    defer v.close();
    var cfg = try config.load(io, a, data_path);
    if (cfg.sync == null) return error.NotConfigured;
    cfg.sync = null;
    try config.save(io, a, data_path, cfg);
}

/// Whether there is a shared vault at `location` (key.json is there).
pub fn isShared(io: std.Io, gpa: std.mem.Allocator, kind: []const u8, location: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try connectors.make(arena.allocator(), kind, location);
    try c.check(io, arena.allocator());
    return try c.readOptional(io, arena.allocator(), keywrap.file) != null;
}

/// A connector of `kind` at `location`, ready to use (or why not).
fn ready(io: std.Io, a: std.mem.Allocator, kind: []const u8, location: []const u8) !Connector {
    const c = try connectors.make(a, kind, location);
    try c.check(io, a);
    return c;
}

/// The Argon2id cost of new wraps (tests lower it).
var wrap_params = keywrap.default_params;

fn saveSync(io: std.Io, a: std.mem.Allocator, data_path: []const u8, kind: []const u8, location: []const u8) !void {
    var cfg = try config.load(io, a, data_path);
    cfg.sync = .{ .connector = kind, .location = location };
    try config.save(io, a, data_path, cfg);
}

/// Writes the last sync's outcome to sync-status.json (best effort: a
/// status that can't be written isn't worth failing a sync over).
pub fn recordStatus(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, ok: bool, message: []const u8) void {
    const status: Status = .{ .t = std.Io.Clock.real.now(io).toMilliseconds(), .ok = ok, .message = message };
    const json = std.json.Stringify.valueAlloc(gpa, status, .{}) catch return;
    defer gpa.free(json);
    const path = std.fs.path.join(gpa, &.{ data_path, status_file }) catch return;
    defer gpa.free(path);
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .permissions = vault.owner_only }) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, json) catch {};
}

/// The last sync's outcome, or null when there has been none.
pub fn loadStatus(io: std.Io, arena: std.mem.Allocator, data_path: []const u8) ?Status {
    const path = std.fs.path.join(arena, &.{ data_path, status_file }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 10)) catch return null;
    return std.json.parseFromSliceLeaky(Status, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Two machines (two data directories) and a shared folder, all in a
/// temp directory.
const World = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    shared: []const u8,
    a: []const u8,
    b: []const u8,

    fn init() !World {
        var w: World = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .shared = "", .a = "", .b = "" };
        const al = w.arena.allocator();
        const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, try std.fmt.allocPrint(al, ".zig-cache/tmp/{s}", .{w.tmp.sub_path}), al);
        w.shared = try std.fs.path.join(al, &.{ base, "Swarm" });
        w.a = try std.fs.path.join(al, &.{ base, "machine-a" });
        w.b = try std.fs.path.join(al, &.{ base, "machine-b" });
        try std.Io.Dir.cwd().createDirPath(testing.io, w.shared);
        wrap_params = .{ .t = 1, .m = 8 * 1024, .p = 1 }; // fast, for tests
        return w;
    }

    fn deinit(w: *World) void {
        w.arena.deinit();
        w.tmp.cleanup();
    }

    fn set(w: *World, machine: []const u8, p: []const u8, ws: []const u8, name: []const u8, value: []const u8) !void {
        _ = w;
        var v = try vault.open(testing.io, testing.allocator, machine, .write);
        defer v.close();
        try v.setSecret(p, ws, name, value);
        try v.save();
    }

    fn get(w: *World, machine: []const u8, p: []const u8, ws: []const u8, name: []const u8) !?[]const u8 {
        var v = try vault.open(testing.io, testing.allocator, machine, .read);
        defer v.close();
        const value = v.secret(p, ws, name) orelse return null;
        return try w.arena.allocator().dupe(u8, value);
    }

    fn connector(w: *World) !Connector {
        return connectors.make(w.arena.allocator(), "folder", w.shared);
    }
};

test "set up on one machine, join from another, and edits travel both ways" {
    var w = try World.init();
    defer w.deinit();
    const io = testing.io;
    const g = testing.allocator;

    try w.set(w.a, "hub", "stage", "TOKEN", "from-a");
    try w.set(w.b, "infra", "default", "HCLOUD", "from-b");
    try testing.expectError(error.NotShared, join(io, g, w.b, "folder", w.shared, "a good passphrase"));

    _ = try setup(io, g, w.a, "folder", w.shared, "a good passphrase");
    try testing.expectError(error.AlreadyShared, setup(io, g, w.b, "folder", w.shared, "another passphrase"));
    try testing.expectError(error.WrongPassphrase, join(io, g, w.b, "folder", w.shared, "the wrong passphrase"));
    _ = try join(io, g, w.b, "folder", w.shared, "a good passphrase");

    // b has a's secret and kept its own; a gets b's on its next sync.
    try testing.expectEqualStrings("from-a", (try w.get(w.b, "hub", "stage", "TOKEN")).?);
    try testing.expectEqualStrings("from-b", (try w.get(w.b, "infra", "default", "HCLOUD")).?);
    _ = (try syncIfShared(io, g, w.a)).?;
    try testing.expectEqualStrings("from-b", (try w.get(w.a, "infra", "default", "HCLOUD")).?);

    // An edit on a reaches b.
    try w.set(w.a, "hub", "stage", "TOKEN", "rotated");
    _ = (try syncIfShared(io, g, w.a)).?;
    _ = (try syncIfShared(io, g, w.b)).?;
    try testing.expectEqualStrings("rotated", (try w.get(w.b, "hub", "stage", "TOKEN")).?);

    // Nothing new: nothing written.
    const quiet = (try syncIfShared(io, g, w.b)).?;
    try testing.expect(!quiet.pulled and !quiet.pushed);
    try testing.expect(loadStatus(io, w.arena.allocator(), w.b).?.ok);
}

test "a deletion on one machine reaches the other" {
    var w = try World.init();
    defer w.deinit();
    const io = testing.io;
    const g = testing.allocator;
    try w.set(w.a, "hub", "stage", "TOKEN", "x");
    _ = try setup(io, g, w.a, "folder", w.shared, "a good passphrase");
    _ = try join(io, g, w.b, "folder", w.shared, "a good passphrase");
    {
        var v = try vault.open(io, g, w.a, .write);
        defer v.close();
        try testing.expect(v.removeSecret("hub", "stage", "TOKEN"));
        try v.save();
    }
    _ = (try syncIfShared(io, g, w.a)).?;
    _ = (try syncIfShared(io, g, w.b)).?;
    try testing.expect(try w.get(w.b, "hub", "stage", "TOKEN") == null);
}

test "conflict copies the backend made are merged and removed" {
    var w = try World.init();
    defer w.deinit();
    const io = testing.io;
    const g = testing.allocator;
    const al = w.arena.allocator();
    try w.set(w.a, "hub", "default", "A", "1");
    _ = try setup(io, g, w.a, "folder", w.shared, "a good passphrase");
    _ = try join(io, g, w.b, "folder", w.shared, "a good passphrase");

    // Both machines edit, then both write the shared vault "at once": the
    // backend keeps b's write as a conflict copy, as NomadFS would.
    try w.set(w.a, "hub", "default", "FROM_A", "a");
    try w.set(w.b, "hub", "default", "FROM_B", "b");
    const c = try w.connector();
    var key: [vault.key_len]u8 = undefined;
    {
        var v = try vault.open(io, al, w.b, .read);
        defer v.close();
        key = v.key;
        try c.write(io, al, "vault (conflict from b).enc", try vault.seal(al, io, key, &v.store), .any);
    }
    _ = (try syncIfShared(io, g, w.a)).?;
    try testing.expectEqualStrings("b", (try w.get(w.a, "hub", "default", "FROM_B")).?);
    for (try c.list(io, al)) |name| try testing.expect(!c.isCopyOf(name, shared_vault));
    _ = (try syncIfShared(io, g, w.b)).?;
    try testing.expectEqualStrings("a", (try w.get(w.b, "hub", "default", "FROM_A")).?);
}

test "a conflict copy this key can't open is left alone, not deleted" {
    var w = try World.init();
    defer w.deinit();
    const io = testing.io;
    const g = testing.allocator;
    const al = w.arena.allocator();
    try w.set(w.a, "hub", "default", "A", "1");
    _ = try setup(io, g, w.a, "folder", w.shared, "a good passphrase");
    const c = try w.connector();
    const foreign: [vault.key_len]u8 = @splat(3);
    var s: store.Store = .{};
    try c.write(io, al, "vault (conflict from x).enc", try vault.seal(al, io, foreign, &s), .any);
    try w.set(w.a, "hub", "default", "B", "2"); // something to push
    const r = (try syncIfShared(io, g, w.a)).?;
    try testing.expectEqual(@as(usize, 0), r.copies);
    try testing.expect(try c.readOptional(io, al, "vault (conflict from x).enc") != null);
}

test "an unshared vault doesn't sync; stop keeps the vault" {
    var w = try World.init();
    defer w.deinit();
    const io = testing.io;
    const g = testing.allocator;
    try w.set(w.a, "hub", "default", "A", "1");
    try testing.expect(try syncIfShared(io, g, w.a) == null);
    try testing.expectError(error.NotConfigured, stop(io, g, w.a));
    _ = try setup(io, g, w.a, "folder", w.shared, "a good passphrase");
    try testing.expect(try isShared(io, g, "folder", w.shared));
    try stop(io, g, w.a);
    try testing.expect(try syncIfShared(io, g, w.a) == null);
    try testing.expectEqualStrings("1", (try w.get(w.a, "hub", "default", "A")).?);
}

test "setup refuses a shared vault without its key, and a damaged shared vault isn't a key mismatch" {
    var w = try World.init();
    defer w.deinit();
    const io = testing.io;
    const g = testing.allocator;
    const al = w.arena.allocator();
    try w.set(w.a, "hub", "default", "A", "1");
    const c = try w.connector();

    // vault.enc there, key.json not (yet): never sealed over.
    try c.write(io, al, shared_vault, "someone else's", .any);
    try testing.expectError(error.SharedVaultWithoutKey, setup(io, g, w.a, "folder", w.shared, "a good passphrase"));
    try c.remove(io, al, shared_vault, .any);
    _ = try setup(io, g, w.a, "folder", w.shared, "a good passphrase");

    // Sealed with the shared key, but not a vault.
    var v = try vault.open(io, al, w.a, .read);
    const key = v.key;
    v.close();
    var junk: [64]u8 = undefined;
    const nonce: [12]u8 = @splat(1);
    var tag: [16]u8 = undefined;
    const plain = "not json";
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(junk[12..][0..plain.len], &tag, plain, "locket/v1", nonce, key);
    @memcpy(junk[0..12], &nonce);
    @memcpy(junk[12 + plain.len ..][0..16], &tag);
    try c.write(io, al, shared_vault, junk[0 .. 12 + plain.len + 16], .any);
    try testing.expectError(error.CorruptSharedVault, sync(io, g, w.a, c));
    // Another key's vault: a mismatch.
    const other: [vault.key_len]u8 = @splat(3);
    var empty: store.Store = .{};
    try c.write(io, al, shared_vault, try vault.seal(al, io, other, &empty), .any);
    try testing.expectError(error.KeyMismatch, sync(io, g, w.a, c));
    // The local vault is untouched either way.
    try testing.expectEqualStrings("1", (try w.get(w.a, "hub", "default", "A")).?);
}

test "a sync round merges a bounded number of conflict copies" {
    var w = try World.init();
    defer w.deinit();
    const io = testing.io;
    const g = testing.allocator;
    const al = w.arena.allocator();
    try w.set(w.a, "hub", "default", "A", "1");
    _ = try setup(io, g, w.a, "folder", w.shared, "a good passphrase");
    const c = try w.connector();
    const sealed = (try c.read(io, al, shared_vault)).data;
    for (0..max_copies + 4) |i| {
        try c.write(io, al, try std.fmt.allocPrint(al, "vault (conflict {d}).enc", .{i}), sealed, .any);
    }
    const first = try sync(io, g, w.a, c);
    try testing.expectEqual(@as(usize, max_copies), first.copies);
    const second = try sync(io, g, w.a, c);
    try testing.expectEqual(@as(usize, 4), second.copies);
}
