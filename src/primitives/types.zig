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

pub const Capability = enum {
    none,
    io,
    io_fs,
    io_net,
    ffi,
    system,
    eval,

    /// Returns true if `self` grants access to `required`.
    pub fn grants(self: Capability, required: Capability) bool {
        if (self == required) return true;
        if (required == .io) return self == .io_fs or self == .io_net;
        return false;
    }
};

pub const Primitive = struct {
    name: []const u8,
    stack_effect: ?[]const u8 = null,
    doc: ?[]const u8 = null,
    func: NativeFn,
    parse_time: bool = false,
    parse_time_only: bool = false,
    effect_transparent: bool = false,
    markers: []const *Marker = &.{},
    capability: Capability = .none,
};

pub const RegistryEntry = struct {
    name: []const u8,
    func: NativeFn,
    stack_effect: ?[]const u8 = null,
    polymorphic: bool = false,
    capability: Capability = .none,
};

const testing = @import("std").testing;

test "Capability.grants identity" {
    try testing.expect(Capability.none.grants(.none));
    try testing.expect(Capability.io.grants(.io));
    try testing.expect(Capability.io_fs.grants(.io_fs));
    try testing.expect(Capability.io_net.grants(.io_net));
    try testing.expect(Capability.ffi.grants(.ffi));
    try testing.expect(Capability.system.grants(.system));
    try testing.expect(Capability.eval.grants(.eval));
}

test "Capability.grants hierarchy" {
    try testing.expect(Capability.io_fs.grants(.io));
    try testing.expect(Capability.io_net.grants(.io));
}

test "Capability.grants does not grant unrelated" {
    try testing.expect(!Capability.none.grants(.io));
    try testing.expect(!Capability.io.grants(.io_fs));
    try testing.expect(!Capability.io.grants(.io_net));
    try testing.expect(!Capability.ffi.grants(.io));
    try testing.expect(!Capability.system.grants(.ffi));
    try testing.expect(!Capability.io_fs.grants(.io_net));
    try testing.expect(!Capability.io_net.grants(.io_fs));
}
