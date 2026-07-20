const std = @import("std");

// Build-only root for the `wasm-clock-check` step (build.zig), which cross-compiles this file as
// a static library for wasm32-freestanding to prove the interpreter no-libc porting work
// actually compiles for that target, not just that its `is_freestanding`-keyed branches look
// correct by inspection.
//
// `onez_wasm_context_probe` now exercises the full chain the earlier, narrower version of this
// file deliberately deferred: constructing a real Context (`Context.init`) and loading the real
// prelude (`Context.loadPrelude`), which transitively pulls in the JIT-decoupling comptime
// guards, the ucontext-free StatementProcessor path, the module resolver's filesystem-free
// front end, and every freestanding-gated primitive module.
//
// `zig build test` pulls in a posix-heavy default test runner that does not compile for
// wasm32-freestanding either, which is why this is a plain `export fn` forcing real analysis
// through a library build (mirroring how `capi_wasm.zig` itself is built) rather than a
// `b.addTest` binary.

const scheduler = @import("scheduler.zig");
const multiplexer = @import("multiplexer.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;

pub const panic = std.debug.no_panic;

export fn onez_wasm_compile_probe() void {
    _ = scheduler.monotonicNowNs();

    var mux = multiplexer.Multiplexer.init() catch return;
    var wake = mux.addWakeSource() catch return;
    wake.signal();
    wake.drain();
    wake.deinit();
    _ = mux.poll(1000) catch {};
    mux.deinit();
}

export fn onez_wasm_context_probe() void {
    var ctx = Context.init(std.heap.wasm_allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch {};
}
