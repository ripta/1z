// Re-export types
pub const types = @import("types.zig");
pub const InterpreterError = types.InterpreterError;
pub const Primitive = types.Primitive;

// Re-export helpers
pub const helpers = @import("helpers.zig");
pub const makeSimpleEffect = helpers.makeSimpleEffect;
pub const popInteger = helpers.popInteger;
pub const popBoolean = helpers.popBoolean;
pub const popQuotation = helpers.popQuotation;
pub const popSymbol = helpers.popSymbol;
pub const popString = helpers.popString;
pub const popStackEffect = helpers.popStackEffect;
pub const popVector = helpers.popVector;
pub const popByteArray = helpers.popByteArray;
pub const popStream = helpers.popStream;

// Domain modules
pub const stack = @import("stack.zig");
pub const arithmetic = @import("arithmetic.zig");
pub const control = @import("control.zig");
pub const strings = @import("strings.zig");
pub const misc = @import("misc.zig");
pub const parse_time = @import("parse_time.zig");

// Aggregated primitives from extracted modules
pub const extracted_primitives = stack.primitives ++
    arithmetic.primitives ++
    control.primitives ++
    strings.primitives ++
    misc.primitives ++
    parse_time.primitives;
