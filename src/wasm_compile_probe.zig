const std = @import("std");

// Build-only root for the `wasm-clock-check` step (build.zig), which cross-compiles this file as
// a static library for wasm32-freestanding to prove the wasm clock host import and the no-op
// multiplexer actually compile for that target, not just that their `is_freestanding`-keyed
// branches look correct by inspection.
//
// Scoped deliberately narrow: `Scheduler`/`WorkerPool` are not exercised here, because
// constructing either pulls in `Task` -> `Context` -> the still-unguarded `ffi/ir.zig`
// `@cImport`, `value.zig`'s 64-bit-only `@sizeOf(Value) == 40` assertion, and several
// `std.posix` declarations Zig itself does not fully resolve for wasm32-freestanding. Porting
// that whole surface is the interpreter no-libc porting work, not this file's job.
//
// `zig build test` pulls in a posix-heavy default test runner that does not compile for
// wasm32-freestanding either, which is why this is a plain `export fn` forcing real analysis
// through a library build (mirroring how `capi_wasm.zig` itself is built) rather than a
// `b.addTest` binary.

const scheduler = @import("scheduler.zig");
const multiplexer = @import("multiplexer.zig");

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
