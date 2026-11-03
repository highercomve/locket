//! A sync connector: somewhere a shared vault lives, seen as a few named
//! files in Locket's own area there (`key.json`, `vault.enc`, and the
//! copies the backend makes when two machines write at once).
//!
//! Every backend implements this one interface (a context pointer and a
//! table of functions), so the sync engine (engine.zig) never knows which
//! one it talks to. Folder-based backends (folder.zig, nomadfs.zig) share
//! one implementation; one that isn't a folder (WebDAV, S3, a git
//! remote...) implements the same six functions. connectors.zig lists
//! them.
//! @atlas layer: sync

const std = @import("std");

pub const Connector = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Ready to use now (mounted, present, reachable), or why not.
        check: *const fn (ptr: *anyopaque, io: std.Io) anyerror!void,
        /// The names of the files in Locket's area (none when it doesn't
        /// exist yet).
        list: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror![]const []const u8,
        /// A file's bytes; error.FileNotFound when there is none.
        read: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8) anyerror![]u8,
        /// Replaces a file, all at once (readers see the old or the new).
        write: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, data: []const u8) anyerror!void,
        remove: *const fn (ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8) anyerror!void,
        /// `name` is a conflict copy the backend made of `base`.
        isCopyOf: *const fn (ptr: *anyopaque, name: []const u8, base: []const u8) bool,
        /// Where it is, for people ("NomadFS swarm folder at ~/NomadFS/Swarm").
        describe: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) anyerror![]const u8,
    };

    pub fn check(c: Connector, io: std.Io) !void {
        return c.vtable.check(c.ptr, io);
    }
    pub fn list(c: Connector, io: std.Io, gpa: std.mem.Allocator) ![]const []const u8 {
        return c.vtable.list(c.ptr, io, gpa);
    }
    pub fn read(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return c.vtable.read(c.ptr, io, gpa, name);
    }
    /// The file's bytes, or null when it doesn't exist.
    pub fn readOptional(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8) !?[]u8 {
        return c.read(io, gpa, name) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }
    pub fn write(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8, data: []const u8) !void {
        return c.vtable.write(c.ptr, io, gpa, name, data);
    }
    pub fn remove(c: Connector, io: std.Io, gpa: std.mem.Allocator, name: []const u8) !void {
        return c.vtable.remove(c.ptr, io, gpa, name);
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
