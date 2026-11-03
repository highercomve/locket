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
const Connector = @import("connector.zig").Connector;

pub const shared_vault = "vault.enc";
const status_file = "sync-status.json";
const max_rounds = 3;

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
        error.NomadFsNotMounted => "NomadFS isn't mounted here: start NomadFS and turn on Mount devices, or check the swarm folder's path",
        error.FolderMissing => "the sync folder doesn't exist (an unmounted share?)",
        error.FolderNotAbsolute => "the sync folder must be an absolute path",
        error.NotShared => "there's no shared vault there yet: set one up from a machine that has your secrets",
        error.AlreadyShared => "there's a shared vault there already: join it with its passphrase",
        error.WrongPassphrase => "that passphrase doesn't open the shared vault",
        error.WeakPassphrase => "the passphrase must be at least 8 characters",
        error.CorruptKeyFile => "the shared key file (key.json) is damaged",
        error.KeyMismatch => "this machine's key doesn't open the shared vault: join it again with the passphrase",
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
    return try connectors.make(arena, s.connector, s.path);
}

/// Syncs when the vault is shared, recording how it went; null when it
/// isn't shared. The error is returned too (callers warn and go on with
/// the local vault).
pub fn syncIfShared(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8) !?Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try configured(io, arena.allocator(), data_path) orelse return null;
    const report = sync(io, gpa, data_path, c) catch |err| {
        recordStatus(io, gpa, data_path, false, describe(err) orelse @errorName(err));
        return err;
    };
    recordStatus(io, gpa, data_path, true, summary(report));
    return report;
}

fn summary(r: Report) []const u8 {
    if (r.copies > 0) return "synced; merged edits made on two machines at once";
    if (r.pulled and r.pushed) return "synced both ways";
    if (r.pulled) return "synced; took changes from other machines";
    if (r.pushed) return "synced; shared this machine's changes";
    return "up to date";
}

/// One sync with the shared vault (see the file's comment).
pub fn sync(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, c: Connector) !Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try c.check(io);
    if (try c.readOptional(io, a, keywrap.file) == null) return error.NotShared;

    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        // 1. The shared vault and the conflict copies, without the lock.
        const main = try c.readOptional(io, a, shared_vault);
        var copy_names: std.ArrayListUnmanaged([]const u8) = .empty;
        var copy_data: std.ArrayListUnmanaged([]const u8) = .empty;
        for (try c.list(io, a)) |name| {
            if (!c.isCopyOf(name, shared_vault)) continue;
            const data = try c.readOptional(io, a, name) orelse continue;
            try copy_names.append(a, name);
            try copy_data.append(a, data);
        }

        // 2. Merge into the local vault, under its lock.
        var report: Report = .{};
        var push: ?[]u8 = null;
        {
            var v = try vault.open(io, a, data_path, .write);
            defer v.close();
            var merged = v.store;
            var main_digest: ?[32]u8 = null;
            if (main) |m| {
                const remote = vault.unseal(a, v.key, m) catch |e| return if (e == error.CorruptVault) error.KeyMismatch else e;
                main_digest = try store.digest(a, &remote);
                merged = try store.merge(a, &merged, &remote);
            }
            for (copy_data.items) |data| {
                // A copy this key can't open isn't ours to merge: it stays.
                const copy = vault.unseal(a, v.key, data) catch continue;
                merged = try store.merge(a, &merged, &copy);
            }
            const merged_digest = try store.digest(a, &merged);
            if (!std.mem.eql(u8, &merged_digest, &(try store.digest(a, &v.store)))) {
                v.replaceStore(merged);
                try v.save();
                report.pulled = true;
            }
            const same = if (main_digest) |d| std.mem.eql(u8, &d, &merged_digest) else false;
            if (!same or copy_names.items.len > 0) push = try vault.seal(a, io, v.key, &v.store);
        }

        // 3. Share the merge, unless someone wrote meanwhile.
        const sealed = push orelse return report;
        const now = try c.readOptional(io, a, shared_vault);
        if (!sameBytes(now, main)) continue;
        try c.write(io, a, shared_vault, sealed);
        for (copy_names.items) |name| c.remove(io, a, name) catch {};
        report.pushed = true;
        report.copies = copy_names.items.len;
        return report;
    }
    return error.SyncBusy;
}

fn sameBytes(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

/// Shares this machine's vault at `path` through connector `kind`: the
/// vault key, wrapped with `passphrase`, and the vault. The first machine
/// does this; the others `join`.
pub fn setup(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, kind: []const u8, path: []const u8, passphrase: []const u8) !Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try connectors.make(a, kind, path);
    try c.check(io);
    if (passphrase.len < keywrap.min_passphrase) return error.WeakPassphrase;
    if (try c.readOptional(io, a, keywrap.file) != null) return error.AlreadyShared;
    {
        var v = try vault.open(io, a, data_path, .write);
        defer v.close();
        const wrapped = try keywrap.wrap(io, a, v.key, passphrase, wrap_params);
        try c.write(io, a, keywrap.file, wrapped);
        try saveSync(io, a, data_path, kind, path);
    }
    return finish(io, gpa, data_path, c);
}

/// Joins the vault shared at `path`: unwraps its key with `passphrase`,
/// merges this machine's vault into the shared one, and keeps the shared
/// key from now on (re-sealing the local vault with it).
pub fn join(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, kind: []const u8, path: []const u8, passphrase: []const u8) !Report {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try connectors.make(a, kind, path);
    try c.check(io);
    const wrapped = try c.readOptional(io, a, keywrap.file) orelse return error.NotShared;
    var key = try keywrap.unwrap(io, a, wrapped, passphrase);
    defer std.crypto.secureZero(u8, &key);
    const main = try c.readOptional(io, a, shared_vault);
    {
        var v = try vault.open(io, a, data_path, .write);
        defer v.close();
        if (!std.mem.eql(u8, &key, &v.key)) {
            if (main) |m| {
                const remote = vault.unseal(a, key, m) catch |e| return if (e == error.CorruptVault) error.KeyMismatch else e;
                v.replaceStore(try store.merge(a, &v.store, &remote));
            }
            try v.rekey(key);
        }
        try saveSync(io, a, data_path, kind, path);
    }
    return finish(io, gpa, data_path, c);
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

/// Whether there is a shared vault at `path` (key.json is there).
pub fn isShared(io: std.Io, gpa: std.mem.Allocator, kind: []const u8, path: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const c = try connectors.make(arena.allocator(), kind, path);
    try c.check(io);
    return try c.readOptional(io, arena.allocator(), keywrap.file) != null;
}

/// The Argon2id cost of new wraps (tests lower it).
var wrap_params = keywrap.default_params;

fn saveSync(io: std.Io, a: std.mem.Allocator, data_path: []const u8, kind: []const u8, path: []const u8) !void {
    var cfg = try config.load(io, a, data_path);
    cfg.sync = .{ .connector = kind, .path = path };
    try config.save(io, a, data_path, cfg);
}

fn finish(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, c: Connector) !Report {
    const report = sync(io, gpa, data_path, c) catch |err| {
        recordStatus(io, gpa, data_path, false, describe(err) orelse @errorName(err));
        return err;
    };
    recordStatus(io, gpa, data_path, true, summary(report));
    return report;
}

/// Writes the last sync's outcome to sync-status.json (best effort: a
/// status that can't be written isn't worth failing a sync over).
pub fn recordStatus(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, ok: bool, message: []const u8) void {
    const status: Status = .{ .t = std.Io.Clock.real.now(io).toMilliseconds(), .ok = ok, .message = message };
    const json = std.json.Stringify.valueAlloc(gpa, status, .{}) catch return;
    defer gpa.free(json);
    const path = std.fs.path.join(gpa, &.{ data_path, status_file }) catch return;
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json }) catch {};
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
        try c.write(io, al, "vault (conflict from b).enc", try vault.seal(al, io, key, &v.store));
    }
    _ = (try syncIfShared(io, g, w.a)).?;
    try testing.expectEqualStrings("b", (try w.get(w.a, "hub", "default", "FROM_B")).?);
    for (try c.list(io, al)) |name| try testing.expect(!c.isCopyOf(name, shared_vault));
    _ = (try syncIfShared(io, g, w.b)).?;
    try testing.expectEqualStrings("a", (try w.get(w.b, "hub", "default", "FROM_A")).?);
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
