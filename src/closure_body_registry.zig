//! Debug-only registry of live closure-owned body addresses.
//!
//! The body-keyed resolution maps (`Context.quotation_scope_info` and the layered
//! `carryable_scope_gate`) admit only keys that outlive the layer or map they enter. A body a
//! closure owns is freed when the closure is released, so an entry under its address would
//! outlive its own key, and a later unrelated allocation at the same address would inherit the
//! dead closure's resolution data. The writers refuse such a body by asking the threaded carrier,
//! but that re-checks what the caller decided. This registry answers independently: it tracks every live closure-owned body address,
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

/// How many executions of each closure-owned body are in flight, by body address.
var running: std.AutoHashMapUnmanaged(usize, u32) = .{};

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
///
/// This is the choke point of the running-body invariant: a closure released to zero must not own
/// a body that is executing. Every body entered through `enterRunning` is counted until its
/// `exitRunning`, and a count above zero here means the closure was released while its body ran,
/// so the interpreter would read freed instructions on its next step.
pub fn deregister(key: usize, len: usize) void {
    if (comptime !enabled) return;
    if (len == 0) return;

    mu.lock();
    defer mu.unlock();
    if (running.get(key)) |depth|
        std.debug.panic("closure released to zero while its body is running 0x{x} (depth {d})", .{ key, depth });
    std.debug.assert(live.remove(key));
}

/// Record that the body at `key` started executing. Nested and recursive runs of one body count.
pub fn enterRunning(key: usize, len: usize) void {
    if (comptime !enabled) return;
    if (len == 0) return;

    mu.lock();
    defer mu.unlock();
    const gop = running.getOrPut(gpa, key) catch |err|
        std.debug.panic("closure body registry allocation failed: {s}", .{@errorName(err)});
    if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
}

/// Record that a run `enterRunning` counted has ended.
pub fn exitRunning(key: usize, len: usize) void {
    if (comptime !enabled) return;
    if (len == 0) return;

    mu.lock();
    defer mu.unlock();
    const depth = running.getPtr(key) orelse std.debug.panic("exit of a body that was not running 0x{x}", .{key});
    if (depth.* == 1) _ = running.remove(key) else depth.* -= 1;
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
