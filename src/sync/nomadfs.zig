//! The NomadFS connector: the shared vault in NomadFS's swarm folder (the
//! one folder every device of a swarm reads and writes), through the
//! running node's local swarm API: no mount needed
//! (https://nomadfs.foreachdeveloper.com).
//!
//! The location is NomadFS's device folder (`~/.nomadfs`, where its keys
//! live). The running node (the app, or `nomadfs` as a service) publishes
//! its API there in `api.json`: an HTTP address on 127.0.0.1 and a token.
//! Locket keeps its files under `locket/` in the swarm folder:
//!
//!   GET    files/locket/<name>   the file, ETag = its content id
//!   PUT    files/locket/<name>   If-Match / If-None-Match: compare-and-swap
//!   DELETE files/locket/<name>
//!   GET    list/locket
//!
//! Writes are versioned (412 when the file changed since it was read), and
//! the node refuses them until it has synced with its peers once since it
//! started (503 NotSynced): an empty folder on a device that just woke up
//! never overwrites the swarm's vault. Edits two devices make before they
//! meet still become a conflict copy (`vault (conflict from <device>).enc`),
//! which the engine merges and removes.
//! @atlas layer: sync

const std = @import("std");
const builtin = @import("builtin");
const connector_mod = @import("connector.zig");
const Connector = connector_mod.Connector;
const Object = connector_mod.Object;
const Expect = connector_mod.Expect;

pub const id = "nomadfs";
/// Locket's folder inside the swarm folder.
const area = "locket";
const api_file = "api.json";
/// A response's size bound: the node's 8 MiB file limit and headers.
const max_response = connector_mod.max_object + 64 * 1024;
const timeout_ms = 60_000;

/// NomadFS's default device folder: `~/.nomadfs`.
pub fn defaultLocation(home: ?[]const u8, gpa: std.mem.Allocator) !?[]u8 {
    const h = home orelse return null;
    return try std.fs.path.join(gpa, &.{ h, ".nomadfs" });
}

pub const NomadFs = struct {
    /// NomadFS's device folder (where api.json is).
    dir: []const u8,

    pub fn connector(n: *NomadFs) Connector {
        return .{ .ptr = n, .vtable = &vtable };
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

    fn self(ptr: *anyopaque) *NomadFs {
        return @ptrCast(@alignCast(ptr));
    }

    /// The node answers (it runs, and its API is this one).
    fn check(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror!void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const r = try self(ptr).call(io, arena.allocator(), .{ .method = "GET", .what = "status" });
        if (r.code != 200) return statusError(r);
    }

    fn list(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator) anyerror![]const []const u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const r = try self(ptr).call(io, arena.allocator(), .{ .method = "GET", .what = "list/" ++ area });
        if (r.code == 404) return &.{};
        if (r.code != 200) return statusError(r);
        const Entry = struct { name: []const u8, dir: bool };
        const entries = std.json.parseFromSliceLeaky([]const Entry, arena.allocator(), r.body, .{ .ignore_unknown_fields = true }) catch return error.NomadFsBadAnswer;
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        for (entries[0..@min(entries.len, 1024)]) |e| {
            if (!e.dir) try names.append(gpa, try gpa.dupe(u8, e.name));
        }
        return names.toOwnedSlice(gpa);
    }

    fn read(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8) anyerror!Object {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const r = try self(ptr).call(io, arena.allocator(), .{ .method = "GET", .what = try fileUrl(arena.allocator(), name) });
        if (r.code == 404) return error.FileNotFound;
        if (r.code != 200) return statusError(r);
        const version = r.etag orelse return error.NomadFsBadAnswer;
        return .{ .data = try gpa.dupe(u8, r.body), .version = try gpa.dupe(u8, version) };
    }

    fn write(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, data: []const u8, expect: Expect) anyerror!void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const r = try self(ptr).call(io, arena.allocator(), .{ .method = "PUT", .what = try fileUrl(arena.allocator(), name), .expect = expect, .body = data });
        if (r.code == 412) return error.Changed;
        if (r.code != 200) return statusError(r);
    }

    fn remove(ptr: *anyopaque, io: std.Io, gpa: std.mem.Allocator, name: []const u8, expect: Expect) anyerror!void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const r = try self(ptr).call(io, arena.allocator(), .{ .method = "DELETE", .what = try fileUrl(arena.allocator(), name), .expect = expect });
        if (r.code == 412) return error.Changed;
        if (r.code != 204 and r.code != 404) return statusError(r);
    }

    fn versioned(_: *anyopaque) bool {
        return true;
    }

    fn isCopyOf(_: *anyopaque, name: []const u8, base: []const u8) bool {
        return connector_mod.isConflictCopy(name, base);
    }

    fn describe(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror![]const u8 {
        return std.fmt.allocPrint(gpa, "NomadFS swarm folder (node at {s})", .{self(ptr).dir});
    }

    // ---------------------------------------------------------------- http

    const Response = struct {
        code: u16,
        etag: ?[]const u8 = null,
        /// X-NomadFS-Error: the node's error name on a failure.
        err: ?[]const u8 = null,
        body: []const u8 = "",
    };

    const Request = struct {
        method: []const u8,
        /// The path under the API's base (`files/locket/vault.enc`).
        what: []const u8,
        expect: Expect = .any,
        body: []const u8 = "",
    };

    /// One request to the node's API, all in `arena`.
    fn call(n: *NomadFs, io: std.Io, arena: std.mem.Allocator, req: Request) !Response {
        const method = req.method;
        const what = req.what;
        const expect = req.expect;
        const body = req.body;
        const ep = try n.endpoint(io, arena);
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", ep.port);
        const stream = addr.connect(io, .{ .mode = .stream }) catch return error.NomadFsNotRunning;
        defer stream.close(io);
        // A node that stalls can't hang every locket command (they all sync
        // first) or the window's sync: each read and write waits this long.
        setTimeouts(stream.socket.handle, timeout_ms) catch {};

        var wbuf: [4096]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        const w = &writer.interface;
        try w.print("{s} {s}{s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: {d}\r\n", .{ method, ep.base, what, body.len });
        switch (expect) {
            .any => {},
            .absent => try w.writeAll("If-None-Match: *\r\n"),
            .version => |v| try w.print("If-Match: {s}\r\n", .{v}),
        }
        try w.writeAll("\r\n");
        try w.writeAll(body);
        try w.flush();

        var rbuf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        const raw = reader.interface.allocRemaining(arena, .limited(max_response)) catch |e| switch (e) {
            error.StreamTooLong => return error.NomadFsBadAnswer,
            error.ReadFailed => return if (reader.err) |re| (if (re == error.WouldBlock) error.NomadFsTimeout else error.NomadFsNotRunning) else error.NomadFsNotRunning,
            else => return error.NomadFsNotRunning,
        };
        return parseResponse(raw);
    }

    const Endpoint = struct { port: u16, base: []const u8 };

    /// The running node's API, from `<dir>/api.json`: a regular file only
    /// this user can read (the node writes it 0600), so another user
    /// can't plant one that sends the vault to their own server.
    fn endpoint(n: *NomadFs, io: std.Io, arena: std.mem.Allocator) !Endpoint {
        if (!std.fs.path.isAbsolute(n.dir)) return error.FolderNotAbsolute;
        // The node writes it next to its device keys: in the folder itself
        // (the app's layout) or in its keys/ (the command line's).
        var path = try std.fs.path.join(arena, &.{ n.dir, api_file });
        const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => blk: {
                path = try std.fs.path.join(arena, &.{ n.dir, "keys", api_file });
                break :blk std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |e2| switch (e2) {
                    error.FileNotFound => return error.NomadFsNotRunning,
                    else => return e2,
                };
            },
            else => return e,
        };
        if (st.kind != .file) return error.NomadFsInsecureApiFile;
        if (comptime builtin.os.tag != .windows) {
            if (st.permissions.toMode() & 0o077 != 0) return error.NomadFsInsecureApiFile;
        }
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch |e| switch (e) {
            error.FileNotFound => return error.NomadFsNotRunning,
            else => return e,
        };
        const Info = struct { url: []const u8 };
        const info = std.json.parseFromSliceLeaky(Info, arena, text, .{ .ignore_unknown_fields = true }) catch return error.NomadFsBadAnswer;
        return parseUrl(info.url);
    }
};

/// `http://127.0.0.1:<port>/<token>/v1/` → port and `/<token>/v1/`. Only
/// the loopback address: a planted api.json can't send the vault away.
fn parseUrl(url: []const u8) !NomadFs.Endpoint {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, prefix)) return error.NomadFsBadAnswer;
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NomadFsBadAnswer;
    const base = rest[slash..];
    if (!std.mem.endsWith(u8, base, "/")) return error.NomadFsBadAnswer;
    for (base) |c| if (c <= ' ' or c >= 0x7f) return error.NomadFsBadAnswer;
    return .{ .port = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.NomadFsBadAnswer, .base = base };
}

/// `files/locket/<name>`, the name percent-encoded.
fn fileUrl(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("files/" ++ area ++ "/");
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => try out.writer.writeByte(c),
        else => try out.writer.print("%{X:0>2}", .{c}),
    };
    return out.written();
}

/// Bounds each blocking read and write on `handle` to `ms`.
fn setTimeouts(handle: SocketHandle, ms: u32) !void {
    if (builtin.os.tag == .windows) {
        const ws = std.os.windows.ws2_32;
        if (winsock.setsockopt(handle, ws.SOL.SOCKET, ws.SO.RCVTIMEO, std.mem.asBytes(&ms), @sizeOf(u32)) != 0) return error.Unexpected;
        if (winsock.setsockopt(handle, ws.SOL.SOCKET, ws.SO.SNDTIMEO, std.mem.asBytes(&ms), @sizeOf(u32)) != 0) return error.Unexpected;
        return;
    }
    const tv = std.posix.timeval{
        .sec = @intCast(ms / std.time.ms_per_s),
        .usec = @intCast((ms % std.time.ms_per_s) * std.time.us_per_ms),
    };
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
}

const SocketHandle = @TypeOf(@as(std.Io.net.Socket, undefined).handle);

const winsock = struct {
    extern "ws2_32" fn setsockopt(s: SocketHandle, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;
};

/// The answer, all of it: a body shorter than its Content-Length (the
/// node stopped mid-answer) is refused, not taken for a whole file.
fn parseResponse(raw: []const u8) !NomadFs.Response {
    const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.NomadFsBadAnswer;
    var lines = std.mem.splitSequence(u8, raw[0..end], "\r\n");
    const status = lines.next() orelse return error.NomadFsBadAnswer;
    if (status.len < 12 or !std.mem.startsWith(u8, status, "HTTP/1.1 ")) return error.NomadFsBadAnswer;
    var r: NomadFs.Response = .{ .code = std.fmt.parseInt(u16, status[9..12], 10) catch return error.NomadFsBadAnswer, .body = raw[end + 4 ..] };
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(line[0..colon], "etag")) r.etag = value;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "x-nomadfs-error")) r.err = value;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
            const want = std.fmt.parseInt(usize, value, 10) catch return error.NomadFsBadAnswer;
            if (want != r.body.len) return error.NomadFsBadAnswer;
        }
        if (std.ascii.eqlIgnoreCase(line[0..colon], "transfer-encoding")) return error.NomadFsBadAnswer; // the node never chunks
    }
    return r;
}

/// A failed answer as an error the engine and the people understand.
fn statusError(r: NomadFs.Response) anyerror {
    if (r.code == 503 and r.err != null and std.mem.eql(u8, r.err.?, "NotSynced")) return error.NomadFsNotSynced;
    if (r.code == 503) return error.NomadFsUnavailable;
    if (r.code == 413) return error.NomadFsTooLarge;
    if (r.code == 404) return error.NomadFsNoSwarm; // the token's wrong, or no swarm folder
    return error.NomadFsBadAnswer;
}

/// A connector to the node whose device folder is `dir`. It lives in `arena`.
pub fn make(arena: std.mem.Allocator, dir: []const u8) !Connector {
    const n = try arena.create(NomadFs);
    n.* = .{ .dir = try arena.dupe(u8, dir) };
    return n.connector();
}

test parseUrl {
    const ep = try parseUrl("http://127.0.0.1:40883/abc/v1/");
    try std.testing.expectEqual(@as(u16, 40883), ep.port);
    try std.testing.expectEqualStrings("/abc/v1/", ep.base);
    try std.testing.expectError(error.NomadFsBadAnswer, parseUrl("http://10.0.0.1:1/abc/v1/"));
    try std.testing.expectError(error.NomadFsBadAnswer, parseUrl("http://127.0.0.1:1/a b/"));
}

test fileUrl {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("files/locket/vault%20%28conflict%20from%20x%29.enc", try fileUrl(arena.allocator(), "vault (conflict from x).enc"));
}

test parseResponse {
    const r = try parseResponse("HTTP/1.1 503 Not Synced Yet\r\nX-NomadFS-Error: NotSynced\r\n\r\n");
    try std.testing.expectEqual(error.NomadFsNotSynced, statusError(r));
    const whole = try parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nETag: \"ab\"\r\n\r\nhello");
    try std.testing.expectEqualStrings("hello", whole.body);
    // The node stopped mid-answer: refused, not taken for a short file.
    try std.testing.expectError(error.NomadFsBadAnswer, parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nhello"));
    try std.testing.expectError(error.NomadFsBadAnswer, parseResponse("HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\nhello"));
}

test "a node that isn't running is NomadFsNotRunning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try make(arena.allocator(), "/nonexistent/.nomadfs");
    try std.testing.expectError(error.NomadFsNotRunning, c.check(std.testing.io, std.testing.allocator));
}

test "api.json is found in the folder or in its keys/, and only when private" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    var n: NomadFs = .{ .dir = dir };
    try t.expectError(error.NomadFsNotRunning, n.endpoint(io, a));
    // The command line node's layout: keys/api.json.
    try tmp.dir.createDirPath(io, "keys");
    const json = "{\"version\":1,\"url\":\"http://127.0.0.1:4321/tok/v1/\"}";
    try tmp.dir.writeFile(io, .{ .sub_path = "keys/api.json", .data = json, .flags = .{ .permissions = .fromMode(0o600) } });
    try t.expectEqual(@as(u16, 4321), (try n.endpoint(io, a)).port);
    // The app's layout wins when both are there.
    try tmp.dir.writeFile(io, .{ .sub_path = "api.json", .data = "{\"version\":1,\"url\":\"http://127.0.0.1:1234/tok/v1/\"}", .flags = .{ .permissions = .fromMode(0o600) } });
    try t.expectEqual(@as(u16, 1234), (try n.endpoint(io, a)).port);
    // Readable by others: not trusted.
    try tmp.dir.deleteFile(io, "api.json");
    try tmp.dir.writeFile(io, .{ .sub_path = "api.json", .data = json, .flags = .{ .permissions = .fromMode(0o644) } });
    try t.expectError(error.NomadFsInsecureApiFile, n.endpoint(io, a));
}
