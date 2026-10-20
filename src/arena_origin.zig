//! Debug-only test of whether an address lies inside an arena's buffers.
//!
//! The body-keyed store writers use it to check where a key lives. An arena offers no such query,
//! so this walks the buffer list the way the arena's own `deinit` does.

const std = @import("std");

/// Mirrors the standard library's private buffer header. The arena allocates each buffer with this
/// header at its start, and `data` is the whole buffer's length, header included. The test below
/// pins the layout, so a standard library change fails loudly instead of answering wrongly.
const BufNode = struct {
    data: usize,
    node: std.SinglyLinkedList.Node = .{},
};

/// Whether `addr` lies inside one of the buffers `arena` has allocated.
pub fn contains(arena: *const std.heap.ArenaAllocator, addr: usize) bool {
    var it = arena.state.buffer_list.first;
    while (it) |node| : (it = node.next) {
        const buf_node: *BufNode = @fieldParentPtr("node", node);
        const start = @intFromPtr(buf_node);
        if (addr >= start and addr < start + buf_node.data) return true;
    }
    return false;
}

const testing = std.testing;

test "contains: an address from any buffer of the arena is inside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const small = try arena.allocator().alloc(u8, 16);
    const large = try arena.allocator().alloc(u8, 1 << 16);

    try testing.expect(contains(&arena, @intFromPtr(small.ptr)));
    try testing.expect(contains(&arena, @intFromPtr(&small[small.len - 1])));
    try testing.expect(contains(&arena, @intFromPtr(large.ptr)));
    try testing.expect(contains(&arena, @intFromPtr(&large[large.len - 1])));
}

test "contains: an address from anywhere else is outside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try arena.allocator().alloc(u8, 16);

    var on_stack: u8 = 0;
    _ = &on_stack;
    try testing.expect(!contains(&arena, @intFromPtr(&on_stack)));

    const on_heap = try testing.allocator.create(u8);
    defer testing.allocator.destroy(on_heap);
    try testing.expect(!contains(&arena, @intFromPtr(on_heap)));

    var other = std.heap.ArenaAllocator.init(testing.allocator);
    defer other.deinit();
    const elsewhere = try other.allocator().alloc(u8, 16);
    try testing.expect(!contains(&arena, @intFromPtr(elsewhere.ptr)));
}
