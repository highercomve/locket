//! `locket`, the command line (the desktop window is `locket-app`).
//!
//!     locket ls [project | project/workspace]
//!     printf 'secret' | locket set project[/workspace]/NAME
//!     locket get project[/workspace]/NAME
//!     locket rm project[/workspace]/NAME
//!     locket rm --workspace project/workspace
//!     locket rm --project project
//!     locket run project[/workspace] [--only A,B] [--prefix] -- command [args...]
//!
//! Every project has a `default` workspace: leaving the workspace out
//! means it (`locket run hub -- cmd`, `locket set hub/API_KEY`). Address
//! rules live in the core (`vault.Ref`); this file parses argv and prints.
//!
//! `set` reads the value from stdin, so the secret never sits in the
//! shell's history or argv (visible in `ps`). `run` injects a workspace's
//! secrets over the child's environment and returns its exit code: the
//! plain way for an agent to get a secret without it ever touching a chat.
//! @atlas layer: front

const std = @import("std");
const vault = @import("vault.zig");

const assert = std.debug.assert;
const Ref = vault.Ref;

const program = "locket";
const stdin_limit = 1 << 20; // a secret bigger than 1 MiB is a paste mistake

var io: std.Io = undefined;

/// Runs one command; `argv` excludes the program name.
pub fn main(init: std.process.Init, argv: []const []const u8) !u8 {
    io = init.io;
    const arena = init.arena.allocator();
    if (argv.len == 0) return usage(2);
    const cmd = std.meta.stringToEnum(Command, argv[0]) orelse return usage(2);
    if (cmd.isHelp()) return usage(0);

    const data_path = try vault.dataDir(init.environ_map, arena);
    var v = vault.open(io, arena, data_path, cmd.mode()) catch |err| {
        return fail("opening the vault: {s}", .{describe(err)});
    };
    defer v.close();

    return dispatch(&v, cmd, arena, init.environ_map, argv[1..]) catch |err| switch (err) {
        error.Usage => usage(2),
        else => fail("{s}", .{describe(err)}),
    };
}

const Command = enum {
    ls,
    set,
    get,
    rm,
    run,
    help,
    @"--help",
    @"-h",

    fn isHelp(c: Command) bool {
        return c == .help or c == .@"--help" or c == .@"-h";
    }

    /// Commands that change the vault hold its write lock.
    fn mode(c: Command) vault.Mode {
        return switch (c) {
            .set, .rm => .write,
            else => .read,
        };
    }
};

fn describe(err: anyerror) []const u8 {
    return vault.describeError(err) orelse @errorName(err);
}

fn usage(code: u8) u8 {
    var buf: [1024]u8 = undefined;
    var w = if (code == 0) std.Io.File.stdout().writerStreaming(io, &buf) else std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.writeAll(
        \\usage:
        \\  locket ls [project | project/workspace]
        \\  locket set project[/workspace]/NAME     value on stdin
        \\  locket get project[/workspace]/NAME
        \\  locket rm project[/workspace]/NAME
        \\  locket rm --workspace project/workspace
        \\  locket rm --project project
        \\  locket run project[/workspace] [--only A,B] [--prefix] -- command [args...]
        \\
        \\Without a workspace, the project's `default` workspace is meant.
        \\run injects the variables under their stored names; --prefix
        \\uses LOCKET_<NAME> instead. The desktop app is locket-app.
        \\
    ) catch {};
    w.interface.flush() catch {};
    return code;
}

/// Prints `locket: <message>` and reports failure to the shell.
fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    stderr.interface.print(program ++ ": " ++ fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
    return 1;
}

fn notFound(what: []const u8, address: []const u8) u8 {
    return fail("no such {s}: {s}", .{ what, address });
}

fn dispatch(
    v: *vault.Vault,
    cmd: Command,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    args: []const []const u8,
) !u8 {
    switch (cmd) {
        .run => return run(v, arena, env, args),
        .ls => return switch (args.len) {
            0 => lsProjects(v),
            1 => ls(v, args[0]),
            else => error.Usage,
        },
        .rm => return rm(v, args),
        .set, .get => {
            if (args.len != 1) return error.Usage;
            return if (cmd == .set) setSecret(v, arena, args[0]) else getSecret(v, args[0]);
        },
        .help, .@"--help", .@"-h" => unreachable, // main answers these
    }
}

const Out = struct {
    buf: [4096]u8 = undefined,
    w: std.Io.File.Writer = undefined,

    fn init(o: *Out) *std.Io.Writer {
        o.w = std.Io.File.stdout().writerStreaming(io, &o.buf);
        return &o.w.interface;
    }
};

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn lsProjects(v: *vault.Vault) !u8 {
    var o: Out = .{};
    const out = o.init();
    if (v.names().len == 0) {
        out.writeAll("no projects yet: printf 'value' | locket set myproject/API_KEY\n") catch {};
    }
    for (v.names()) |name| {
        const p = v.project(name).?;
        const w = p.workspaces.count();
        const s = p.secretCount();
        out.print("{s}  ({d} workspace{s}, {d} secret{s})\n", .{ name, w, plural(w), s, plural(s) }) catch {};
    }
    out.flush() catch {};
    return 0;
}

/// `ls project`: its workspaces. `ls project/workspace`: its variables.
fn ls(v: *vault.Vault, text: []const u8) !u8 {
    const a = try vault.Address.parse(text);
    if (a.secret != null) return error.InvalidAddress;
    const p = v.project(a.project) orelse return notFound("project", a.project);
    var o: Out = .{};
    const out = o.init();
    if (a.workspace) |ws| {
        const w = p.workspaces.getPtr(ws) orelse return notFound("workspace", text);
        for (w.secrets.keys()) |name| {
            out.print("{f}\n", .{Ref{ .project = a.project, .workspace = ws, .name = name }}) catch {};
        }
    } else {
        for (p.workspaces.keys(), p.workspaces.values()) |ws, w| {
            const n = w.secrets.count();
            out.print("{s}/{s}  ({d} secret{s})\n", .{ a.project, ws, n, plural(n) }) catch {};
        }
    }
    out.flush() catch {};
    return 0;
}

fn setSecret(v: *vault.Vault, arena: std.mem.Allocator, text: []const u8) !u8 {
    const r = try Ref.variableOf(text);
    const value = trimNewline(try readStdinAll(arena));
    defer std.crypto.secureZero(u8, @constCast(value));
    try v.setSecret(r.project, r.workspace, r.name.?, value);
    try v.save();
    var o: Out = .{};
    const out = o.init();
    out.print("stored {f}\n", .{r}) catch {};
    out.flush() catch {};
    return 0;
}

/// Drops the trailing newline a heredoc or echo adds: a secret is not a
/// line of text.
fn trimNewline(value: []const u8) []const u8 {
    var val = value;
    if (val.len > 0 and val[val.len - 1] == '\n') {
        val = val[0 .. val.len - 1];
        if (val.len > 0 and val[val.len - 1] == '\r') val = val[0 .. val.len - 1];
    }
    return val;
}

fn getSecret(v: *vault.Vault, text: []const u8) !u8 {
    const r = try Ref.variableOf(text);
    const value = v.secret(r.project, r.workspace, r.name.?) orelse return notFound("variable", text);
    var o: Out = .{};
    const out = o.init();
    out.writeAll(value) catch {};
    out.writeAll("\n") catch {};
    out.flush() catch {};
    return 0;
}

const RmTarget = enum { variable, workspace, project };

/// `rm ADDRESS` removes a variable; workspaces and projects take a flag,
/// so `rm hub/stage` can never mean "the whole stage workspace" by
/// accident.
fn rmTarget(args: []const []const u8) !struct { RmTarget, []const u8 } {
    if (args.len == 1) return .{ .variable, args[0] };
    if (args.len != 2) return error.Usage;
    if (std.mem.eql(u8, args[0], "--workspace")) return .{ .workspace, args[1] };
    if (std.mem.eql(u8, args[0], "--project")) return .{ .project, args[1] };
    return error.Usage;
}

fn rm(v: *vault.Vault, args: []const []const u8) !u8 {
    const target, const text = try rmTarget(args);
    switch (target) {
        .variable => {
            const r = try Ref.variableOf(text);
            if (!v.removeSecret(r.project, r.workspace, r.name.?)) {
                if (v.workspace(r.project, r.name.?) != null) {
                    return fail("{s} is a workspace: locket rm --workspace {s}", .{ text, text });
                }
                return notFound("variable", text);
            }
        },
        .workspace => {
            const r = try Ref.workspaceOf(text);
            if (vault.isDefault(r.workspace)) return error.DefaultWorkspace;
            if (!v.removeWorkspace(r.project, r.workspace)) return notFound("workspace", text);
        },
        .project => {
            const a = try vault.Address.parse(text);
            if (a.workspace != null) return error.InvalidAddress;
            if (!v.removeProject(a.project)) return notFound("project", text);
        },
    }
    try v.save();
    var o: Out = .{};
    const out = o.init();
    out.print("removed {s}\n", .{text}) catch {};
    out.flush() catch {};
    return 0;
}

const RunArgs = struct {
    target: []const u8,
    only: []const u8 = "",
    prefix: bool = false,
    child: []const []const u8,
};

fn parseRun(argv: []const []const u8) !RunArgs {
    var target: ?[]const u8 = null;
    var args: RunArgs = .{ .target = "", .child = &.{} };
    var pos: usize = 0;
    while (pos < argv.len) : (pos += 1) { // bounded: argv is finite
        const arg = argv[pos];
        if (std.mem.eql(u8, arg, "--")) {
            args.child = argv[pos + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--only")) {
            pos += 1;
            if (pos >= argv.len) return error.Usage;
            args.only = argv[pos];
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            args.prefix = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            args.prefix = false; // the default now; kept so old scripts still run
        } else if (arg.len > 0 and arg[0] != '-' and target == null) {
            target = arg;
        } else return error.Usage;
    }
    if (args.child.len == 0) return error.Usage;
    args.target = target orelse return error.Usage;
    return args;
}

/// Injects a workspace's secrets over the child's environment: the child
/// sees them, the caller's output stream never does.
fn run(
    v: *vault.Vault,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    const args = try parseRun(argv);
    const r = try Ref.workspaceOf(args.target);
    const w = v.workspace(r.project, r.workspace) orelse {
        return notFound(if (v.project(r.project) == null) "project" else "workspace", args.target);
    };

    var environ = try std.process.Environ.Map.clone(env, arena);
    const injected = inject(arena, &environ, w, args.only, args.prefix) catch |err| switch (err) {
        error.NotFound => return fail("--only names a variable {f} doesn't have", .{r}),
        else => return err,
    };
    if (injected == 0) return fail("{f} has no variables to inject", .{r});

    var child = std.process.spawn(io, .{
        .argv = args.child,
        .environ_map = &environ,
    }) catch |err| {
        return fail("could not start '{s}': {s}", .{ args.child[0], @errorName(err) });
    };
    const term = child.wait(io) catch |err| {
        child.kill(io);
        return fail("waiting for '{s}': {s}", .{ args.child[0], @errorName(err) });
    };

    // Names and counts only: on stderr, so the child's stdout stays its own.
    var buf: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    stderr.interface.print("[locket injected {d} variable{s} from {f} into {s}]\n", .{
        injected, plural(injected), r, args.child[0],
    }) catch {};
    stderr.flush() catch {};

    // The child decides the parent's exit code; a signal maps to 128+n.
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| @as(u8, 128) +% @as(u8, @truncate(@intFromEnum(sig))),
        else => 1,
    };
}

/// Puts the workspace's variables (all, or the `only` list) into `environ`;
/// how many. error.NotFound when an `only` name isn't in the workspace.
fn inject(
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    w: *const vault.Workspace,
    only: []const u8,
    prefix: bool,
) !usize {
    const allowed = try namesSplit(arena, only);
    var it = allowed.keyIterator();
    while (it.next()) |name| {
        if (!w.secrets.contains(name.*)) return error.NotFound;
    }
    var injected: usize = 0;
    for (w.secrets.keys(), w.secrets.values()) |name, value| {
        if (allowed.count() > 0 and !allowed.contains(name)) continue;
        try environ.put(if (prefix) try envName(arena, name) else name, value);
        injected += 1;
    }
    return injected;
}

/// The `--only` names, as a set. Empty set: every secret passes.
fn namesSplit(arena: std.mem.Allocator, only: []const u8) !std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .{};
    if (only.len == 0) return names;
    var split = std.mem.splitScalar(u8, only, ',');
    while (split.next()) |n| {
        if (n.len == 0) return error.Usage;
        try names.put(arena, n, {});
    }
    return names;
}

/// `--prefix`: `NAME` -> `LOCKET_NAME`, uppercase, non-identifier bytes
/// underscored. (Stored names are already valid variable names:
/// vault.checkVarName.)
fn envName(arena: std.mem.Allocator, secret_name: []const u8) ![]u8 {
    const prefix = "LOCKET_";
    const out = try arena.alloc(u8, secret_name.len + prefix.len);
    @memcpy(out[0..prefix.len], prefix);
    for (secret_name, out[prefix.len..]) |c, *o| {
        o.* = switch (c) {
            'a'...'z' => c - 'a' + 'A',
            'A'...'Z', '0'...'9' => c,
            else => '_',
        };
    }
    return out;
}

fn readStdinAll(gpa: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &buf);
    return stdin.interface.allocRemaining(gpa, .limited(stdin_limit));
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test Command {
    for ([_][]const u8{ "help", "--help", "-h" }) |word| {
        try testing.expect(std.meta.stringToEnum(Command, word).?.isHelp());
    }
    try testing.expect(!Command.run.isHelp());
    try testing.expectEqual(vault.Mode.write, Command.rm.mode());
    try testing.expectEqual(vault.Mode.read, Command.run.mode());
    try testing.expect(std.meta.stringToEnum(Command, "nope") == null);
}

test rmTarget {
    const t1, const a1 = try rmTarget(&.{"hub/stage"});
    try testing.expectEqual(RmTarget.variable, t1);
    try testing.expectEqualStrings("hub/stage", a1);
    const t2, _ = try rmTarget(&.{ "--workspace", "hub/stage" });
    try testing.expectEqual(RmTarget.workspace, t2);
    const t3, _ = try rmTarget(&.{ "--project", "hub" });
    try testing.expectEqual(RmTarget.project, t3);
    try testing.expectError(error.Usage, rmTarget(&.{ "--everything", "hub" }));
    try testing.expectError(error.Usage, rmTarget(&.{}));
}

test parseRun {
    const r = try parseRun(&.{ "hub/stage", "--only", "A,B", "--prefix", "--", "env", "-0" });
    try testing.expectEqualStrings("hub/stage", r.target);
    try testing.expectEqualStrings("A,B", r.only);
    try testing.expect(r.prefix);
    try testing.expectEqual(@as(usize, 2), r.child.len);
    try testing.expectError(error.Usage, parseRun(&.{"hub"})); // no command
    try testing.expectError(error.Usage, parseRun(&.{ "hub", "x", "--", "true" })); // two targets
    try testing.expect(!(try parseRun(&.{ "hub", "--raw", "--", "true" })).prefix);
}

test inject {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w: vault.Workspace = .{};
    try w.secrets.put(a, "API_KEY", "k");
    try w.secrets.put(a, "db.url", "d");
    var env: std.process.Environ.Map = .init(a);
    try testing.expectEqual(@as(usize, 2), try inject(a, &env, &w, "", false));
    try testing.expectEqualStrings("k", env.get("API_KEY").?);
    var env2: std.process.Environ.Map = .init(a);
    try testing.expectEqual(@as(usize, 1), try inject(a, &env2, &w, "db.url", true));
    try testing.expectEqualStrings("d", env2.get("LOCKET_DB_URL").?);
    try testing.expectError(error.NotFound, inject(a, &env2, &w, "MISSING", false));
}

test trimNewline {
    try testing.expectEqualStrings("v", trimNewline("v\r\n"));
    try testing.expectEqualStrings("v", trimNewline("v\n"));
    try testing.expectEqualStrings("v\n", trimNewline("v\n\n"));
}
