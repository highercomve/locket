//! The desktop window's state and its node ids: the views, where each
//! is mounted, and what the user has selected or has open.
//! @atlas layer: front

const std = @import("std");
const oriel = @import("oriel");

const ui = oriel.ui;

pub const Shell = ui.View(@embedFile("../views/locket.oriel"));
pub const ProjectRow = ui.View(@embedFile("../views/project_row.oriel"));
pub const WorkspaceTab = ui.View(@embedFile("../views/workspace_tab.oriel"));
pub const SecretRow = ui.View(@embedFile("../views/secret_row.oriel"));

pub const shell_base: i64 = 100;
pub const shell_styles: i64 = 10_000;
pub const project_styles: i64 = 11_000;
pub const secret_styles: i64 = 12_000;
pub const tab_styles: i64 = 13_000;
pub const project_rows: i64 = 20_000;
pub const tab_rows: i64 = 40_000;
pub const secret_rows: i64 = 60_000;
pub const row_stride: i64 = 16;
pub const max_rows: usize = 1000;

comptime {
    std.debug.assert(ProjectRow.node_count <= row_stride);
    std.debug.assert(WorkspaceTab.node_count <= row_stride);
    std.debug.assert(SecretRow.node_count <= row_stride);
    std.debug.assert(shell_base + Shell.node_count < project_rows);
    std.debug.assert(project_rows + max_rows * row_stride <= tab_rows);
    std.debug.assert(tab_rows + max_rows * row_stride <= secret_rows);
}

/// A node of the shell view.
pub fn sid(comptime name: []const u8) i64 {
    return Shell.id(name, shell_base);
}

/// The shell's text fields (Enter goes to the one that last had focus).
pub const fields = [_][]const u8{ "new-project", "project-name", "project-desc", "new-workspace", "ws-name", "secret-name", "secret-value" };

pub fn isField(node: i64) bool {
    inline for (fields) |name| {
        if (node == sid(name)) return true;
    }
    return false;
}

pub const Editor = enum { closed, new, edit };
pub const Pending = enum { none, project, workspace, secret };

/// Strings are owned in `gpa`, except the `projects`, `workspaces` and
/// `secrets` lists, which live in `names` and are replaced by every
/// render: never hold one of those slices across a render.
pub const State = struct {
    gpa: std.mem.Allocator = undefined,
    names: std.heap.ArenaAllocator = undefined,
    projects: []const []const u8 = &.{},
    workspaces: []const []const u8 = &.{},
    secrets: []const []const u8 = &.{},
    secret_count: usize = 0, // the selected workspace's

    project: ?[]u8 = null,
    workspace: ?[]u8 = null,
    revealed: ?[]u8 = null,
    editor: Editor = .closed,
    editing: ?[]u8 = null, // the secret being edited
    project_form: bool = false,
    workspace_form: bool = false,
    pending: Pending = .none,
    pending_name: ?[]u8 = null,

    /// The field Enter belongs to (native fields send keys without a node).
    active_field: i64 = 0,
    /// A field to focus on the next tick (`focus_timer`).
    pending_focus: i64 = 0,

    pub fn set(self: *State, slot: *?[]u8, value: ?[]const u8) !void {
        const dup = if (value) |v| try self.gpa.dupe(u8, v) else null;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = dup;
    }

    /// Closes the forms and the editor (a selection change).
    pub fn closeForms(self: *State) void {
        self.editor = .closed;
        self.project_form = false;
        self.workspace_form = false;
    }
};

pub const focus_timer: u32 = 1;

pub var io: std.Io = undefined;
pub var data_path: []const u8 = "";
pub var s: State = .{};

pub fn isSelected(selected: ?[]const u8, name: []const u8) bool {
    return selected != null and std.mem.eql(u8, selected.?, name);
}
