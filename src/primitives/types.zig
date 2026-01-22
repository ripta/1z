const dictionary = @import("../dictionary.zig");
pub const NativeFn = dictionary.NativeFn;

pub const InterpreterError = error{
    // General error types
    StackUnderflow,
    TypeError,
    NoTokenizerAvailable,
    // Error handling types
    RethrowError,
    // Stack effect error types
    StackEffectMismatch,
    // Arithmetic error types
    DivisionByZero,
    IntegerOverflow,
    // File error types
    FileNotFound,
    FileReadError,
    // Hash table error types
    InvalidHashSyntax,
    // Sequence error types
    IndexOutOfBounds,
    EmptySequence,
    KeyNotFound,
    // I/O error types
    IOError,
    ClosedStream,
    PermissionDenied,
    NotSeekable,
};

pub const Primitive = struct {
    name: []const u8,
    stack_effect: ?[]const u8 = null,
    func: NativeFn,
    parse_time: bool = false,
};
