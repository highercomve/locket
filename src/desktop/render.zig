//! Brings the window in line with the vault on disk: projects, the
//! selected project's workspaces, and the selected workspace's variables.
//! @atlas layer: front

const std = @import("std");
const oriel = @import("oriel");
const vault = @import("../vault.zig");
const st = @import("state.zig");
const w = @import("widgets.zig");

const ui = oriel.ui;
const sid = st.sid;
const s = &st.s;

/// Re-reads the sealed vault (a snapshot: no lock is held afterwards) and
/// updates every part of the window from it.
pub fn render(e: *ui.Engine) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    var v = vault.open(st.io, arena.allocator(), st.data_path, .read) catch |err| {
        try w.text(e, sid("empty-title"), "The vault failed to open");
        try w.text(e, sid("empty-text"), describe(err));
        try w.display(e, sid("empty"), true);
        try w.display(e, sid("pane"), false);
        e.tree.layout();
        return err;
    };
    defer v.close();

    _ = s.names.reset(.retain_capacity);
    try renderProjects(e, &v);
    if (s.project) |name| {
        const p = v.project(name).?;
        try renderProject(e, name, p);
        const ws = try renderWorkspaces(e, p);
        try renderEditor(e, ws);
        try renderSecrets(e, p.workspaces.getPtr(ws).?);
    } else try renderEmpty(e);
    e.tree.layout();
}

fn renderProjects(e: *ui.Engine, v: *vault.Vault) !void {
    const names = v.names();
    s.projects = try dupeAll(s.names.allocator(), names[0..@min(names.len, st.max_rows)]);
    if (s.project) |sel| if (v.project(sel) == null) try s.set(&s.project, null);
    if (s.project == null and names.len > 0) try s.set(&s.project, names[0]);

    var ids: [st.max_rows]i64 = undefined;
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    for (s.projects, 0..) |name, i| {
        const n = v.project(name).?.secretCount();
        total += n;
        ids[i] = try mountRow(st.ProjectRow, e, st.project_rows, st.project_styles, i, &.{
            .{ .name = "name", .value = name },
            .{ .name = "count", .value = try std.fmt.bufPrint(&buf, "{d}", .{n}) },
        });
        try st.ProjectRow.setState(&e.tree, ids[i], "selected", st.isSelected(s.project, name));
    }
    try stamp(e, sid("projects"), ids[0..s.projects.len]);
    try w.text(e, sid("project-count"), try std.fmt.bufPrint(&buf, "{d} · {d} VARS", .{ names.len, total }));
}

fn renderEmpty(e: *ui.Engine) !void {
    s.workspaces = &.{};
    s.secrets = &.{};
    s.secret_count = 0;
    try w.display(e, sid("empty"), true);
    try w.display(e, sid("pane"), false);
    try w.text(e, sid("empty-title"), "Create your first project");
    try w.text(e, sid("empty-text"), "A project groups the environment variables one agent or tool needs. Its variables live in workspaces (default, stage, prod…). Name a project in the panel on the left.");
    try stamp(e, sid("workspaces"), &.{});
    try stamp(e, sid("secrets"), &.{});
}

fn renderProject(e: *ui.Engine, name: []const u8, p: *const vault.Project) !void {
    try w.display(e, sid("empty"), false);
    try w.display(e, sid("pane"), true);
    try w.text(e, sid("project-title"), name);
    try w.text(e, sid("project-meta"), if (p.description.len > 0) p.description else "No description");
    try w.display(e, sid("project-form"), s.project_form);
    try w.display(e, sid("edit-project"), !s.project_form);
}

/// The workspace tabs (`default` first, always there); the selected
/// workspace's name.
fn renderWorkspaces(e: *ui.Engine, p: *const vault.Project) ![]const u8 {
    if (s.workspace) |ws| if (!p.workspaces.contains(ws)) try s.set(&s.workspace, null);
    if (s.workspace == null) try s.set(&s.workspace, vault.default_workspace);
    const names = p.workspaces.keys();
    s.workspaces = try dupeAll(s.names.allocator(), names[0..@min(names.len, st.max_rows)]);

    var ids: [st.max_rows]i64 = undefined;
    var buf: [256]u8 = undefined;
    for (s.workspaces, 0..) |name, i| {
        ids[i] = try mountRow(st.WorkspaceTab, e, st.tab_rows, st.tab_styles, i, &.{
            .{ .name = "name", .value = name },
            .{ .name = "count", .value = try std.fmt.bufPrint(&buf, "{d}", .{p.workspaces.getPtr(name).?.secrets.count()}) },
        });
        try st.WorkspaceTab.setState(&e.tree, ids[i], "selected", st.isSelected(s.workspace, name));
    }
    try stamp(e, sid("workspaces"), ids[0..s.workspaces.len]);

    const ws = s.workspace.?;
    const is_default = vault.isDefault(ws);
    try w.text(e, sid("ws-title"), try upperPrint(&buf, "VARIABLES · {s}", .{ws}));
    try w.display(e, sid("rename-workspace"), !is_default and !s.workspace_form);
    try w.display(e, sid("delete-workspace"), !is_default);
    try w.display(e, sid("ws-form"), s.workspace_form);
    const ref: vault.Ref = .{ .project = s.project.?, .workspace = ws };
    try w.text(e, sid("run-hint"), try std.fmt.bufPrint(&buf, "locket run {f} -- <command>", .{ref}));
    return ws;
}

fn renderEditor(e: *ui.Engine, ws: []const u8) !void {
    try w.display(e, sid("editor"), s.editor != .closed);
    try w.display(e, sid("new-secret"), s.editor == .closed);
    var buf: [256]u8 = undefined;
    switch (s.editor) {
        .closed => {},
        .new => {
            try w.text(e, sid("editor-title"), try upperPrint(&buf, "NEW VARIABLE IN {s}", .{ws}));
            try w.text(e, sid("editor-hint"), "Use the name your tool expects (e.g. DATABASE_URL). Enter saves, Esc cancels.");
        },
        .edit => {
            try w.text(e, sid("editor-title"), try std.fmt.bufPrint(&buf, "EDIT {s}", .{s.editing orelse ""}));
            try w.text(e, sid("editor-hint"), "Change the name or replace the value. Enter saves, Esc cancels.");
        },
    }
}

fn renderSecrets(e: *ui.Engine, ws: *const vault.Workspace) !void {
    const keys = ws.secrets.keys();
    const values = ws.secrets.values();
    s.secrets = try dupeAll(s.names.allocator(), keys[0..@min(keys.len, st.max_rows)]);
    s.secret_count = keys.len;

    var ids: [st.max_rows]i64 = undefined;
    var buf: [64]u8 = undefined;
    try w.text(e, sid("secret-count"), try std.fmt.bufPrint(&buf, "{d}", .{keys.len}));
    for (s.secrets, values[0..s.secrets.len], 0..) |name, secret, i| {
        const value = secret.value;
        const revealed = st.isSelected(s.revealed, name);
        ids[i] = try mountRow(st.SecretRow, e, st.secret_rows, st.secret_styles, i, &.{
            .{ .name = "name", .value = name },
            .{ .name = "value", .value = if (revealed) value else try mask(&buf, value.len) },
        });
        try st.SecretRow.setState(&e.tree, ids[i], "revealed", revealed);
        try w.label(e, st.SecretRow.id("reveal", ids[i]), if (revealed) "Hide" else "Show");
    }
    try stamp(e, sid("secrets"), ids[0..s.secrets.len]);
    try w.display(e, sid("no-secrets"), keys.len == 0 and s.editor == .closed);
    try w.display(e, sid("secrets"), keys.len > 0);
}

/// Mounts (or updates) row `i` of a list based at `rows`; its base id.
pub fn mountRow(comptime View: type, e: *ui.Engine, rows: i64, styles: i64, i: usize, bindings: []const ui.Binding) !i64 {
    const base = rows + @as(i64, @intCast(i)) * st.row_stride;
    if (e.tree.get(base) == null) {
        _ = try View.mount(&e.tree, base, styles, bindings);
    } else try View.update(&e.tree, base, bindings);
    return base;
}

/// Makes `ids` the list's rows; rows past them are destroyed.
pub fn stamp(e: *ui.Engine, list: i64, ids: []const i64) !void {
    if (!try e.tree.stampKids(list, ids)) return error.InvalidTemplate;
}

fn mask(buf: []u8, len: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}  {d} chars", .{len});
}

fn upperPrint(buf: []u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    const out = try std.fmt.bufPrint(buf, fmt, args);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

fn dupeAll(a: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |item, *o| o.* = try a.dupe(u8, item);
    return out;
}

/// Shows `message` on the header's status line.
pub fn status(e: *ui.Engine, message: []const u8) void {
    w.text(e, sid("status"), message) catch {};
    e.tree.layout();
}

/// The message the window shows for an error.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyValue => "a value is required",
        error.NotFound => "it's gone: the vault changed on disk (reloaded)",
        else => vault.describeError(err) orelse "couldn't complete that (see the log)",
    };
}
