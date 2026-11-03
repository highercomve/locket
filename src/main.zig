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

pub const Commands = struct {};

pub fn main(init: std.process.Init) !u8 {
    st.io = init.io;
    st.data_path = try vault.dataDir(init.environ_map, init.arena.allocator());
    oriel.ui.configure(.{ .boot = desktop.boot, .event = desktop.event, .timer = desktop.timer });
    return oriel.main(init, .{ .commands = Commands }, .{
        .app = app.build,
        .window = .{ .title = "Locket", .width = 1040, .height = 680 },
    });
}
