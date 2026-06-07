//! Compatibility shim for the small set of `std.posix` declarations the
//! capi-reachable tree references in type signatures or as plain integers.
//! On hosted builds these forward to `std.posix`; on freestanding builds
//! they fall back to local definitions so the analyzer can finish without
//! pulling in the full posix surface (which has no implementation on
//! `riscv64-freestanding-none`).
//!
//! Call sites that actually invoke syscall-backed functions
//! (`std.posix.mmap`, `std.posix.clock_gettime`, ...) continue to be gated
//! per-file with `if (is_freestanding) ...` so the body never compiles in
//! the freestanding tree.

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

/// File descriptor type. Hosted: `std.posix.fd_t`. Freestanding: `i32`,
/// matching the existing `mux_fd: i32` in the multiplexer's noop branch.
pub const fd_t = if (is_freestanding) i32 else std.posix.fd_t;

/// Process id type. Hosted: `std.posix.pid_t`. Freestanding: `i32`.
pub const pid_t = if (is_freestanding) i32 else std.posix.pid_t;

/// Standard input file descriptor. Hosted: pulled from `std.posix`.
/// Freestanding: `0`, the conventional value. The freestanding build never
/// reads from this -- the print plumbing routes through a UART vtable.
pub const STDIN_FILENO: fd_t = if (is_freestanding) 0 else std.posix.STDIN_FILENO;
pub const STDOUT_FILENO: fd_t = if (is_freestanding) 1 else std.posix.STDOUT_FILENO;
pub const STDERR_FILENO: fd_t = if (is_freestanding) 2 else std.posix.STDERR_FILENO;

/// Mutex shim. Hosted: `std.Thread.Mutex`. Freestanding: a no-op struct,
/// since the freestanding scheduler is single-worker and the runtime never
/// races on locked state. Using `std.Thread.Mutex` directly on freestanding
/// trips a compile-time chain through `Thread.getCurrentId()`, which has no
/// implementation on `riscv64-freestanding-none`.
pub const Mutex = if (is_freestanding) struct {
    pub fn lock(_: *Mutex) void {}
    pub fn unlock(_: *Mutex) void {}
    pub fn tryLock(_: *Mutex) bool {
        return true;
    }
} else std.Thread.Mutex;

/// RwLock shim. Same reasoning as Mutex above.
pub const RwLock = if (is_freestanding) struct {
    pub fn lock(_: *RwLock) void {}
    pub fn unlock(_: *RwLock) void {}
    pub fn lockShared(_: *RwLock) void {}
    pub fn unlockShared(_: *RwLock) void {}
    pub fn tryLock(_: *RwLock) bool {
        return true;
    }
    pub fn tryLockShared(_: *RwLock) bool {
        return true;
    }
} else std.Thread.RwLock;
