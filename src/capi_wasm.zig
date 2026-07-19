const std = @import("std");

// The interpreter, stack, and register-word plumbing land later, so this file exists only to give
// the wasm32-freestanding build path a root module to compile.

pub const panic = std.debug.no_panic;
