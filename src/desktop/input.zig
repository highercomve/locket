//! Decoding the window's input: key events and clicks inside stamped row
//! lists. Pure functions, tested here.
//! @atlas layer: front

const std = @import("std");

/// A key event's key: its data is `["Enter",mods,repeat]`.
pub fn keyName(data: []const u8) ?[]const u8 {
    if (data.len < 4 or data[0] != '[' or data[1] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, data, 2, '"') orelse return null;
    return data[2..end];
}

pub const Hit = struct { index: usize, local: i64 };

/// The row (and the node within it) that `node` belongs to, in a list of
/// `len` rows mounted at `base + i * stride`.
pub fn rowAt(node: i64, base: i64, stride: i64, len: usize) ?Hit {
    std.debug.assert(stride > 0);
    if (node < base or node >= base + @as(i64, @intCast(len)) * stride) return null;
    const offset = node - base;
    return .{
        .index = @intCast(@divTrunc(offset, stride)),
        .local = @mod(offset, stride),
    };
}

test keyName {
    try std.testing.expectEqualStrings("Enter", keyName("[\"Enter\",0,false]").?);
    try std.testing.expectEqualStrings("Escape", keyName("[\"Escape\",2,true]").?);
    try std.testing.expect(keyName("{}") == null);
    try std.testing.expect(keyName("[\"x") == null);
}

test rowAt {
    try std.testing.expect(rowAt(99, 100, 16, 3) == null);
    try std.testing.expect(rowAt(148, 100, 16, 3) == null);
    const hit = rowAt(100 + 16 + 5, 100, 16, 3).?;
    try std.testing.expectEqual(@as(usize, 1), hit.index);
    try std.testing.expectEqual(@as(i64, 5), hit.local);
}
