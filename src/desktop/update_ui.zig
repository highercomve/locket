//! The header's version and update buttons. The version button checks for
//! a newer release (also once at start, quietly); the update button,
//! shown only when there is one, installs it and then restarts into it.
//! The work runs in updates.zig's commands, off the UI thread; their
//! answers come back through `resolved`.
//! @atlas layer: front

const std = @import("std");
const oriel = @import("oriel");
const build_info = @import("build_info");
const st = @import("state.zig");
const w = @import("widgets.zig");
const status = @import("render.zig").status;

const ui = oriel.ui;
const sid = st.sid;

/// ui.invoke request ids (their own namespace, apart from timers).
const Request = enum(u32) { check = 1, install = 2, restart = 3 };

const Phase = enum { idle, checking, available, installing, installed };

var phase: Phase = .idle;
/// The check was asked for (a click): say so when there's nothing new.
var manual = false;
var can_install = true;
var found_buf: [64]u8 = undefined;
var found: []const u8 = "";

/// At boot: the version on its button, and a quiet check.
pub fn start(e: *ui.Engine) !void {
    var buf: [48]u8 = undefined;
    try w.label(e, sid("version"), try std.fmt.bufPrint(&buf, "v{s}", .{build_info.version}));
    try check(e, false);
}

pub fn clickVersion(e: *ui.Engine) !bool {
    if (phase == .checking or phase == .installing) return true;
    try check(e, true);
    return true;
}

pub fn clickUpdate(e: *ui.Engine) !bool {
    switch (phase) {
        .available => {
            if (!can_install) {
                status(e, "This copy is installed by a package manager: update Locket there.");
                return true;
            }
            phase = .installing;
            try button(e, "Downloading…");
            status(e, "Downloading and verifying the update…");
            try ui.invoke(e, @intFromEnum(Request.install), "update_install", .{});
        },
        .installed => {
            status(e, "Restarting…");
            try ui.invoke(e, @intFromEnum(Request.restart), "update_restart", .{});
        },
        else => {},
    }
    return true;
}

fn check(e: *ui.Engine, asked: bool) !void {
    manual = asked;
    phase = .checking;
    if (asked) status(e, "Checking for updates…");
    try ui.invoke(e, @intFromEnum(Request.check), "update_check", .{});
}

/// Oriel's answer to an update command.
pub fn resolved(e: *ui.Engine, req_id: u32, ok: bool, json: []const u8) !void {
    const req = std.enums.fromInt(Request, req_id) orelse return;
    if (!ok) return failed(e, req, json);
    switch (req) {
        .check => {
            const Result = struct { available: bool, version: ?[]const u8 = null, can_install: bool };
            const r = try std.json.parseFromSlice(Result, e.gpa, json, .{ .ignore_unknown_fields = true });
            defer r.deinit();
            can_install = r.value.can_install;
            const v = r.value.version orelse "";
            if (!r.value.available or v.len == 0 or v.len > found_buf.len) {
                phase = .idle;
                if (manual) {
                    var buf: [96]u8 = undefined;
                    status(e, std.fmt.bufPrint(&buf, "Locket {s} is the latest release.", .{build_info.version}) catch "Up to date.");
                }
                return;
            }
            @memcpy(found_buf[0..v.len], v);
            found = found_buf[0..v.len];
            phase = .available;
            var label_buf: [96]u8 = undefined;
            try button(e, try std.fmt.bufPrint(&label_buf, "{s} {s}", .{ if (can_install) "Update to" else "Available:", found }));
            var buf: [128]u8 = undefined;
            status(e, try std.fmt.bufPrint(&buf, "Locket {s} is available.", .{found}));
        },
        .install => {
            phase = .installed;
            try button(e, "Restart to update");
            var buf: [128]u8 = undefined;
            status(e, try std.fmt.bufPrint(&buf, "Locket {s} is installed: restart to use it.", .{found}));
        },
        .restart => {}, // the new version replaces this process
    }
}

fn failed(e: *ui.Engine, req: Request, json: []const u8) !void {
    // The command's message: a JSON string, or plain text.
    const parsed = std.json.parseFromSlice([]const u8, e.gpa, json, .{}) catch null;
    defer if (parsed) |p| p.deinit();
    const message = if (parsed) |p| p.value else if (json.len > 0) json else "The update command failed.";
    switch (req) {
        .check => {
            phase = .idle;
            if (manual) status(e, message);
            std.log.info("update check: {s}", .{message});
        },
        .install => {
            phase = .available;
            var buf: [96]u8 = undefined;
            try button(e, try std.fmt.bufPrint(&buf, "Update to {s}", .{found}));
            status(e, message);
        },
        .restart => status(e, message),
    }
}

/// Shows the update button with `text`.
fn button(e: *ui.Engine, text: []const u8) !void {
    try w.label(e, sid("update"), text);
    try w.display(e, sid("update"), true);
    e.tree.layout();
}
