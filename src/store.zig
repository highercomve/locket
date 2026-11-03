//! The vault's data: projects → workspaces → secrets, every entry stamped
//! with when and where it last changed, and tombstones for what was
//! deleted. The stamps make two copies of a vault mergeable (`merge`):
//! that is how machines that share a vault through a sync connector
//! (src/sync/) reconcile edits made apart.
//!
//! A `Stamp` is a time in milliseconds and the id of the device that made
//! the change; a newer stamp wins, the device breaks ties. A tombstone at
//! a path removes the entry there, and everything under it, that is
//! older than the tombstone: a project deleted on one machine stays
//! deleted, unless another machine edited something in it afterwards.
//!
//! `vault.json`, version 3:
//!
//!     { "version": 3,
//!       "projects": { "<project>": { "t": <ms>, "d": "<device>", "description": "...",
//!         "workspaces": { "<workspace>": { "t": ..., "d": "...",
//!           "secrets": { "<NAME>": { "v": "<value>", "t": ..., "d": "..." } } } } } },
//!       "tombstones": { "<project>[/<workspace>[/<NAME>]]": { "t": ..., "d": "..." } } }
//!
//! Versions 1 and 2 (no stamps) open with every stamp zero: the oldest,
//! so any real edit wins over them.
//!
//! Allocation: a Store is meant to live in an arena; `free` releases one
//! built with a general allocator, zeroing the values.
//! @atlas layer: core

const std = @import("std");

pub const version = 3;

/// Every project's own workspace, always first; it can't be renamed or
/// removed.
pub const default_workspace = "default";

pub fn isDefault(workspace_name: []const u8) bool {
    return std.mem.eql(u8, workspace_name, default_workspace);
}

pub const Stamp = struct {
    /// Milliseconds since the Unix epoch (kept increasing: see Vault.stamp).
    t: i64 = 0,
    /// The device that made the change (config.zig).
    d: u64 = 0,

    pub fn newer(a: Stamp, b: Stamp) bool {
        return a.t > b.t or (a.t == b.t and a.d > b.d);
    }

    pub fn max(a: Stamp, b: Stamp) Stamp {
        return if (b.newer(a)) b else a;
    }
};

pub const Secret = struct {
    value: []const u8,
    stamp: Stamp = .{},
};

pub const Secrets = std.StringArrayHashMapUnmanaged(Secret);

pub const Workspace = struct {
    stamp: Stamp = .{},
    secrets: Secrets = .{},
};

pub const Workspaces = std.StringArrayHashMapUnmanaged(Workspace);

pub const Project = struct {
    description: []const u8 = "",
    stamp: Stamp = .{},
    workspaces: Workspaces = .{},

    pub fn secretCount(p: *const Project) usize {
        var n: usize = 0;
        for (p.workspaces.values()) |w| n += w.secrets.count();
        return n;
    }
};

/// Deletions, by path: `p`, `p/w` or `p/w/NAME`.
pub const Tombs = std.StringArrayHashMapUnmanaged(Stamp);

pub const Store = struct {
    projects: std.StringArrayHashMapUnmanaged(Project) = .{},
    tombs: Tombs = .{},

    /// The newest stamp anywhere in it (entries and tombstones).
    pub fn high(s: *const Store) Stamp {
        var h: Stamp = .{};
        for (s.tombs.values()) |t| h = h.max(t);
        for (s.projects.values()) |p| {
            h = h.max(p.stamp);
            for (p.workspaces.values()) |w| {
                h = h.max(w.stamp);
                for (w.secrets.values()) |x| h = h.max(x.stamp);
            }
        }
        return h;
    }

    /// The newest tombstone at `p`, `p/w` or `p/w/n` (the parts given).
    pub fn cover(s: *const Store, p: []const u8, w: ?[]const u8, n: ?[]const u8) ?Stamp {
        var buf: [3 * 129]u8 = undefined;
        var best: ?Stamp = s.tombs.get(p);
        if (w) |ws| {
            if (s.tombs.get(join(&buf, &.{ p, ws }))) |t| best = if (best) |b| b.max(t) else t;
            if (n) |name| {
                if (s.tombs.get(join(&buf, &.{ p, ws, name }))) |t| best = if (best) |b| b.max(t) else t;
            }
        }
        return best;
    }

    /// Records that `path` was deleted at `stamp` (the newer stamp stays).
    pub fn bury(s: *Store, gpa: std.mem.Allocator, path: []const u8, stamp: Stamp) !void {
        const gop = try s.tombs.getOrPut(gpa, path);
        if (gop.found_existing) {
            gop.value_ptr.* = gop.value_ptr.max(stamp);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, path) catch |e| {
                s.tombs.swapRemoveAt(gop.index);
                return e;
            };
            gop.value_ptr.* = stamp;
        }
    }
};

/// "a/b/c" from parts, into `buf` (names are at most 128 bytes).
pub fn join(buf: []u8, parts: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (parts, 0..) |part, i| {
        if (i > 0) w.writeByte('/') catch unreachable;
        w.writeAll(part) catch unreachable;
    }
    return w.buffered();
}

/// True when an entry stamped `stamp` survives the tombstones above it.
fn alive(stamp: Stamp, tomb: ?Stamp) bool {
    const t = tomb orelse return true;
    return stamp.newer(t);
}

// ---------------------------------------------------------------- default

/// Puts the default workspace first, creating it (stamped like the
/// project) if missing.
pub fn ensureDefault(gpa: std.mem.Allocator, p: *Project) !void {
    if (p.workspaces.getIndex(default_workspace)) |i| if (i == 0) return;
    var reordered: Workspaces = .{};
    errdefer reordered.deinit(gpa);
    try reordered.ensureTotalCapacity(gpa, p.workspaces.count() + 1);
    if (p.workspaces.get(default_workspace)) |w| {
        reordered.putAssumeCapacity(p.workspaces.getKey(default_workspace).?, w);
    } else {
        reordered.putAssumeCapacity(try gpa.dupe(u8, default_workspace), .{ .stamp = p.stamp });
    }
    for (p.workspaces.keys(), p.workspaces.values()) |k, w| {
        if (!isDefault(k)) reordered.putAssumeCapacity(k, w);
    }
    p.workspaces.deinit(gpa);
    p.workspaces = reordered;
}

// ------------------------------------------------------------------ merge

/// Two copies of a vault, merged: every entry is the newer of its two
/// versions, tombstones are the union, and what a tombstone covers is
/// gone unless it changed after the deletion (then its parents come back
/// with it). Commutative and idempotent; the order of `a` comes first.
/// The result's strings are new allocations in `gpa` (use an arena).
pub fn merge(gpa: std.mem.Allocator, a: *const Store, b: *const Store) !Store {
    var out: Store = .{};
    for ([_]*const Store{ a, b }) |s| {
        for (s.tombs.keys(), s.tombs.values()) |path, t| try out.bury(gpa, path, t);
    }

    var names = try unionKeys(gpa, a.projects.keys(), b.projects.keys());
    defer names.deinit(gpa);
    for (names.keys()) |pn| {
        const pa = a.projects.getPtr(pn);
        const pb = b.projects.getPtr(pn);
        if (try mergeProject(gpa, &out, pn, pa, pb)) |p| {
            try out.projects.put(gpa, try gpa.dupe(u8, pn), p);
        }
    }
    return out;
}

fn mergeProject(gpa: std.mem.Allocator, out: *const Store, pn: []const u8, pa: ?*const Project, pb: ?*const Project) !?Project {
    const win = pickProject(pa, pb);
    var p: Project = .{ .description = try gpa.dupe(u8, win.description), .stamp = win.stamp };
    var newest_inside: ?Stamp = null;

    var ws_names = try unionKeys(gpa, if (pa) |x| x.workspaces.keys() else &.{}, if (pb) |x| x.workspaces.keys() else &.{});
    defer ws_names.deinit(gpa);
    for (ws_names.keys()) |wn| {
        const wa = if (pa) |x| x.workspaces.getPtr(wn) else null;
        const wb = if (pb) |x| x.workspaces.getPtr(wn) else null;
        var w: Workspace = .{ .stamp = maxStamp(if (wa) |x| x.stamp else null, if (wb) |x| x.stamp else null) };

        var s_names = try unionKeys(gpa, if (wa) |x| x.secrets.keys() else &.{}, if (wb) |x| x.secrets.keys() else &.{});
        defer s_names.deinit(gpa);
        var newest_secret: ?Stamp = null;
        for (s_names.keys()) |sn| {
            const sa = if (wa) |x| x.secrets.get(sn) else null;
            const sb = if (wb) |x| x.secrets.get(sn) else null;
            const s = pickSecret(sa, sb);
            if (!alive(s.stamp, out.cover(pn, wn, sn))) continue;
            try w.secrets.put(gpa, try gpa.dupe(u8, sn), .{ .value = try gpa.dupe(u8, s.value), .stamp = s.stamp });
            newest_secret = if (newest_secret) |n| n.max(s.stamp) else s.stamp;
        }

        const own = alive(w.stamp, out.cover(pn, wn, null));
        if (!own and newest_secret == null) continue; // deleted, nothing newer inside
        // Kept for a secret edited after the deletion: stamped like it.
        if (!own) w.stamp = newest_secret.?;
        try p.workspaces.put(gpa, try gpa.dupe(u8, wn), w);
        // An existing default workspace keeps nothing alive by itself.
        if (!isDefault(wn) or w.secrets.count() > 0) {
            const inside = if (newest_secret) |n| n.max(w.stamp) else w.stamp;
            newest_inside = if (newest_inside) |n| n.max(inside) else inside;
        }
    }

    if (!alive(p.stamp, out.cover(pn, null, null))) {
        const keep = newest_inside orelse return null; // deleted
        p.stamp = keep; // brought back by a later edit inside it
    }
    try ensureDefault(gpa, &p);
    return p;
}

/// `a`'s keys, then `b`'s not in `a`. The keys aren't copied.
fn unionKeys(gpa: std.mem.Allocator, a: []const []const u8, b: []const []const u8) !std.StringArrayHashMapUnmanaged(void) {
    var set: std.StringArrayHashMapUnmanaged(void) = .{};
    errdefer set.deinit(gpa);
    try set.ensureTotalCapacity(gpa, a.len + b.len);
    for (a) |k| set.putAssumeCapacity(k, {});
    for (b) |k| set.putAssumeCapacity(k, {});
    return set;
}

fn maxStamp(a: ?Stamp, b: ?Stamp) Stamp {
    if (a == null) return b orelse .{};
    if (b == null) return a.?;
    return a.?.max(b.?);
}

/// The newer project record; on equal stamps, the larger description (so
/// both sides of a merge pick the same one).
fn pickProject(a: ?*const Project, b: ?*const Project) *const Project {
    const x = a orelse return b.?;
    const y = b orelse return x;
    if (y.stamp.newer(x.stamp)) return y;
    if (x.stamp.newer(y.stamp)) return x;
    return if (std.mem.order(u8, y.description, x.description) == .gt) y else x;
}

fn pickSecret(a: ?Secret, b: ?Secret) Secret {
    const x = a orelse return b.?;
    const y = b orelse return x;
    if (y.stamp.newer(x.stamp)) return y;
    if (x.stamp.newer(y.stamp)) return x;
    return if (std.mem.order(u8, y.value, x.value) == .gt) y else x;
}

// ----------------------------------------------------------------- digest

/// A fingerprint of the content (entries, values, stamps, tombstones),
/// independent of order: two stores with the same digest hold the same
/// vault.
pub fn digest(gpa: std.mem.Allocator, s: *const Store) ![32]u8 {
    var lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (lines.items) |l| {
            std.crypto.secureZero(u8, l);
            gpa.free(l);
        }
        lines.deinit(gpa);
    }
    for (s.tombs.keys(), s.tombs.values()) |path, t| {
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "T\x00{s}\x00{d}\x00{x}", .{ path, t.t, t.d }));
    }
    for (s.projects.keys(), s.projects.values()) |pn, p| {
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "P\x00{s}\x00{d}\x00{x}\x00{s}", .{ pn, p.stamp.t, p.stamp.d, p.description }));
        for (p.workspaces.keys(), p.workspaces.values()) |wn, w| {
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "W\x00{s}/{s}\x00{d}\x00{x}", .{ pn, wn, w.stamp.t, w.stamp.d }));
            for (w.secrets.keys(), w.secrets.values()) |sn, x| {
                try lines.append(gpa, try std.fmt.allocPrint(gpa, "S\x00{s}/{s}/{s}\x00{d}\x00{x}\x00{s}", .{ pn, wn, sn, x.stamp.t, x.stamp.d, x.value }));
            }
        }
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, l: []u8, r: []u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.lt);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (lines.items) |l| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, l.len, .little);
        h.update(&len);
        h.update(l);
    }
    return h.finalResult();
}

// ------------------------------------------------------------------- json

pub fn marshal(gpa: std.mem.Allocator, s: *const Store) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    try js.objectField("version");
    try js.write(version);
    try js.objectField("projects");
    try js.beginObject();
    for (s.projects.keys(), s.projects.values()) |name, p| {
        try js.objectField(name);
        try js.beginObject();
        try writeStamp(&js, p.stamp);
        try js.objectField("description");
        try js.write(p.description);
        try js.objectField("workspaces");
        try js.beginObject();
        for (p.workspaces.keys(), p.workspaces.values()) |w_name, w| {
            try js.objectField(w_name);
            try js.beginObject();
            try writeStamp(&js, w.stamp);
            try js.objectField("secrets");
            try js.beginObject();
            for (w.secrets.keys(), w.secrets.values()) |s_name, x| {
                try js.objectField(s_name);
                try js.beginObject();
                try js.objectField("v");
                try js.write(x.value);
                try writeStamp(&js, x.stamp);
                try js.endObject();
            }
            try js.endObject();
            try js.endObject();
        }
        try js.endObject();
        try js.endObject();
    }
    try js.endObject();
    try js.objectField("tombstones");
    try js.beginObject();
    for (s.tombs.keys(), s.tombs.values()) |path, t| {
        try js.objectField(path);
        try js.beginObject();
        try writeStamp(&js, t);
        try js.endObject();
    }
    try js.endObject();
    try js.endObject();
    return out.toOwnedSlice();
}

fn writeStamp(js: *std.json.Stringify, st: Stamp) !void {
    try js.objectField("t");
    try js.write(st.t);
    try js.objectField("d");
    var buf: [16]u8 = undefined;
    try js.write(std.fmt.bufPrint(&buf, "{x:0>16}", .{st.d}) catch unreachable);
}

/// The store from its JSON (versions 1 to 3). Allocations are meant for
/// an arena: on a corrupt document, what was built so far is not freed.
pub fn unmarshal(gpa: std.mem.Allocator, plain: []const u8) !Store {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, plain, .{}) catch return error.CorruptVault;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.CorruptVault;
    const ver: i64 = switch (root.object.get("version") orelse return error.CorruptVault) {
        .integer => |i| i,
        else => return error.CorruptVault,
    };
    if (ver < 1 or ver > version) return error.CorruptVault;
    const projects = root.object.get("projects") orelse return error.CorruptVault;
    if (projects != .object) return error.CorruptVault;

    var s: Store = .{};
    var p_it = projects.object.iterator();
    while (p_it.next()) |p_entry| {
        const p_obj = p_entry.value_ptr.*;
        if (p_obj != .object) return error.CorruptVault;
        var p: Project = .{ .stamp = try readStamp(p_obj) };
        if (p_obj.object.get("description")) |d| {
            if (d == .string) p.description = try gpa.dupe(u8, d.string);
        }
        if (ver == 1) {
            // Secrets straight under the project: its `default` workspace.
            if (p_obj.object.get("secrets")) |secrets| {
                const w = try workspaceOrCreate(gpa, &p, default_workspace, .{});
                try readSecrets(gpa, secrets, &w.secrets, false);
            }
        } else if (p_obj.object.get("workspaces")) |workspaces| {
            if (workspaces != .object) return error.CorruptVault;
            var w_it = workspaces.object.iterator();
            while (w_it.next()) |w_entry| {
                const w_obj = w_entry.value_ptr.*;
                if (w_obj != .object) return error.CorruptVault;
                const w = try workspaceOrCreate(gpa, &p, w_entry.key_ptr.*, try readStamp(w_obj));
                if (w_obj.object.get("secrets")) |secrets| try readSecrets(gpa, secrets, &w.secrets, ver >= 3);
            }
        }
        try ensureDefault(gpa, &p);
        try s.projects.put(gpa, try gpa.dupe(u8, p_entry.key_ptr.*), p);
    }
    if (root.object.get("tombstones")) |tombs| {
        if (tombs != .object) return error.CorruptVault;
        var t_it = tombs.object.iterator();
        while (t_it.next()) |t| {
            if (t.value_ptr.* != .object) return error.CorruptVault;
            try s.bury(gpa, t.key_ptr.*, try readStamp(t.value_ptr.*));
        }
    }
    return s;
}

/// An entry's stamp; zero when it has none (versions 1 and 2).
fn readStamp(obj: std.json.Value) !Stamp {
    if (obj != .object) return error.CorruptVault;
    var st: Stamp = .{};
    if (obj.object.get("t")) |t| st.t = switch (t) {
        .integer => |i| std.math.cast(i64, i) orelse return error.CorruptVault,
        else => return error.CorruptVault,
    };
    if (obj.object.get("d")) |d| {
        if (d != .string) return error.CorruptVault;
        st.d = std.fmt.parseInt(u64, d.string, 16) catch return error.CorruptVault;
    }
    return st;
}

fn readSecrets(gpa: std.mem.Allocator, value: std.json.Value, out: *Secrets, stamped: bool) !void {
    if (value != .object) return error.CorruptVault;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        const secret: Secret = if (stamped) blk: {
            if (v != .object) return error.CorruptVault;
            const text = v.object.get("v") orelse return error.CorruptVault;
            if (text != .string) return error.CorruptVault;
            break :blk .{ .value = try gpa.dupe(u8, text.string), .stamp = try readStamp(v) };
        } else blk: {
            if (v != .string) return error.CorruptVault;
            break :blk .{ .value = try gpa.dupe(u8, v.string) };
        };
        try out.put(gpa, try gpa.dupe(u8, entry.key_ptr.*), secret);
    }
}

pub fn workspaceOrCreate(gpa: std.mem.Allocator, p: *Project, name: []const u8, stamp: Stamp) !*Workspace {
    const gop = try p.workspaces.getOrPut(gpa, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, name) catch |e| {
            p.workspaces.swapRemoveAt(gop.index);
            return e;
        };
        gop.value_ptr.* = .{ .stamp = stamp };
    }
    return gop.value_ptr;
}

// ------------------------------------------------------------------- free

/// Releases a store built with a general allocator, zeroing the values.
pub fn free(gpa: std.mem.Allocator, s: *Store) void {
    for (s.projects.keys(), s.projects.values()) |name, *p| {
        gpa.free(name);
        freeProject(gpa, p);
    }
    s.projects.deinit(gpa);
    for (s.tombs.keys()) |k| gpa.free(k);
    s.tombs.deinit(gpa);
    s.* = .{};
}

pub fn freeProject(gpa: std.mem.Allocator, p: *Project) void {
    gpa.free(p.description);
    for (p.workspaces.keys(), p.workspaces.values()) |k, *w| {
        gpa.free(k);
        freeSecrets(gpa, &w.secrets);
    }
    p.workspaces.deinit(gpa);
}

pub fn freeSecrets(gpa: std.mem.Allocator, secrets: *Secrets) void {
    for (secrets.keys(), secrets.values()) |k, x| {
        gpa.free(k);
        freeSecret(gpa, x);
    }
    secrets.deinit(gpa);
}

pub fn freeSecret(gpa: std.mem.Allocator, x: Secret) void {
    std.crypto.secureZero(u8, @constCast(x.value));
    gpa.free(x.value);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// A small store for the tests: "p" with `default` and "ws", one secret
/// in each, stamped at `t` by device `d`.
fn sample(a: std.mem.Allocator, t: i64, d: u64, value: []const u8) !Store {
    var s: Store = .{};
    const st: Stamp = .{ .t = t, .d = d };
    var p: Project = .{ .description = try a.dupe(u8, "desc"), .stamp = st };
    try ensureDefault(a, &p);
    const def = p.workspaces.getPtr(default_workspace).?;
    try def.secrets.put(a, try a.dupe(u8, "A"), .{ .value = try a.dupe(u8, value), .stamp = st });
    const ws = try workspaceOrCreate(a, &p, "ws", st);
    try ws.secrets.put(a, try a.dupe(u8, "B"), .{ .value = try a.dupe(u8, value), .stamp = st });
    try s.projects.put(a, try a.dupe(u8, "p"), p);
    return s;
}

test "merge: the newer value wins, both ways round, and the merge is idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try sample(a, 10, 1, "old");
    var y = try sample(a, 20, 2, "new");
    const xy = try merge(a, &x, &y);
    const yx = try merge(a, &y, &x);
    try testing.expectEqualStrings("new", xy.projects.get("p").?.workspaces.get("ws").?.secrets.get("B").?.value);
    try testing.expectEqual(try digest(a, &xy), try digest(a, &yx));
    const again = try merge(a, &xy, &y);
    try testing.expectEqual(try digest(a, &xy), try digest(a, &again));
}

test "merge: edits to different entries both survive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try sample(a, 10, 1, "v");
    var y = try sample(a, 10, 1, "v");
    // x changes A, y changes B, later.
    x.projects.getPtr("p").?.workspaces.getPtr(default_workspace).?.secrets.getPtr("A").?.* = .{ .value = "x-edit", .stamp = .{ .t = 30, .d = 1 } };
    y.projects.getPtr("p").?.workspaces.getPtr("ws").?.secrets.getPtr("B").?.* = .{ .value = "y-edit", .stamp = .{ .t = 31, .d = 2 } };
    const m = try merge(a, &x, &y);
    const p = m.projects.get("p").?;
    try testing.expectEqualStrings("x-edit", p.workspaces.get(default_workspace).?.secrets.get("A").?.value);
    try testing.expectEqualStrings("y-edit", p.workspaces.get("ws").?.secrets.get("B").?.value);
}

test "merge: a deletion removes what is older, and a later edit brings its parents back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try sample(a, 10, 1, "v");
    var y = try sample(a, 10, 1, "v");
    // x deletes the whole project at 20.
    _ = x.projects.orderedRemove("p");
    try x.bury(a, "p", .{ .t = 20, .d = 1 });
    {
        const m = try merge(a, &x, &y);
        try testing.expect(m.projects.get("p") == null);
        try testing.expect(m.tombs.get("p") != null);
    }
    // y edited B at 25, after the deletion: B, ws and p come back.
    y.projects.getPtr("p").?.workspaces.getPtr("ws").?.secrets.getPtr("B").?.* = .{ .value = "later", .stamp = .{ .t = 25, .d = 2 } };
    const m = try merge(a, &x, &y);
    const p = m.projects.get("p").?;
    try testing.expectEqualStrings("later", p.workspaces.get("ws").?.secrets.get("B").?.value);
    try testing.expect(p.workspaces.get(default_workspace).?.secrets.get("A") == null); // older than the deletion
    try testing.expectEqualStrings(default_workspace, p.workspaces.keys()[0]);
}

test "merge: a deleted secret stays deleted; re-adding it later wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try sample(a, 10, 1, "v");
    var y = try sample(a, 10, 1, "v");
    _ = x.projects.getPtr("p").?.workspaces.getPtr("ws").?.secrets.orderedRemove("B");
    try x.bury(a, "p/ws/B", .{ .t = 20, .d = 1 });
    try testing.expect((try merge(a, &y, &x)).projects.get("p").?.workspaces.get("ws").?.secrets.get("B") == null);
    try y.projects.getPtr("p").?.workspaces.getPtr("ws").?.secrets.put(a, "B", .{ .value = "again", .stamp = .{ .t = 40, .d = 2 } });
    try testing.expectEqualStrings("again", (try merge(a, &y, &x)).projects.get("p").?.workspaces.get("ws").?.secrets.get("B").?.value);
}

test "merge: equal stamps with different values pick the same one on both sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try sample(a, 0, 0, "aaa");
    var y = try sample(a, 0, 0, "zzz");
    try testing.expectEqual(try digest(a, &(try merge(a, &x, &y))), try digest(a, &(try merge(a, &y, &x))));
}

test "json: v3 round-trips stamps and tombstones; v1 and v2 open with zero stamps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try sample(a, 1234, 0xabc, "v");
    try s.bury(a, "gone/ws", .{ .t = 99, .d = 7 });
    const back = try unmarshal(a, try marshal(a, &s));
    try testing.expectEqual(try digest(a, &s), try digest(a, &back));
    try testing.expectEqual(@as(u64, 0xabc), back.projects.get("p").?.stamp.d);

    const v1 = try unmarshal(a,
        \\{"version":1,"projects":{"hub":{"description":"d","secrets":{"K":"v"}}}}
    );
    const k = v1.projects.get("hub").?.workspaces.get(default_workspace).?.secrets.get("K").?;
    try testing.expectEqualStrings("v", k.value);
    try testing.expectEqual(@as(i64, 0), k.stamp.t);
    const v2 = try unmarshal(a,
        \\{"version":2,"projects":{"hub":{"description":"","workspaces":{"stage":{"secrets":{"K":"s"}}}}}}
    );
    try testing.expectEqualStrings("s", v2.projects.get("hub").?.workspaces.get("stage").?.secrets.get("K").?.value);
    try testing.expectError(error.CorruptVault, unmarshal(a, "{\"version\":9,\"projects\":{}}"));
}

test "free releases a store built with a general allocator" {
    const a = testing.allocator;
    var s: Store = .{};
    var p: Project = .{ .description = try a.dupe(u8, "d") };
    try ensureDefault(a, &p);
    const w = try workspaceOrCreate(a, &p, "ws", .{});
    try w.secrets.put(a, try a.dupe(u8, "K"), .{ .value = try a.dupe(u8, "v") });
    try s.projects.put(a, try a.dupe(u8, "p"), p);
    try s.bury(a, "x", .{});
    free(a, &s);
}
