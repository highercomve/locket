//! The folder connector: a shared vault in `<root>/locket/` of any
//! directory another tool keeps in step between machines (Syncthing,
//! Dropbox, a network share, NomadFS's mount). Plain files have no
//! versions: writes aren't conditional (`versioned` is false), and the
//! engine re-reads before writing instead.
//!
//! `root` must exist: Locket creates only its own `locket/` inside it, so
//! a sync folder that isn't there (an unmounted share) is reported, not
//! silently replaced by an empty local directory.
//! @atlas layer: sync

const std = @import("std");
const builtin = @import("builtin");
const connector_mod = @import("connector.zig");
const Connector = connector_mod.Connector;
const Object = connector_mod.Object;
const Expect = connector_mod.Expect;
const isConflictCopy = connector_mod.isConflictCopy;

/// Locket's own area inside the folder.
pub const area = "locket";

pub const Folder = struct {
    /// The shared folder (absolute).
    root: []const u8,

    pub fn connector(f: *Folder) Connector {
        return .{ .ptr = f, .vtable = &vtable };
    }

    const vtable: Connector.VTable = .{
        .check = check,
        .list = list,
        .read = read,
        .write = write,
        .remove = remove,
        .versioned = versioned,
        .isCopyOf = isCopyOf,
        .describe = describe,
    };

    fn self(ptr: *anyopaque) *Folder {
        return @ptrCast(@alignCast(ptr));
    }

    fn check(ptr: *anyopaque, io: std.Io, _: std.mem.Allocator) anyerror!void {
        const f = self(ptr);
        if (!std.fs.path.isAbsolute(f.root)) return error.FolderNotAbsolute;
        const st = std.Io.Dir.cwd().statFile(io, f.root, .{}) catch |e| switch (e) {
            error.FileNotFound => return error.FolderMissing,
            else => return e,
        };
        if (st.kind != .directory) return error.FolderMissing;
    }

    /// Locket's area, opened without following a symlink there: a link
    /// planted in the shared folder can't send reads or writes elsewhere.
    /// error.FileNotFound when it doesn't exist and `create` is false.
    fn openArea(f: *Folder, io: std.Io, create: bool, iterate: bool) !std.Io.Dir {
        var root = try std.Io.Dir.cwd().openDir(io, f.root, .{});
        defer root.close(io);
        if (create) root.createDirPath(io, area) catch |e| return if (e == error.NotDir) error.FolderAreaNotDirectory else e;
        return root.openDir(io, area, .{ .follow_symlinks = false, .iterate = iterate }) catch |e| switch (e) {
            error.SymLinkLoop, error.NotDir => error.FolderAreaNotDirectory,
            else => e,
        };
    }

    fn list(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror![]const []const u8 {
        const f = self(ptr);
        try check(ptr, io, gpa);
        var dir = f.openArea(io, false, true) catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };
        defer dir.close(io);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = dir.iterate();
        var seen: usize = 0;
        while (try it.next(io)) |entry| : (seen += 1) {
            if (seen >= 1024) break; // Locket's area holds a few files
            if (entry.kind != .file or entry.name[0] == '.') continue; // temp files are hidden; links aren't files
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        return names.toOwnedSlice(gpa);
    }

    fn read(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8) anyerror!Object {
        const f = self(ptr);
        try check(ptr, io, gpa);
        try checkFileName(name);
        var dir = try f.openArea(io, false, false);
        defer dir.close(io);
        // Windows opens a file it doesn't follow links for in asynchronous
        // mode, which plain reads can't use: there, a link is refused by
        // looking first (making one there takes administrator rights).
        const windows = builtin.os.tag == .windows;
        if (windows) {
            const st = try dir.statFile(io, name, .{ .follow_symlinks = false });
            if (st.kind == .sym_link) return error.FolderFileIsLink;
        }
        var file = dir.openFile(io, name, .{ .follow_symlinks = windows, .allow_directory = false }) catch |e| switch (e) {
            error.SymLinkLoop => return error.FolderFileIsLink,
            else => return e,
        };
        defer file.close(io);
        var reader = file.reader(io, &.{});
        const data = reader.interface.allocRemaining(gpa, .limited(connector_mod.max_object + 1)) catch |e| switch (e) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => return error.ObjectTooLarge,
            error.OutOfMemory => return e,
        };
        if (data.len > connector_mod.max_object) {
            gpa.free(data);
            return error.ObjectTooLarge;
        }
        return .{ .data = data };
    }

    /// A hidden temp file in the same folder, renamed over the target: the
    /// sync tool sees one complete file (NomadFS adds it as one edit).
    /// `expect` isn't enforced (no versions), except `.absent`, checked
    /// just before writing (best effort).
    fn write(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, data: []const u8, expect: Expect) anyerror!void {
        const f = self(ptr);
        try check(ptr, io, gpa);
        try checkFileName(name);
        if (data.len > connector_mod.max_object) return error.ObjectTooLarge;
        var dir = try f.openArea(io, true, false);
        defer dir.close(io);
        if (expect == .absent) {
            if (dir.statFile(io, name, .{ .follow_symlinks = false })) |_| return error.Changed else |_| {}
        }
        var rnd: u32 = 0;
        io.random(std.mem.asBytes(&rnd));
        var tmp_buf: [std.fs.max_name_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.{x}.tmp", .{ name, rnd });
        {
            const file = try dir.createFile(io, tmp, .{ .exclusive = true });
            errdefer dir.deleteFile(io, tmp) catch {};
            defer file.close(io);
            try file.writeStreamingAll(io, data);
            try file.sync(io);
        }
        errdefer dir.deleteFile(io, tmp) catch {};
        // A rename replaces a link itself, never what it points to.
        try dir.rename(tmp, dir, name, io);
    }

    fn remove(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, _: Expect) anyerror!void {
        const f = self(ptr);
        try check(ptr, io, gpa);
        try checkFileName(name);
        var dir = f.openArea(io, false, false) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer dir.close(io);
        dir.deleteFile(io, name) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    /// A file directly in the area: no separators, not `.` or `..`.
    fn checkFileName(name: []const u8) !void {
        if (name.len == 0 or name.len > 200 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.BadFileName;
        for (name) |c| if (c == '/' or c == '\\' or c == 0) return error.BadFileName;
    }

    fn versioned(_: *anyopaque) bool {
        return false;
    }

    fn isCopyOf(_: *anyopaque, name: []const u8, base: []const u8) bool {
        return isConflictCopy(name, base);
    }

    fn describe(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror![]const u8 {
        const f = self(ptr);
        return std.fmt.allocPrint(gpa, "folder at {s}", .{f.root});
    }
};

test "a folder connector writes, lists, reads and removes, and refuses a missing folder" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);

    var f: Folder = .{ .root = root };
    const c = f.connector();
    try c.check(io, a);
    try t.expectEqual(@as(usize, 0), (try c.list(io, a)).len);
    try t.expect(try c.readOptional(io, a, "vault.enc") == null);
    try c.write(io, a, "vault.enc", "one", .absent);
    try t.expectError(error.Changed, c.write(io, a, "vault.enc", "dup", .absent));
    try c.write(io, a, "vault.enc", "two", .any);
    try t.expectEqualStrings("two", (try c.read(io, a, "vault.enc")).data);
    const names = try c.list(io, a);
    try t.expectEqual(@as(usize, 1), names.len); // the temp files are gone
    try c.remove(io, a, "vault.enc", .any);
    try c.remove(io, a, "vault.enc", .any); // already gone: fine

    var missing: Folder = .{ .root = try std.fs.path.join(a, &.{ root, "nope" }) };
    try t.expectError(error.FolderMissing, missing.connector().check(io, a));
    try t.expectError(error.FolderMissing, missing.connector().write(io, a, "x", "y", .any));
    var relative: Folder = .{ .root = "relative/path" };
    try t.expectError(error.FolderNotAbsolute, relative.connector().check(io, a));
    try t.expectError(error.BadFileName, c.read(io, a, "../config.json"));
    try t.expectError(error.ObjectTooLarge, c.write(io, a, "big", try a.alloc(u8, connector_mod.max_object + 1), .any));
}

test "a folder connector refuses links planted in the shared folder" {
    const t = std.testing;
    const io = t.io;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    try tmp.dir.createDirPath(io, "shared");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/secret", .data = "private" });

    // The area itself a link.
    try tmp.dir.symLink(io, try std.fs.path.join(a, &.{ base, "elsewhere" }), "shared/locket", .{ .is_directory = true });
    var f: Folder = .{ .root = try std.fs.path.join(a, &.{ base, "shared" }) };
    try t.expectError(error.FolderAreaNotDirectory, f.connector().read(io, a, "secret"));
    try t.expectError(error.FolderAreaNotDirectory, f.connector().write(io, a, "vault.enc", "x", .any));
    try tmp.dir.deleteFile(io, "shared/locket");

    // A file in the area a link.
    try tmp.dir.createDirPath(io, "shared/locket");
    try tmp.dir.symLink(io, try std.fs.path.join(a, &.{ base, "elsewhere", "secret" }), "shared/locket/vault.enc", .{});
    try t.expectError(error.FolderFileIsLink, f.connector().read(io, a, "vault.enc"));
    try t.expectEqual(@as(usize, 0), (try f.connector().list(io, a)).len);
    // Writing replaces the link, and leaves its target alone.
    try f.connector().write(io, a, "vault.enc", "new", .any);
    try t.expectEqualStrings("new", (try f.connector().read(io, a, "vault.enc")).data);
    try t.expectEqualStrings("private", try tmp.dir.readFileAlloc(io, "elsewhere/secret", a, .limited(64)));
}
