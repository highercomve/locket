//! A sync connector: somewhere a shared vault lives, seen as a few named
//! files in Locket's own area there (`key.json`, `vault.enc`, and the
//! copies a backend makes when two machines write at once).
//!
//! Every backend implements this one interface (a context pointer and a
//! table of functions), so the sync engine (engine.zig) never knows which
//! one it talks to. connectors.zig lists them: the folder connector
//! (folder.zig: any synced folder, NomadFS's mount included) and the
//! NomadFS connector (nomadfs.zig: the swarm folder through the running
//! node's API, no mount).
//!
//! Versions: a backend that can tell versions apart (NomadFS: a file's
//! content id) returns one with every read, and enforces a write's or a
//! removal's `Expect` atomically: error.Changed when the file isn't what
//! the writer saw, so an edit made meanwhile is never overwritten. A
//! backend that can't (a plain folder) returns no version, says so in
//! `versioned`, and the engine re-reads before writing instead.
//! @atlas layer: sync

const std = @import("std");

/// The largest file a connector reads or writes: a vault of thousands of
/// secrets is well under a MiB; this bounds what a hostile share or node
/// can make Locket allocate. (NomadFS's API has the same limit.)
pub const max_object: usize = 8 << 20;

/// A file and, when the backend has one, its version.
pub const Object = struct {
    data: []u8,
    version: ?[]const u8 = null,
};

/// What a write or a removal requires of the file it replaces.
pub const Expect = union(enum) {
    /// Whatever is there.
    any,
    /// Nothing yet (a create).
    absent,
    /// This version (from a read).
    version: []const u8,
};

pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Ready to use now (running, mounted, present), or why not.
        check: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror!void,
        /// The names of the files in Locket's area (none when it doesn't
        /// exist yet).
        list: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror![]const []const u8,
        /// A file; error.FileNotFound when there is none.
        read: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8) anyerror!Object,
        /// Replaces a file, all at once (readers see the old or the new);
        /// error.Changed when `expect` doesn't hold (versioned backends).
        write: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, data: []const u8, expect: Expect) anyerror!void,
        /// Removes a file (gone already: fine); error.Changed as `write`.
        remove: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, expect: Expect) anyerror!void,
        /// Writes and removals honour `Expect` atomically.
        versioned: *const fn (ptr: *anyopaque) bool,
        /// `name` is a conflict copy the backend made of `base`.
        isCopyOf: *const fn (ptr: *anyopaque, name: []const u8, base: []const u8) bool,
        /// Where it is, for people ("NomadFS's swarm folder (node at ~/.nomadfs)").
        describe: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) anyerror![]const u8,
    };

    pub fn check(c: Connector, io: std.Io, gpa: std.mem.Allocator) !void {
        return c.vtable.check(c.ptr, io, gpa);
    }
    pub fn list(c: Connector, io: std.Io, gpa: std.mem.Allocator) ![]const []const u8 {
        return c.vtable.list(c.ptr, io, gpa);
    }
    pub fn read(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8) !Object {
        return c.vtable.read(c.ptr, io, gpa, name);
    }
    /// The file, or null when it doesn't exist.
    pub fn readOptional(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8) !?Object {
        return c.read(io, gpa, name) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }
    pub fn write(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8, data: []const u8, expect: Expect) !void {
        return c.vtable.write(c.ptr, io, gpa, name, data, expect);
    }
    pub fn remove(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8, expect: Expect) !void {
        return c.vtable.remove(c.ptr, io, gpa, name, expect);
    }
    pub fn versioned(c: Connector) bool {
        return c.vtable.versioned(c.ptr);
    }
    pub fn isCopyOf(c: Connector, name: []const u8, base: []const u8) bool {
        return c.vtable.isCopyOf(c.ptr, name, base);
    }
    pub fn describe(c: Connector, gpa: std.mem.Allocator) ![]const u8 {
        return c.vtable.describe(c.ptr, gpa);
    }
};

/// The conflict copies sync tools make of `base`, by name: same stem and
/// extension, "conflict" in between.
///
///     vault (conflict from laptop).enc               NomadFS
///     vault.sync-conflict-20261103-101500-ABC.enc    Syncthing
///     vault (Ana's conflicted copy 2026-11-03).enc   Dropbox
///     vault (conflicted copy 2026-11-03 101500).enc  Nextcloud
pub fn isConflictCopy(name: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, name, base)) return false;
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    if (name.len < stem.len + ext.len or !std.mem.startsWith(u8, name, stem) or !std.mem.endsWith(u8, name, ext)) return false;
    const middle = name[stem.len .. name.len - ext.len];
    return std.ascii.indexOfIgnoreCase(middle, "conflict") != null;
}

test isConflictCopy {
    const t = std.testing;
    try t.expect(isConflictCopy("vault (conflict from laptop).enc", "vault.enc"));
    try t.expect(isConflictCopy("vault.sync-conflict-20261103-101500-ABCDEFG.enc", "vault.enc"));
    try t.expect(isConflictCopy("vault (Ana's conflicted copy 2026-11-03).enc", "vault.enc"));
    try t.expect(!isConflictCopy("vault.enc", "vault.enc"));
    try t.expect(!isConflictCopy("key (conflict from x).json", "vault.enc"));
    try t.expect(!isConflictCopy("vault.enc.tmp", "vault.enc"));
    try t.expect(!isConflictCopy("vaults.enc", "vault.enc"));
}
