const dictionary = @import("../dictionary.zig");
pub const NativeFn = dictionary.NativeFn;

pub const InterpreterError = error{
    // General error types
    StackUnderflow,
    TypeMismatch,
    NoTokenizerAvailable,
    // Error handling types
    UserRethrown,
    UserThrown,
    // Stack effect error types
    StackEffectMismatch,
    // Arithmetic error types
    DivisionByZero,
    FixnumOverflow,
    // File error types
    FileNotFound,
    FileReadFailed,
    // Hash table error types
    InvalidHashSyntax,
    // Sequence error types
    IndexOutOfBounds,
    EmptySequence,
    KeyNotFound,
    NotComparable,
    // Import error types
    EmptyImport,
    // I/O error types
    IOFailed,
    ClosedStream,
    PermissionDenied,
    NotSeekable,
    // Resource error types
    UseAfterClose,
    // FFI error types
    FFILibraryNotFound,
    FFISymbolNotFound,
    FFITypeMismatch,
    FFICallFailed,
    FFIRangeError,
    // Recursion error types
    NonTailRecursion,
    StackOverflow,
};

const Marker = @import("../value.zig").Marker;

pub const Primitive = struct {
    name: []const u8,
    stack_effect: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    func: NativeFn,
    parse_time: bool = false,
    parse_time_only: bool = false,
    effect_transparent: bool = false,
    markers: []const *Marker = &.{},
};

pub const RegistryEntry = struct {
    name: []const u8,
    func: NativeFn,
    stack_effect: ?[]const u8 = null,
    polymorphic: bool = false,
};
