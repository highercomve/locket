//! Locket's vault: the operations every front end shares (the CLI, the
//! desktop app), the sealed storage and its lock. The data and how two
//! copies merge are store.zig's; sharing between machines is src/sync/'s.
//!
//! Layout (the data directory, see `dataDir`):
//!
//!     master.key   32 random bytes, mode 0600: the vault's key
//!     vault.enc    nonce (12) || ciphertext || tag (16):
//!                  vault.json (store.zig) sealed with AES-256-GCM
//!     config.json  this machine's settings (config.zig)
//!     lock         held while a process reads or writes the vault
//!
//! The model: projects hold workspaces, workspaces hold secrets (the
//! environment variables one run gets). A workspace is addressed as
//! `project/workspace` and a secret as `project/workspace/NAME`. Every
//! project has a `default` workspace, always first, which can't be
//! renamed or removed; `project` alone addresses it.
//!
//! Every change is stamped (time, this machine) and every removal leaves
//! a tombstone, so copies of the vault on several machines merge
//! (store.merge). Stamps only move forward: a new one is newer than every
//! stamp already in the vault, whatever this machine's clock says.
//!
//! Secrets are strings; values stay only in memory and the sealed file.
//! The core never prints them, and `close` zeroes them.
//!
//! Concurrency: the CLI and the desktop app (and several agents) share
//! the file. `open(.write)` holds an exclusive lock on `<data>/lock` until
//! `close`, so every edit is read → change → save with no other writer in
//! between; `open(.read)` takes a shared lock just long enough to read a
//! consistent snapshot. `save` writes a temp file, syncs it, renames it
//! over `vault.enc` and syncs the directory, so a crash leaves either the
//! old vault or the new one.
//!
//! Threat model: the seal protects `vault.enc` when it's copied alone
//! (backups, sync folders). `master.key` sits beside it, readable by your
//! user only (open refuses a key that group or others can read): anything
//! running as your user can read both. An OS keychain would close that.
//!
//! @atlas layer: core

const std = @import("std");
const builtin = @import("builtin");
const store = @import("store.zig");
const config = @import("config.zig");

const assert = std.debug.assert;
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Store = store.Store;
pub const Project = store.Project;
pub const Workspace = store.Workspace;
pub const Secret = store.Secret;
pub const Secrets = store.Secrets;
pub const Stamp = store.Stamp;
pub const default_workspace = store.default_workspace;
pub const isDefault = store.isDefault;

pub const key_len = 32;
const nonce_len = 12; // Aes256Gcm.nonce_length
const tag_len = 16; // Aes256Gcm.tag_length
const vault_ad = "locket/v1"; // the seal's format, not the JSON's version

pub const key_file = "master.key";
/// The key a rekey is switching to, until the vault is sealed with it.
const next_key_file = "master.key.next";
pub const vault_file = "vault.enc";
pub const lock_file = "lock";

pub const OpenError = error{
    CorruptVault,
    InsecureKey, // master.key is readable by group or others
};

/// `read`: a snapshot, no lock held after `open` returns; `save` asserts.
/// `write`: an exclusive lock held until `close`; the key is made if
/// missing.
pub const Mode = enum { read, write };

pub const Vault = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    key: [key_len]u8,
    store: Store,

    mode: Mode,
    /// The exclusive lock of a `write` vault, released by `close`.
    lock: ?std.Io.File = null,

    /// This machine, in the stamps (config.json; 0 until it has one).
    device: u64 = 0,
    /// The wall clock when the vault was opened, in milliseconds.
    clock_ms: i64 = 0,
    /// The newest stamp in the vault, and the last one made.
    high: Stamp = .{},

    /// Zeroes the values and the key, frees the store, releases the lock.
    pub fn close(v: *Vault) void {
        store.free(v.gpa, &v.store);
        std.crypto.secureZero(u8, &v.key);
        if (v.lock) |f| f.close(v.io); // closing the file releases its lock
        v.lock = null;
        v.gpa.free(v.dir_path);
        v.* = undefined;
    }

    /// A stamp for a change made now: newer than everything in the vault.
    pub fn stamp(v: *Vault) Stamp {
        const t = if (v.clock_ms > v.high.t) v.clock_ms else v.high.t + 1;
        v.high = .{ .t = t, .d = v.device };
        return v.high;
    }

    /// Takes `s` as the vault's content (a merge's result), freeing the old.
    pub fn replaceStore(v: *Vault, s: Store) void {
        store.free(v.gpa, &v.store);
        v.store = s;
        v.high = v.high.max(s.high());
    }

    // ------------------------------------------------------------ lookups

    pub fn names(v: *Vault) []const []const u8 {
        return v.store.projects.keys();
    }

    pub fn project(v: *Vault, name: []const u8) ?*Project {
        return v.store.projects.getPtr(name);
    }

    pub fn workspace(v: *Vault, project_name: []const u8, workspace_name: []const u8) ?*Workspace {
        const p = v.project(project_name) orelse return null;
        return p.workspaces.getPtr(workspace_name);
    }

    /// A secret's value. Callers must not write through it or free it;
    /// it's owned by the store.
    pub fn secret(v: *Vault, project_name: []const u8, workspace_name: []const u8, secret_name: []const u8) ?[]const u8 {
        const w = v.workspace(project_name, workspace_name) orelse return null;
        const x = w.secrets.get(secret_name) orelse return null;
        return x.value;
    }

    // ----------------------------------------------------------- projects

    /// A new, empty project. error.Exists when the name is taken.
    pub fn createProject(v: *Vault, name: []const u8, description: []const u8) !void {
        try checkName(name);
        if (!std.unicode.utf8ValidateSlice(description)) return error.InvalidUtf8;
        if (v.store.projects.contains(name)) return error.Exists;
        const dup_desc = try v.gpa.dupe(u8, description);
        errdefer v.gpa.free(dup_desc);
        const p = try v.projectOrCreate(name, v.stamp());
        v.gpa.free(p.description);
        p.description = dup_desc;
    }

    /// Renames a project in place (it keeps its position) and sets its
    /// description. A rename is the old path's deletion and a new project.
    pub fn updateProject(v: *Vault, old_name: []const u8, new_name: []const u8, description: []const u8) !void {
        try checkName(new_name);
        if (!std.unicode.utf8ValidateSlice(description)) return error.InvalidUtf8;
        const index = v.store.projects.getIndex(old_name) orelse return error.NotFound;
        const renaming = !std.mem.eql(u8, old_name, new_name);
        if (renaming and v.store.projects.contains(new_name)) return error.Exists;
        const dup_desc = try v.gpa.dupe(u8, description);
        errdefer v.gpa.free(dup_desc);
        const st = v.stamp();
        if (renaming) {
            try v.store.bury(v.gpa, old_name, st);
            try renameKey(v.gpa, &v.store.projects, index, new_name);
        }
        const p = &v.store.projects.values()[index];
        v.gpa.free(p.description);
        p.description = dup_desc;
        if (renaming) restampProject(p, st) else p.stamp = st;
    }

    pub fn removeProject(v: *Vault, name: []const u8) bool {
        const kv = v.store.projects.fetchOrderedRemove(name) orelse return false;
        v.gpa.free(kv.key);
        var p = kv.value;
        store.freeProject(v.gpa, &p);
        v.store.bury(v.gpa, name, v.stamp()) catch {}; // OOM: the removal stays local
        return true;
    }

    // --------------------------------------------------------- workspaces

    pub fn createWorkspace(v: *Vault, project_name: []const u8, name: []const u8) !void {
        try checkName(name);
        const p = v.project(project_name) orelse return error.NotFound;
        if (p.workspaces.contains(name)) return error.Exists;
        _ = try store.workspaceOrCreate(v.gpa, p, name, v.stamp());
    }

    pub fn renameWorkspace(v: *Vault, project_name: []const u8, old_name: []const u8, new_name: []const u8) !void {
        try checkName(new_name);
        if (isDefault(old_name) or isDefault(new_name)) return error.DefaultWorkspace;
        const p = v.project(project_name) orelse return error.NotFound;
        const index = p.workspaces.getIndex(old_name) orelse return error.NotFound;
        if (std.mem.eql(u8, old_name, new_name)) return;
        if (p.workspaces.contains(new_name)) return error.Exists;
        const st = v.stamp();
        var buf: [3 * 129]u8 = undefined;
        try v.store.bury(v.gpa, store.join(&buf, &.{ project_name, old_name }), st);
        try renameKey(v.gpa, &p.workspaces, index, new_name);
        restampWorkspace(&p.workspaces.values()[index], st);
    }

    /// False when it doesn't exist. The default workspace is never
    /// removed (assert: callers check isDefault first).
    pub fn removeWorkspace(v: *Vault, project_name: []const u8, name: []const u8) bool {
        assert(!isDefault(name));
        const p = v.project(project_name) orelse return false;
        const kv = p.workspaces.fetchOrderedRemove(name) orelse return false;
        v.gpa.free(kv.key);
        var w = kv.value;
        store.freeSecrets(v.gpa, &w.secrets);
        var buf: [3 * 129]u8 = undefined;
        v.store.bury(v.gpa, store.join(&buf, &.{ project_name, name }), v.stamp()) catch {};
        return true;
    }

    // ------------------------------------------------------------ secrets

    /// Writes a secret, creating its project and workspace as needed (the
    /// CLI's `set` on a fresh name).
    pub fn setSecret(v: *Vault, project_name: []const u8, workspace_name: []const u8, secret_name: []const u8, value: []const u8) !void {
        try checkName(project_name);
        try checkName(workspace_name);
        try checkVarName(secret_name);
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8; // JSON copy must stay valid
        const dup_value = try v.gpa.dupe(u8, value);
        errdefer v.gpa.free(dup_value);
        const st = v.stamp();
        const p = try v.projectOrCreate(project_name, st);
        const w = try store.workspaceOrCreate(v.gpa, p, workspace_name, st);
        const gop = try w.secrets.getOrPut(v.gpa, secret_name);
        if (gop.found_existing) {
            store.freeSecret(v.gpa, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = v.gpa.dupe(u8, secret_name) catch |e| {
                w.secrets.swapRemoveAt(gop.index);
                return e;
            };
        }
        gop.value_ptr.* = .{ .value = dup_value, .stamp = st };
    }

    /// Writes a secret of an existing workspace, renaming it first when
    /// `old_name` is set and differs from `new_name` (an edit: it keeps its
    /// position). An empty `old_name` adds one: error.Exists if taken.
    pub fn updateSecret(v: *Vault, project_name: []const u8, workspace_name: []const u8, old_name: []const u8, new_name: []const u8, value: []const u8) !void {
        try checkVarName(new_name);
        const w = v.workspace(project_name, workspace_name) orelse return error.NotFound;
        const renaming = !std.mem.eql(u8, old_name, new_name);
        if (renaming and w.secrets.contains(new_name)) return error.Exists;
        if (old_name.len > 0) {
            // An edit of a secret removed meanwhile must not bring it back.
            const index = w.secrets.getIndex(old_name) orelse return error.NotFound;
            if (renaming) {
                var buf: [3 * 129]u8 = undefined;
                try v.store.bury(v.gpa, store.join(&buf, &.{ project_name, workspace_name, old_name }), v.stamp());
                try renameKey(v.gpa, &w.secrets, index, new_name);
            }
        }
        try v.setSecret(project_name, workspace_name, new_name, value);
    }

    pub fn removeSecret(v: *Vault, project_name: []const u8, workspace_name: []const u8, secret_name: []const u8) bool {
        const w = v.workspace(project_name, workspace_name) orelse return false;
        const kv = w.secrets.fetchOrderedRemove(secret_name) orelse return false;
        v.gpa.free(kv.key);
        store.freeSecret(v.gpa, kv.value);
        var buf: [3 * 129]u8 = undefined;
        v.store.bury(v.gpa, store.join(&buf, &.{ project_name, workspace_name, secret_name }), v.stamp()) catch {};
        return true;
    }

    fn projectOrCreate(v: *Vault, name: []const u8, st: Stamp) !*Project {
        const gop = try v.store.projects.getOrPut(v.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = v.gpa.dupe(u8, name) catch |e| {
                v.store.projects.swapRemoveAt(gop.index);
                return e;
            };
            gop.value_ptr.* = .{ .stamp = st };
            store.ensureDefault(v.gpa, gop.value_ptr) catch |e| {
                v.gpa.free(gop.key_ptr.*);
                v.store.projects.swapRemoveAt(gop.index);
                return e;
            };
        }
        return gop.value_ptr;
    }

    // ------------------------------------------------------------ storage

    pub fn save(v: *Vault) !void {
        assert(v.mode == .write and v.lock != null);
        const sealed = try seal(v.gpa, v.io, v.key, &v.store);
        defer v.gpa.free(sealed);
        try writeAtomic(v.io, v.gpa, v.dir_path, vault_file, sealed);
    }

    /// Re-seals the vault with `key` and makes it the vault's key (a
    /// machine joining a shared vault). Crash-safe in two steps: the new
    /// key goes to master.key.next, the vault is saved with it, then
    /// master.key.next replaces master.key; `open` finishes a rekey a
    /// crash interrupted (the vault opens with .next, not master.key).
    pub fn rekey(v: *Vault, key: [key_len]u8) !void {
        assert(v.mode == .write and v.lock != null);
        try writeAtomic(v.io, v.gpa, v.dir_path, next_key_file, &key);
        v.key = key;
        try v.save();
        try finishRekey(v.io, v.gpa, v.dir_path);
    }

    pub fn marshal(v: *Vault) ![]u8 {
        return store.marshal(v.gpa, &v.store);
    }
};

/// Every entry of a renamed project is new: stamped `st`.
fn restampProject(p: *Project, st: Stamp) void {
    p.stamp = st;
    for (p.workspaces.values()) |*w| restampWorkspace(w, st);
}

fn restampWorkspace(w: *Workspace, st: Stamp) void {
    w.stamp = st;
    for (w.secrets.values()) |*x| x.stamp = st;
}

/// Renames the entry at `index` in place, keeping its position.
fn renameKey(gpa: std.mem.Allocator, map: anytype, index: usize, new_name: []const u8) !void {
    const keys = map.keys();
    if (std.mem.eql(u8, keys[index], new_name)) return;
    const dup = try gpa.dupe(u8, new_name);
    errdefer gpa.free(dup);
    const old = keys[index];
    keys[index] = dup;
    map.reIndex(gpa) catch |e| {
        keys[index] = old;
        return e;
    };
    gpa.free(old);
}

// ------------------------------------------------------------------- seal

/// `s` as vault.json, sealed with `key`: nonce || ciphertext || tag.
pub fn seal(gpa: std.mem.Allocator, io: std.Io, key: [key_len]u8, s: *const Store) ![]u8 {
    const plain = try store.marshal(gpa, s);
    defer {
        std.crypto.secureZero(u8, plain);
        gpa.free(plain);
    }
    const sealed = try gpa.alloc(u8, nonce_len + plain.len + tag_len);
    errdefer gpa.free(sealed);
    var nonce: [nonce_len]u8 = undefined;
    io.random(&nonce);
    var tag: [tag_len]u8 = undefined;
    Aes.encrypt(sealed[nonce_len .. nonce_len + plain.len], &tag, plain, vault_ad, nonce, key);
    @memcpy(sealed[0..nonce_len], &nonce);
    @memcpy(sealed[sealed.len - tag_len ..], &tag);
    return sealed;
}

/// The store sealed in `sealed`; error.CorruptVault when `key` doesn't
/// open it or the JSON is damaged.
pub fn unseal(gpa: std.mem.Allocator, key: [key_len]u8, sealed: []const u8) !Store {
    if (sealed.len < nonce_len + tag_len) return error.CorruptVault;
    const ciphertext = sealed[nonce_len .. sealed.len - tag_len];
    const tag = sealed[sealed.len - tag_len ..][0..tag_len].*;
    const nonce = sealed[0..nonce_len].*;
    const plain = try gpa.alloc(u8, ciphertext.len);
    defer {
        std.crypto.secureZero(u8, plain);
        gpa.free(plain);
    }
    Aes.decrypt(plain, ciphertext, tag, vault_ad, nonce, key) catch return error.CorruptVault;
    return store.unmarshal(gpa, plain);
}

/// Writes `dir_path/name` through a synced temp file and a rename, then
/// syncs the directory: a crash leaves the old file or the new one.
fn writeAtomic(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, name: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(gpa, &.{ dir_path, name });
    defer gpa.free(path);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp_path);
    {
        const f = try cwd.createFile(io, tmp_path, .{ .permissions = owner_only });
        defer f.close(io);
        try f.writeStreamingAll(io, data);
        try f.sync(io);
    }
    try cwd.rename(tmp_path, cwd, path, io);
    try syncDir(io, dir_path);
}

fn syncDir(io: std.Io, path: []const u8) !void {
    if (builtin.os.tag == .windows) return; // directories can't be synced there
    // iterate: a real descriptor (O_RDONLY), not O_PATH, which fsync refuses.
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const f: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try f.sync(io);
}

// -------------------------------------------------------------- addresses

pub const NameError = error{ EmptyName, NameTooLong, InvalidName };

/// A project, workspace or secret name: 1–128 bytes, no '/', whitespace
/// or control bytes (addresses join names with '/').
pub fn checkName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > 128) return error.NameTooLong;
    for (name) |c| {
        if (c == '/' or c <= ' ' or c == 0x7f) return error.InvalidName;
    }
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
}

/// A secret's name: a name that is also an environment variable name
/// (`run` injects it as one), so no '='.
pub fn checkVarName(name: []const u8) (NameError || error{InvalidVarName})!void {
    try checkName(name);
    if (std.mem.indexOfScalar(u8, name, '=') != null) return error.InvalidVarName;
}

/// What the core's errors mean, worded for people: both front ends show
/// these. Null for errors that aren't the vault's (I/O, OOM).
pub fn describeError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.EmptyName => "a name is required",
        error.NameTooLong => "names are at most 128 characters",
        error.InvalidName => "names can't contain spaces, '/' or control characters",
        error.InvalidVarName => "variable names can't contain '=' (they become environment variables)",
        error.InvalidAddress => "expected project[/workspace][/NAME]; names have no spaces or '/'",
        error.Exists => "that name is already taken",
        error.NotFound => "not found: the vault changed on disk",
        error.DefaultWorkspace => "the default workspace can't be renamed or removed",
        error.InvalidUtf8 => "text must be valid UTF-8",
        error.CorruptVault => "the vault can't be decrypted (wrong key or damaged file)",
        error.InsecureKey => "master.key is readable by other users: chmod 600 it",
        else => null,
    };
}

/// A resolved address: a workspace, or a variable in one. Leaving the
/// workspace out means the project's default workspace.
pub const Ref = struct {
    project: []const u8,
    workspace: []const u8,
    name: ?[]const u8 = null,

    /// `project` (its default workspace) or `project/workspace`.
    pub fn workspaceOf(text: []const u8) error{InvalidAddress}!Ref {
        const a = try Address.parse(text);
        if (a.secret != null) return error.InvalidAddress;
        return .{ .project = a.project, .workspace = a.workspace orelse default_workspace };
    }

    /// `project/NAME` (in the default workspace) or `project/workspace/NAME`.
    pub fn variableOf(text: []const u8) error{InvalidAddress}!Ref {
        const a = try Address.parse(text);
        const second = a.workspace orelse return error.InvalidAddress;
        if (a.secret) |name| return .{ .project = a.project, .workspace = second, .name = name };
        return .{ .project = a.project, .workspace = default_workspace, .name = second };
    }

    /// The shortest address `run` takes for this workspace.
    pub fn format(r: Ref, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(r.project);
        if (!isDefault(r.workspace)) try w.print("/{s}", .{r.workspace});
        if (r.name) |n| try w.print("/{s}", .{n});
    }
};

/// `project`, `project/workspace` or `project/workspace/NAME`.
pub const Address = struct {
    project: []const u8,
    workspace: ?[]const u8 = null,
    secret: ?[]const u8 = null,

    pub fn parse(text: []const u8) error{InvalidAddress}!Address {
        var it = std.mem.splitScalar(u8, text, '/');
        var parts: [3][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |part| : (n += 1) {
            if (n == parts.len) return error.InvalidAddress;
            checkName(part) catch return error.InvalidAddress;
            parts[n] = part;
        }
        assert(n >= 1);
        return .{
            .project = parts[0],
            .workspace = if (n >= 2) parts[1] else null,
            .secret = if (n >= 3) parts[2] else null,
        };
    }
};

test checkName {
    try checkName("prod");
    try checkName("DATABASE_URL");
    try std.testing.expectError(error.EmptyName, checkName(""));
    try std.testing.expectError(error.InvalidName, checkName("a/b"));
    try std.testing.expectError(error.InvalidName, checkName("a b"));
}

test checkVarName {
    try checkVarName("DATABASE_URL");
    try std.testing.expectError(error.InvalidVarName, checkVarName("A=B"));
}

test Ref {
    const ws = try Ref.workspaceOf("hub");
    try std.testing.expectEqualStrings(default_workspace, ws.workspace);
    try std.testing.expectEqualStrings("stage", (try Ref.workspaceOf("hub/stage")).workspace);
    try std.testing.expectError(error.InvalidAddress, Ref.workspaceOf("hub/stage/X"));
    const v1 = try Ref.variableOf("hub/API_KEY");
    try std.testing.expectEqualStrings(default_workspace, v1.workspace);
    try std.testing.expectEqualStrings("API_KEY", v1.name.?);
    const v2 = try Ref.variableOf("hub/stage/API_KEY");
    try std.testing.expectEqualStrings("stage", v2.workspace);
    try std.testing.expectError(error.InvalidAddress, Ref.variableOf("hub"));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hub", try std.fmt.bufPrint(&buf, "{f}", .{ws}));
    try std.testing.expectEqualStrings("hub/stage/API_KEY", try std.fmt.bufPrint(&buf, "{f}", .{v2}));
}

test "Address.parse" {
    const a = try Address.parse("hub/stage/API_KEY");
    try std.testing.expectEqualStrings("hub", a.project);
    try std.testing.expectEqualStrings("stage", a.workspace.?);
    try std.testing.expectEqualStrings("API_KEY", a.secret.?);
    const b = try Address.parse("hub/stage");
    try std.testing.expect(b.secret == null);
    const c = try Address.parse("hub");
    try std.testing.expect(c.workspace == null);
    try std.testing.expectError(error.InvalidAddress, Address.parse("hub//x"));
    try std.testing.expectError(error.InvalidAddress, Address.parse("a/b/c/d"));
    try std.testing.expectError(error.InvalidAddress, Address.parse(""));
}

// ------------------------------------------------------------------- open

/// Files only their owner can read and write (0600). Windows has no mode
/// bits: a file under the user's profile is the user's.
const owner_only: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);

/// The vault's directory:
///
///     $LOCKET_HOME                         when set (any platform)
///     Linux     $XDG_DATA_HOME/locket      default ~/.local/share/locket
///     macOS     ~/Library/Application Support/locket
///     Windows   %APPDATA%\locket
pub fn dataDir(env: anytype, gpa: std.mem.Allocator) ![]u8 {
    return dataDirFor(builtin.os.tag, env, gpa);
}

fn dataDirFor(os: std.Target.Os.Tag, env: anytype, gpa: std.mem.Allocator) ![]u8 {
    if (env.get("LOCKET_HOME")) |dir| if (dir.len > 0) return gpa.dupe(u8, dir);
    switch (os) {
        .windows => {
            const appdata = env.get("APPDATA") orelse return error.NoDataDir;
            return std.fs.path.join(gpa, &.{ appdata, "locket" });
        },
        .macos => {
            const home = env.get("HOME") orelse return error.NoDataDir;
            return std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "locket" });
        },
        else => {
            const xdg = env.get("XDG_DATA_HOME") orelse "";
            if (xdg.len > 0 and xdg[0] == '/') return std.fs.path.join(gpa, &.{ xdg, "locket" });
            const home = env.get("HOME") orelse return error.NoDataDir;
            return std.fs.path.join(gpa, &.{ home, ".local", "share", "locket" });
        },
    }
}

test dataDirFor {
    const Env = struct {
        pairs: []const [2][]const u8,
        fn get(e: @This(), key: []const u8) ?[]const u8 {
            for (e.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
            return null;
        }
    };
    const a = std.testing.allocator;
    const cases = [_]struct { os: std.Target.Os.Tag, env: Env, want: []const u8 }{
        .{ .os = .linux, .env = .{ .pairs = &.{.{ "HOME", "/h" }} }, .want = "/h/.local/share/locket" },
        .{ .os = .linux, .env = .{ .pairs = &.{ .{ "HOME", "/h" }, .{ "XDG_DATA_HOME", "/x" } } }, .want = "/x/locket" },
        .{ .os = .macos, .env = .{ .pairs = &.{.{ "HOME", "/h" }} }, .want = "/h/Library/Application Support/locket" },
        .{ .os = .linux, .env = .{ .pairs = &.{ .{ "HOME", "/h" }, .{ "LOCKET_HOME", "/v" } } }, .want = "/v" },
    };
    for (cases) |c| {
        const got = try dataDirFor(c.os, c.env, a);
        defer a.free(got);
        // The host's separator joins the parts (`\\` on Windows).
        std.mem.replaceScalar(u8, got, std.fs.path.sep, '/');
        try std.testing.expectEqualStrings(c.want, got);
    }
    try std.testing.expectError(error.NoDataDir, dataDirFor(.windows, Env{ .pairs = &.{} }, a));
}

/// Loads the vault at `data_path` (creating the directory). See `Mode`;
/// call `close` when done. `gpa` may be an arena: `close` then only zeroes.
pub fn open(io: std.Io, gpa: std.mem.Allocator, data_path: []const u8, mode: Mode) !Vault {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, data_path);

    var v: Vault = .{
        .gpa = gpa,
        .io = io,
        .dir = cwd,
        .dir_path = try gpa.dupe(u8, data_path),
        .key = undefined,
        .store = .{},
        .mode = mode,
        .clock_ms = std.Io.Clock.real.now(io).toMilliseconds(),
    };
    errdefer gpa.free(v.dir_path);

    const lock_path = try std.fs.path.join(gpa, &.{ v.dir_path, lock_file });
    defer gpa.free(lock_path);
    const lock = try cwd.createFile(io, lock_path, .{
        .truncate = false,
        .lock = if (mode == .write) .exclusive else .shared,
        .permissions = owner_only,
    });
    var keep_lock = false;
    defer if (!keep_lock) lock.close(io);

    v.device = try loadDevice(io, gpa, v.dir_path, mode);

    const key_path = try std.fs.path.join(gpa, &.{ v.dir_path, key_file });
    defer gpa.free(key_path);
    if (!try loadKey(&v, key_path)) {
        // No key, so nothing was ever sealed: an empty vault.
        if (mode == .read) return v;
        try makeKey(&v, key_path);
    }

    const vault_path = try std.fs.path.join(gpa, &.{ v.dir_path, vault_file });
    defer gpa.free(vault_path);
    if (v.dir.readFileAlloc(io, vault_path, gpa, .limited(64 << 20))) |sealed| {
        defer gpa.free(sealed);
        v.store = unseal(gpa, v.key, sealed) catch |e| store: {
            // A rekey interrupted after the vault was sealed with the new key.
            if (e != error.CorruptVault) return e;
            const next = try loadNextKey(io, gpa, v.dir_path) orelse return e;
            const s = try unseal(gpa, next, sealed);
            v.key = next;
            if (mode == .write) try finishRekey(io, gpa, v.dir_path);
            break :store s;
        };
        v.high = v.store.high();
    } else |e| {
        if (e != error.FileNotFound) return e;
    }
    if (mode == .write) {
        v.lock = lock;
        keep_lock = true;
    }
    return v;
}

/// This machine's device id from config.json; a write open makes one the
/// first time (under the lock, so two first runs can't race).
fn loadDevice(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, mode: Mode) !u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var cfg = config.load(io, arena.allocator(), dir_path) catch config.Config{};
    if (cfg.deviceId() != 0 or mode == .read) return cfg.deviceId();
    var buf: [16]u8 = undefined;
    cfg.device = config.newDevice(io, &buf);
    try config.save(io, gpa, dir_path, cfg);
    return cfg.deviceId();
}

/// master.key.next, when a rekey left one.
fn loadNextKey(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) !?[key_len]u8 {
    const path = try std.fs.path.join(gpa, &.{ dir_path, next_key_file });
    defer gpa.free(path);
    const k = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer {
        std.crypto.secureZero(u8, k);
        gpa.free(k);
    }
    if (k.len != key_len) return null;
    return k[0..key_len].*;
}

fn finishRekey(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const next = try std.fs.path.join(gpa, &.{ dir_path, next_key_file });
    defer gpa.free(next);
    const key = try std.fs.path.join(gpa, &.{ dir_path, key_file });
    defer gpa.free(key);
    try cwd.rename(next, cwd, key, io);
    try syncDir(io, dir_path);
}

/// Reads master.key into `v.key`; false when there is none yet.
fn loadKey(v: *Vault, key_path: []const u8) !bool {
    const st = v.dir.statFile(v.io, key_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    if (comptime builtin.os.tag != .windows) {
        if (st.permissions.toMode() & 0o077 != 0) return error.InsecureKey;
    }
    const k = try v.dir.readFileAlloc(v.io, key_path, v.gpa, .limited(64));
    defer {
        std.crypto.secureZero(u8, k);
        v.gpa.free(k);
    }
    if (k.len != key_len) return error.CorruptVault;
    @memcpy(&v.key, k);
    return true;
}

/// A new random key, synced to master.key (mode 0600). Only under the
/// exclusive lock, so two first runs can't race.
fn makeKey(v: *Vault, key_path: []const u8) !void {
    assert(v.mode == .write);
    const f = try v.dir.createFile(v.io, key_path, .{
        .exclusive = true,
        .permissions = owner_only,
    });
    defer f.close(v.io);
    v.io.random(&v.key);
    try f.writeStreamingAll(v.io, &v.key);
    try f.sync(v.io);
    try syncDir(v.io, v.dir_path);
}

/// A vault in memory, for tests: no file, no lock.
fn testVault(a: std.mem.Allocator) Vault {
    return .{ .gpa = a, .io = undefined, .dir = undefined, .dir_path = "", .key = undefined, .store = .{}, .mode = .write, .device = 1, .clock_ms = 1000 };
}

test "operations round-trip through the JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = testVault(a);
    try v.createProject("hub", "Pantahub");
    try v.createWorkspace("hub", "stage");
    try v.setSecret("hub", "stage", "TOKEN", "s3cret");
    try v.setSecret("hub", "prod", "TOKEN", "p");
    try v.updateSecret("hub", "stage", "TOKEN", "API_TOKEN", "s3cret2");
    try v.renameWorkspace("hub", "prod", "production");
    var back = try store.unmarshal(a, try v.marshal());
    const p = back.projects.getPtr("hub").?;
    try std.testing.expectEqualStrings("s3cret2", p.workspaces.get("stage").?.secrets.get("API_TOKEN").?.value);
    try std.testing.expectEqualStrings("p", p.workspaces.get("production").?.secrets.get("TOKEN").?.value);
    try std.testing.expectEqual(@as(usize, 2), p.secretCount());
    try std.testing.expectEqualStrings(default_workspace, p.workspaces.keys()[0]);
    // Renames and removals leave tombstones, for the merge.
    try std.testing.expect(back.tombs.get("hub/prod") != null);
    try std.testing.expect(back.tombs.get("hub/stage/TOKEN") != null);
    try std.testing.expectError(error.DefaultWorkspace, v.renameWorkspace("hub", default_workspace, "x"));
    try std.testing.expect(v.removeWorkspace("hub", "stage"));
    try std.testing.expect(v.removeProject("hub"));
    try std.testing.expect(v.store.tombs.get("hub") != null);
}

test "stamps only move forward, even behind a newer stamp from another machine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var v = testVault(arena.allocator());
    v.high = .{ .t = 5000, .d = 9 }; // from a machine whose clock is ahead
    const s1 = v.stamp();
    const s2 = v.stamp();
    try std.testing.expect(s1.newer(.{ .t = 5000, .d = 9 }));
    try std.testing.expect(s2.newer(s1));
    try std.testing.expectEqual(@as(u64, 1), s2.d);
}

test "editing a secret removed meanwhile is NotFound, not a re-add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var v = testVault(arena.allocator());
    try v.setSecret("hub", default_workspace, "K", "v");
    try std.testing.expect(v.removeSecret("hub", default_workspace, "K"));
    try std.testing.expectError(error.NotFound, v.updateSecret("hub", default_workspace, "K", "K", "v2"));
    try std.testing.expectError(error.NotFound, v.updateSecret("hub", default_workspace, "K", "K2", "v2"));
    try std.testing.expect(v.secret("hub", default_workspace, "K") == null);
    try std.testing.expectError(error.InvalidVarName, v.setSecret("hub", default_workspace, "A=B", "x"));
}

test "seal and unseal; the wrong key is CorruptVault" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = testVault(a);
    try v.setSecret("hub", default_workspace, "K", "v");
    var key: [key_len]u8 = @splat(7);
    const sealed = try seal(a, io, key, &v.store);
    const back = try unseal(a, key, sealed);
    try std.testing.expectEqualStrings("v", back.projects.get("hub").?.workspaces.get(default_workspace).?.secrets.get("K").?.value);
    key[0] ^= 1;
    try std.testing.expectError(error.CorruptVault, unseal(a, key, sealed));
}

test "rekey re-seals with the new key, and open finishes an interrupted one" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const new_key: [key_len]u8 = @splat(9);
    {
        var v = try open(io, testing.allocator, path, .write);
        defer v.close();
        try v.setSecret("hub", default_workspace, "K", "v");
        try v.save();
        try v.rekey(new_key);
    }
    {
        var v = try open(io, testing.allocator, path, .read);
        defer v.close();
        try testing.expectEqual(new_key, v.key);
        try testing.expectEqualStrings("v", v.secret("hub", default_workspace, "K").?);
    }
    // Interrupted: the vault sealed with a newer key, master.key still the old one.
    const newer: [key_len]u8 = @splat(5);
    {
        var v = try open(io, testing.allocator, path, .write);
        defer v.close();
        try writeAtomic(io, testing.allocator, path, next_key_file, &newer);
        v.key = newer;
        try v.save(); // ...and the crash comes before finishRekey
    }
    {
        var v = try open(io, testing.allocator, path, .write);
        defer v.close();
        try testing.expectEqual(newer, v.key);
        try testing.expectEqualStrings("v", v.secret("hub", default_workspace, "K").?);
    }
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, next_key_file, .{}));
}

test "open, save and reopen on disk; edits hold the lock; insecure keys are refused" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(path);

    // A read of a fresh directory: empty, and it makes no key.
    {
        var v = try open(io, testing.allocator, path, .read);
        defer v.close();
        try testing.expectEqual(@as(usize, 0), v.names().len);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, key_file, .{}));
    }
    {
        var v = try open(io, testing.allocator, path, .write);
        defer v.close();
        try testing.expect(v.device != 0); // made on the first write open
        try v.setSecret("hub", "stage", "TOKEN", "s3cret");
        try v.save();
        // Another writer can't get in while this one is open.
        const other = try tmp.dir.createFile(io, lock_file, .{ .truncate = false });
        defer other.close(io);
        try testing.expect(!try other.tryLock(io, .exclusive));
    }
    {
        var v = try open(io, testing.allocator, path, .read);
        defer v.close();
        try testing.expectEqualStrings("s3cret", v.secret("hub", "stage", "TOKEN").?);
        try testing.expect(v.lock == null);
        try testing.expect(v.high.t > 0);
    }
    // Windows has no mode bits to get wrong.
    if (comptime builtin.os.tag != .windows) {
        const key = try tmp.dir.openFile(io, key_file, .{});
        defer key.close(io);
        try key.setPermissions(io, .fromMode(0o644));
        try testing.expectError(error.InsecureKey, open(io, testing.allocator, path, .read));
    }
}
