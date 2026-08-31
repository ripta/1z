//! Debug-only registry of live closure-owned body addresses.
//!
//! The body-keyed resolution maps (`Context.quotation_scope_info` and the process-shared
//! `carryable_scope_gate`) admit only process-lifetime keys. A body a closure owns is freed when
//! the closure is released, so an entry under its address would outlive its own key, and a later
//! unrelated allocation at the same address would inherit the dead closure's resolution data. The
//! writers refuse such a body by asking the threaded carrier, but that re-checks what the caller
//! decided. This registry answers independently: it tracks every live closure-owned body address,
//! and the one shared insert helper asserts the key is not among them.
//!
//! Registration mirrors the body's own alloc and free: an entry is written where ownership is
//! minted, in `Closure.create` when the template carries `owns_body`, and removed in
//! `destroyClosure` before the body is freed. A derivative aliasing a base's body needs no entry
//! of its own, since the base already registered that address. An empty body is excluded on both
//! ends: every zero-length allocation shares one sentinel address, so the pointer cannot identify
//! an owner, and `ownsBody`, the stamp store, and the map path all exclude it on the same terms.
//!
//! The state is a process global rather than context-owned because `destroyClosure` holds no
//! context. That is a deliberate Debug-only exception to the no-global-state rule; the registry
//! holds no semantic state and compiles out entirely outside Debug builds. The mutex is a leaf:
//! nothing that locks is called while it is held.

const std = @import("std");
const builtin = @import("builtin");

const enabled = builtin.mode == .Debug;

var mu: std.Thread.Mutex = .{};
var live: std.AutoHashMapUnmanaged(usize, void) = .{};

/// The registry's own bookkeeping rides the page allocator so it stays outside the interpreter's
/// tracked memory limit; a Debug diagnostic must not change what a capped run can allocate.
const gpa = std.heap.page_allocator;

/// Record that a live closure owns the body at `key`. Two live closures owning one address would
/// be a double free in waiting, so a duplicate registration asserts.
pub fn register(key: usize, len: usize) void {
    if (comptime !enabled) return;
    if (len == 0) return;

    mu.lock();
    defer mu.unlock();
    const gop = live.getOrPut(gpa, key) catch |err|
        std.debug.panic("closure body registry allocation failed: {s}", .{@errorName(err)});
    std.debug.assert(!gop.found_existing);
}

/// Forget the body at `key` on the owning closure's destroy path, before the body is freed, so
/// the registry never holds a freed address. Deregistering an address that was never registered
/// asserts, since it means ownership was minted somewhere other than the registration site.
pub fn deregister(key: usize, len: usize) void {
    if (comptime !enabled) return;
    if (len == 0) return;

    mu.lock();
    defer mu.unlock();
    std.debug.assert(live.remove(key));
}

/// Whether a live closure owns the body at `key`. False outside Debug builds.
pub fn isLive(key: usize) bool {
    if (comptime !enabled) return false;

    mu.lock();
    defer mu.unlock();
    return live.contains(key);
}

/// Assert that no live closure owns the body at `key`.
///
/// The invariant: a body a closure owns never enters `quotation_scope_info` or
/// `carryable_scope_gate`; its resolution data rides the `Closure` value instead. The
/// reconciliation sites are `register` in `Closure.create` and `deregister` in `destroyClosure`.
/// A firing panic means a map writer reached the shared insert helper without its carrier, or
/// with a carrier that does not name the body being keyed.
pub fn assertNotLive(key: usize) void {
    if (comptime !enabled) return;

    if (isLive(key))
        std.debug.panic("body-keyed map write for live closure-owned body 0x{x}", .{key});
}

const testing = std.testing;

test "closure_body_registry: a registered address is live until deregistered" {
    if (comptime !enabled) return error.SkipZigTest;

    var body: [2]u8 = undefined;
    const key = @intFromPtr(&body);

    register(key, body.len);
    defer deregister(key, body.len);

    try testing.expect(isLive(key));
    assertNotLive(key + 1);
}

test "closure_body_registry: an empty body is excluded on both ends" {
    if (comptime !enabled) return error.SkipZigTest;

    var body: [1]u8 = undefined;
    const key = @intFromPtr(&body);

    register(key, 0);
    try testing.expect(!isLive(key));
    deregister(key, 0);
}

test "closure_body_registry: an address can be registered again after deregistration" {
    if (comptime !enabled) return error.SkipZigTest;

    var body: [2]u8 = undefined;
    const key = @intFromPtr(&body);

    register(key, body.len);
    deregister(key, body.len);
    try testing.expect(!isLive(key));

    register(key, body.len);
    defer deregister(key, body.len);
    try testing.expect(isLive(key));
}
