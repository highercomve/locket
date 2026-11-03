//! The desktop window's behaviour: Oriel's driver callbacks (boot, event,
//! timer) and the actions behind every button and field.
//!
//! Every edit opens the vault for writing (an exclusive lock, see
//! vault.zig), applies one change, saves and closes it, and only then
//! renders: render takes a shared lock, which would wait forever on the
//! exclusive one this process still held.
//! @atlas layer: front

const std = @import("std");
const oriel = @import("oriel");
const vault = @import("../vault.zig");
const st = @import("state.zig");
const w = @import("widgets.zig");
const input = @import("input.zig");
const view = @import("render.zig");

const ui = oriel.ui;
const sid = st.sid;
const s = &st.s;
const render = view.render;

pub fn boot(e: *ui.Engine) !void {
    s.gpa = e.gpa;
    s.names = .init(e.gpa);
    try st.Shell.prepare(&e.tree, st.shell_styles);
    try st.ProjectRow.prepare(&e.tree, st.project_styles);
    try st.WorkspaceTab.prepare(&e.tree, st.tab_styles);
    try st.SecretRow.prepare(&e.tree, st.secret_styles);
    var bindings: [st.Shell.binding_names.len]ui.Binding = undefined;
    inline for (st.Shell.binding_names, 0..) |name, i| {
        bindings[i] = .{ .name = name, .value = if (comptime std.mem.eql(u8, name, "vault_path")) st.data_path else "" };
    }
    _ = try st.Shell.mount(&e.tree, st.shell_base, st.shell_styles, &bindings);
    e.tree.root = e.tree.get(st.shell_base);
    try render(e);
}

pub fn event(e: *ui.Engine, node: i64, kind: []const u8, data: []const u8) bool {
    return handle(e, node, kind, data) catch |err| {
        std.log.err("locket: {s}", .{@errorName(err)});
        if (err == error.NotFound) render(e) catch {};
        status(e, view.describe(err));
        return true;
    };
}

pub fn timer(e: *ui.Engine, timer_id: u32) !void {
    if (timer_id != st.focus_timer or s.pending_focus == 0) return;
    const node = s.pending_focus;
    s.pending_focus = 0;
    w.focus(e, node);
    s.active_field = node;
}

// ---------------------------------------------------------------- events

const Action = *const fn (*ui.Engine) anyerror!bool;

/// The shell's buttons and what each does.
const clicks = .{
    .{ "reload", reload },
    .{ "add-project", createProject },
    .{ "edit-project", openProjectForm },
    .{ "project-cancel", closeProjectForm },
    .{ "project-save", saveProject },
    .{ "delete-project", askDeleteProject },
    .{ "add-workspace", createWorkspace },
    .{ "rename-workspace", openWorkspaceForm },
    .{ "ws-cancel", closeWorkspaceForm },
    .{ "ws-save", saveWorkspace },
    .{ "delete-workspace", askDeleteWorkspace },
    .{ "new-secret", openNewEditor },
    .{ "secret-cancel", closeEditor },
    .{ "secret-save", saveSecret },
};

/// What Enter does in each field.
const enters = .{
    .{ "new-project", createProject },
    .{ "new-workspace", createWorkspace },
    .{ "ws-name", saveWorkspace },
    .{ "secret-name", saveSecret },
    .{ "secret-value", saveSecret },
    .{ "project-name", saveProject },
    .{ "project-desc", saveProject },
};

fn handle(e: *ui.Engine, node: i64, kind: []const u8, data: []const u8) !bool {
    const eq = std.mem.eql;
    if (eq(u8, kind, "focus") or eq(u8, kind, "input")) {
        if (st.isField(node)) s.active_field = node;
        return false;
    }
    if (eq(u8, kind, "blur")) {
        if (node == s.active_field) s.active_field = 0;
        return false;
    }
    if (eq(u8, kind, "key")) return key(e, if (node != 0) node else s.active_field, data);
    if (!eq(u8, kind, "click")) return false;

    if (s.pending != .none) {
        if (node == sid("confirm-ok")) return confirmDelete(e);
        if (node == sid("confirm-cancel") or node == sid("confirm")) return closeConfirm(e);
        return true; // the dialog is modal
    }
    inline for (clicks) |c| if (node == sid(c[0])) return @as(Action, c[1])(e);
    return rowClick(e, node);
}

/// A click in one of the stamped lists: a project, a workspace tab, or a
/// variable row's button.
fn rowClick(e: *ui.Engine, node: i64) !bool {
    if (input.rowAt(node, st.project_rows, st.row_stride, s.projects.len)) |hit| {
        try selectProject(e, s.projects[hit.index]);
        return true;
    }
    if (input.rowAt(node, st.tab_rows, st.row_stride, s.workspaces.len)) |hit| {
        try selectWorkspace(e, s.workspaces[hit.index]);
        return true;
    }
    const hit = input.rowAt(node, st.secret_rows, st.row_stride, s.secrets.len) orelse return false;
    const name = s.secrets[hit.index];
    if (hit.local == st.SecretRow.id("reveal", 0)) {
        try s.set(&s.revealed, if (st.isSelected(s.revealed, name)) null else name);
        try render(e);
        return true;
    }
    if (hit.local == st.SecretRow.id("edit", 0)) return openEditor(e, name);
    if (hit.local == st.SecretRow.id("delete", 0)) return askDelete(e, .secret, name);
    return false;
}

fn key(e: *ui.Engine, node: i64, data: []const u8) !bool {
    const name = input.keyName(data) orelse return false;
    if (std.mem.eql(u8, name, "Escape")) return escape(e);
    if (!std.mem.eql(u8, name, "Enter")) return false;
    if (s.pending != .none) return false; // the focused button decides
    inline for (enters) |f| if (node == sid(f[0])) return @as(Action, f[1])(e);
    return false;
}

fn escape(e: *ui.Engine) !bool {
    if (s.pending != .none) return closeConfirm(e);
    if (s.editor != .closed) return closeEditor(e);
    if (s.project_form) return closeProjectForm(e);
    if (s.workspace_form) return closeWorkspaceForm(e);
    return false;
}

// --------------------------------------------------------------- actions

/// One edit: opens the vault for writing (the exclusive lock), calls
/// `change(&vault, args...)`, saves, and closes it (releasing the lock)
/// before returning, so the caller can render.
fn commit(e: *ui.Engine, comptime change: anytype, args: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    var v = try vault.open(st.io, arena.allocator(), st.data_path, .write);
    defer v.close();
    try @call(.auto, change, .{&v} ++ args);
    try v.save();
}

/// A read of the vault for one look-up; `close` it when done.
fn snapshot(a: std.mem.Allocator) !vault.Vault {
    return vault.open(st.io, a, st.data_path, .read);
}

fn reload(e: *ui.Engine) !bool {
    try render(e);
    status(e, "Reloaded from disk.");
    return true;
}

fn createProject(e: *ui.Engine) !bool {
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const name = try w.field(e, arena.allocator(), sid("new-project"));
    try commit(e, vault.Vault.createProject, .{ name, "" });
    try w.setField(e, sid("new-project"), "");
    try selectProject(e, name);
    try statusFmt(e, "Created {s}. Add variables to its default workspace, or a workspace above.", .{name});
    return openEditor(e, null);
}

fn openProjectForm(e: *ui.Engine) !bool {
    const name = s.project orelse return true;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    var v = try snapshot(arena.allocator());
    defer v.close();
    const p = v.project(name) orelse return error.NotFound;
    s.closeForms();
    s.project_form = true;
    try render(e);
    try w.setField(e, sid("project-name"), s.project.?);
    try w.setField(e, sid("project-desc"), p.description);
    focusField(e, sid("project-name"));
    return true;
}

fn closeProjectForm(e: *ui.Engine) !bool {
    s.project_form = false;
    try render(e);
    return true;
}

fn saveProject(e: *ui.Engine) !bool {
    if (!s.project_form) return true;
    const old = s.project orelse return true;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const name = try w.field(e, arena.allocator(), sid("project-name"));
    const desc = try w.field(e, arena.allocator(), sid("project-desc"));
    try commit(e, vault.Vault.updateProject, .{ old, name, desc });
    s.project_form = false;
    try s.set(&s.project, name);
    try render(e);
    try statusFmt(e, "Saved project {s}.", .{name});
    return true;
}

fn createWorkspace(e: *ui.Engine) !bool {
    const project = s.project orelse return true;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const name = try w.field(e, arena.allocator(), sid("new-workspace"));
    try commit(e, vault.Vault.createWorkspace, .{ project, name });
    try w.setField(e, sid("new-workspace"), "");
    try selectWorkspace(e, name);
    try statusFmt(e, "Created {s}/{s}.", .{ s.project.?, name });
    return openEditor(e, null);
}

fn openWorkspaceForm(e: *ui.Engine) !bool {
    const name = s.workspace orelse return true;
    if (vault.isDefault(name)) return error.DefaultWorkspace;
    s.closeForms();
    s.workspace_form = true;
    try render(e);
    try w.setField(e, sid("ws-name"), s.workspace.?);
    focusField(e, sid("ws-name"));
    return true;
}

fn closeWorkspaceForm(e: *ui.Engine) !bool {
    s.workspace_form = false;
    try render(e);
    return true;
}

fn saveWorkspace(e: *ui.Engine) !bool {
    if (!s.workspace_form) return true;
    const project = s.project orelse return true;
    const old = s.workspace orelse return true;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const name = try w.field(e, arena.allocator(), sid("ws-name"));
    try commit(e, vault.Vault.renameWorkspace, .{ project, old, name });
    s.workspace_form = false;
    try s.set(&s.workspace, name);
    try render(e);
    try statusFmt(e, "Renamed to {s}/{s}.", .{ s.project.?, name });
    return true;
}

fn openNewEditor(e: *ui.Engine) !bool {
    return openEditor(e, null);
}

/// Opens the variable editor: empty for a new one, or filled with
/// `secret_name`'s name and value. `secret_name` may be a slice of the
/// render's name list, so only the owned copy (`s.editing`) is used once
/// render has run.
fn openEditor(e: *ui.Engine, secret_name: ?[]const u8) !bool {
    if (s.project == null or s.workspace == null) return true;
    s.closeForms();
    s.editor = if (secret_name == null) .new else .edit;
    try s.set(&s.editing, secret_name);
    try render(e);
    const name = s.editing orelse {
        try w.setField(e, sid("secret-name"), "");
        try w.setField(e, sid("secret-value"), "");
        focusField(e, sid("secret-name"));
        return true;
    };
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    var v = try snapshot(arena.allocator());
    defer v.close();
    const value = v.secret(s.project.?, s.workspace.?, name) orelse return error.NotFound;
    try w.setField(e, sid("secret-name"), name);
    try w.setField(e, sid("secret-value"), value);
    focusField(e, sid("secret-value"));
    return true;
}

fn closeEditor(e: *ui.Engine) !bool {
    s.editor = .closed;
    try s.set(&s.editing, null);
    // Don't leave a value sitting in a hidden field.
    try w.setField(e, sid("secret-value"), "");
    try render(e);
    return true;
}

// @atlas allow: the guards and arena setup match saveWorkspace; no shared logic
fn saveSecret(e: *ui.Engine) !bool {
    if (s.editor == .closed) return true;
    const project = s.project orelse return true;
    const workspace = s.workspace orelse return true;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const name = try w.field(e, arena.allocator(), sid("secret-name"));
    const value = try arena.allocator().dupe(u8, w.fieldValue(e, sid("secret-value")));
    defer std.crypto.secureZero(u8, value);
    try vault.checkVarName(name);
    if (value.len == 0) return error.EmptyValue;
    try commit(e, vault.Vault.updateSecret, .{ project, workspace, s.editing orelse "", name, value });
    const verb = if (s.editor == .new) "Added" else "Updated";
    if (s.editing) |old| if (st.isSelected(s.revealed, old)) try s.set(&s.revealed, null);
    _ = try closeEditor(e);
    try statusFmt(e, "{s} {f}.", .{ verb, vault.Ref{ .project = s.project.?, .workspace = s.workspace.?, .name = name } });
    return true;
}

fn askDeleteProject(e: *ui.Engine) !bool {
    return askDelete(e, .project, s.project orelse return true);
}

fn askDeleteWorkspace(e: *ui.Engine) !bool {
    return askDelete(e, .workspace, s.workspace orelse return true);
}

fn askDelete(e: *ui.Engine, what: st.Pending, name: []const u8) !bool {
    std.debug.assert(what != .none);
    if (what == .workspace and vault.isDefault(name)) return error.DefaultWorkspace;
    s.pending = what;
    try s.set(&s.pending_name, name);
    var title: [256]u8 = undefined;
    var body: [512]u8 = undefined;
    const n = s.secret_count;
    const pn = s.pending_name.?;
    const kind = switch (what) {
        .project => "project ",
        .workspace => "workspace ",
        else => "",
    };
    try w.text(e, sid("confirm-title"), try std.fmt.bufPrint(&title, "Delete {s}{s}?", .{ kind, pn }));
    try w.text(e, sid("confirm-text"), switch (what) {
        .project => try std.fmt.bufPrint(&body, "This removes {s}, all of its workspaces and their variables from the vault. It can't be undone.", .{pn}),
        .workspace => try std.fmt.bufPrint(&body, "This removes the workspace and its {d} variable{s} from the vault. It can't be undone.", .{ n, if (n == 1) "" else "s" }),
        .secret => "The value is removed from the sealed vault, and agents running this workspace no longer receive it. It can't be undone.",
        .none => unreachable,
    });
    try w.display(e, sid("confirm"), true);
    e.tree.layout();
    w.focus(e, sid("confirm-cancel"));
    return true;
}

fn closeConfirm(e: *ui.Engine) !bool {
    s.pending = .none;
    try s.set(&s.pending_name, null);
    try w.display(e, sid("confirm"), false);
    e.tree.layout();
    return true;
}

fn confirmDelete(e: *ui.Engine) !bool {
    const what = s.pending;
    var arena = std.heap.ArenaAllocator.init(e.gpa);
    defer arena.deinit();
    const name = try arena.allocator().dupe(u8, s.pending_name orelse return closeConfirm(e));
    _ = try closeConfirm(e);
    const project = s.project orelse return true;
    const workspace = s.workspace orelse return true;
    try commit(e, remove, .{ what, project, workspace, name });
    var buf: [512]u8 = undefined;
    const message = switch (what) {
        .project => try std.fmt.bufPrint(&buf, "Deleted project {s}.", .{name}),
        .workspace => try std.fmt.bufPrint(&buf, "Deleted workspace {s}/{s}.", .{ project, name }),
        .secret => try std.fmt.bufPrint(&buf, "Deleted {f}.", .{vault.Ref{ .project = project, .workspace = workspace, .name = name }}),
        .none => unreachable,
    };
    switch (what) {
        .project => try s.set(&s.project, null),
        .workspace => try s.set(&s.workspace, vault.default_workspace),
        .secret => if (st.isSelected(s.editing, name)) {
            s.editor = .closed;
        },
        .none => unreachable,
    }
    if (what != .secret) s.closeForms();
    try render(e);
    status(e, message);
    return true;
}

/// The removal a confirmed dialog asks for.
fn remove(v: *vault.Vault, what: st.Pending, project: []const u8, workspace: []const u8, name: []const u8) !void {
    const gone = switch (what) {
        .project => v.removeProject(name),
        .workspace => v.removeWorkspace(project, name),
        .secret => v.removeSecret(project, workspace, name),
        .none => unreachable,
    };
    if (!gone) return error.NotFound;
}

fn selectProject(e: *ui.Engine, name: []const u8) !void {
    if (st.isSelected(s.project, name)) return;
    try s.set(&s.project, name);
    try s.set(&s.workspace, vault.default_workspace);
    try select(e);
}

fn selectWorkspace(e: *ui.Engine, name: []const u8) !void {
    if (st.isSelected(s.workspace, name)) return;
    try s.set(&s.workspace, name);
    try select(e);
}

/// After a selection change: forms closed, nothing revealed, no value left
/// in the editor's field.
fn select(e: *ui.Engine) !void {
    try s.set(&s.revealed, null);
    s.closeForms();
    try w.setField(e, sid("secret-value"), "");
    try render(e);
}

// --------------------------------------------------------------- helpers

/// Focuses a field on the next tick: the click that asked for it may be
/// hiding the focused button, and GTK moves focus off it afterwards.
fn focusField(e: *ui.Engine, node: i64) void {
    e.tree.layout();
    s.pending_focus = node;
    e.backend.add_timer(e.backend.ctx, e, st.focus_timer, 40);
}

fn status(e: *ui.Engine, message: []const u8) void {
    w.text(e, sid("status"), message) catch {};
    e.tree.layout();
}

fn statusFmt(e: *ui.Engine, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    status(e, std.fmt.bufPrint(&buf, fmt, args) catch "Done.");
}
