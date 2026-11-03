//! `locket`: the command line (src/cli.zig), with no GUI libraries
//! linked. The desktop window is `locket-app` (src/main.zig).
//! @atlas layer: app

const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    return cli.main(init, if (args.len > 0) args[1..] else args);
}
