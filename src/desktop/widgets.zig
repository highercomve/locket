//! Small helpers over Oriel's retained tree: text, a control's label,
//! display, and native text fields. Nothing Locket-specific.
//! @atlas layer: front

const std = @import("std");
const oriel = @import("oriel");

const ui = oriel.ui;

pub fn text(e: *ui.Engine, node: i64, value: []const u8) !void {
    if (!try e.tree.updateText(node, value)) return error.InvalidTextNode;
}

/// A <control>'s label.
pub fn label(e: *ui.Engine, node: i64, value: []const u8) !void {
    var props = e.tree.get(node).?.props;
    const runs = props.runs orelse return;
    if (runs.len == 1 and std.mem.eql(u8, runs[0].t, value)) return;
    var run = runs[0];
    run.t = value;
    props.runs = &.{run};
    props.al = value;
    try e.tree.updateUiProps(node, props);
}

/// Shows or hides a node (display: none).
pub fn display(e: *ui.Engine, node: i64, on: bool) !void {
    var props = e.tree.get(node).?.props;
    if (props.none == !on) return;
    props.none = !on;
    try e.tree.updateUiProps(node, props);
    // A display flip changes layout, which updateUiProps alone doesn't flag.
    e.tree.dirty = true;
    e.tree.paint_dirty = true;
}

/// A field's current text, owned by the tree: copy it (`field`) before
/// anything that may change the field.
pub fn fieldValue(e: *ui.Engine, node: i64) []const u8 {
    const n = e.tree.get(node) orelse return "";
    return n.ui_value orelse n.props.val orelse "";
}

/// A field's trimmed text, copied into `a`.
pub fn field(e: *ui.Engine, a: std.mem.Allocator, node: i64) ![]const u8 {
    return a.dupe(u8, std.mem.trim(u8, fieldValue(e, node), " \t\r\n"));
}

/// Sets a field's text. The text it replaces is zeroed first: fields may
/// hold secret values. (The platform widget's own buffers are beyond
/// reach.)
pub fn setField(e: *ui.Engine, node: i64, value: []const u8) !void {
    const n = e.tree.get(node) orelse return error.UnknownNode;
    if (n.ui_value) |old| {
        // acceptUiValue frees it next; the value isn't aliased elsewhere.
        if (old.ptr != value.ptr) std.crypto.secureZero(u8, old);
    }
    try e.tree.acceptUiValue(node, value);
    var props = e.tree.get(node).?.props;
    props.val = value;
    try e.tree.updateUiProps(node, props);
}

pub fn focus(e: *ui.Engine, node: i64) void {
    if (e.tree.get(node)) |n| e.backend.focus(e.backend.ctx, n);
}

/// A failed command's message as Oriel delivers it to `resolved`: plain
/// text, or a JSON string. It lives in `buf` or `json`.
pub fn failureText(json: []const u8, buf: []u8, fallback: []const u8) []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const parsed = std.json.parseFromSliceLeaky([]const u8, fba.allocator(), json, .{}) catch {
        return if (json.len > 0) json else fallback;
    };
    return parsed;
}

test failureText {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("plain", failureText("plain", &buf, "x"));
    try std.testing.expectEqualStrings("quoted", failureText("\"quoted\"", &buf, "x"));
    try std.testing.expectEqualStrings("x", failureText("", &buf, "x"));
}

/// A choice button's look: amber when chosen, quiet otherwise.
pub fn choose(e: *ui.Engine, node: i64, on: bool) !void {
    var props = e.tree.get(node).?.props;
    const ink = if (on) oriel.canvas.rgb(0xf6b042) else oriel.canvas.rgb(0xa99f8f);
    props.bg = .{ .color = if (on) oriel.canvas.rgba(0xf6b042, 0.12) else oriel.canvas.rgba(0xf2e8d8, 0.03) };
    const edge = if (on) oriel.canvas.rgba(0xf6b042, 0.55) else oriel.canvas.rgba(0xf2e8d8, 0.15);
    props.bc = .{ edge, edge, edge, edge };
    props.col = ink;
    if (props.runs) |runs| if (runs.len == 1) {
        var run = runs[0];
        run.c = ink;
        props.runs = &.{run};
    };
    try e.tree.updateUiProps(node, props);
}
