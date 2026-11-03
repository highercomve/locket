//! `locket-app`: Locket's desktop window, on the Oriel renderer
//! (compiled .oriel views, no JavaScript, no web view). The window's
//! code is in src/desktop/; the vault it manages is src/vault.zig, the
//! same core the `locket` CLI uses.
//! @atlas layer: app

const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");
const vault = @import("vault.zig");
const st = @import("desktop/state.zig");
const desktop = @import("desktop/app.zig");
const updates = @import("desktop/updates.zig");
const sync_cmds = @import("desktop/sync_cmds.zig");
const connectors = @import("sync/connectors.zig");

/// The commands the window invokes off the UI thread: updates and sync.
pub const Commands = struct {
    pub const async_commands = updates.Commands.async_commands ++ sync_cmds.Commands.async_commands;
    pub const update_check = updates.Commands.update_check;
    pub const update_install = updates.Commands.update_install;
    pub const update_restart = updates.Commands.update_restart;
    pub const sync_info = sync_cmds.Commands.sync_info;
    pub const sync_now = sync_cmds.Commands.sync_now;
    pub const sync_probe = sync_cmds.Commands.sync_probe;
    pub const sync_setup = sync_cmds.Commands.sync_setup;
    pub const sync_join = sync_cmds.Commands.sync_join;
    pub const sync_stop = sync_cmds.Commands.sync_stop;
};

pub fn main(init: std.process.Init) !u8 {
    st.io = init.io;
    st.data_path = try vault.dataDir(init.environ_map, init.arena.allocator());
    updates.init(init.io);
    if (connectors.homeDir(init.environ_map)) |h| st.home = try init.arena.allocator().dupe(u8, h);
    oriel.ui.configure(.{
        .boot = desktop.boot,
        .event = desktop.event,
        .timer = desktop.timer,
        .resolved = desktop.resolved,
    });
    return oriel.main(init, .{ .commands = Commands }, .{
        .app = app.build,
        .window = .{ .title = "Locket", .width = 1040, .height = 680 },
    });
}
