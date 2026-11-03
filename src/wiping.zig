//! An allocator that zeroes memory before giving it back: what the sync
//! engine's arenas run on, so the plaintext stores they decrypt and merge
//! (every secret's value, several times over) don't linger in freed heap.
//! @atlas layer: core

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Wiping = struct {
    child: Allocator,

    pub fn allocator(w: *Wiping) Allocator {
        return .{ .ptr = w, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        // Moving memory would hand the old copy back unzeroed: never.
        .remap = Allocator.noRemap,
        .free = free,
    };

    fn self(ptr: *anyopaque) *Wiping {
        return @ptrCast(@alignCast(ptr));
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        return self(ptr).child.rawAlloc(len, alignment, ret_addr);
    }

    /// Grows in place when the child can; never shrinks (the tail given
    /// back couldn't be zeroed first without risking live data when the
    /// child refuses). A refused resize is always allowed.
    fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        if (new_len < memory.len) return false;
        return self(ptr).child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        std.crypto.secureZero(u8, memory);
        self(ptr).child.rawFree(memory, alignment, ret_addr);
    }
};

test Wiping {
    var w: Wiping = .{ .child = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(w.allocator());
    const a = arena.allocator();
    const s = try a.dupe(u8, "a secret");
    try std.testing.expectEqualStrings("a secret", s);
    _ = try a.alloc(u8, 100_000); // grows the arena
    arena.deinit();
}
