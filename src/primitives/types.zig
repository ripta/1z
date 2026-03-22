const std = @import("std");
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

pub const SandboxSpec = struct {
    granted: u8 = 0,

    const cap_bits = [_]struct { cap: Capability, bit: u3 }{
        .{ .cap = .io, .bit = 0 },
        .{ .cap = .io_fs, .bit = 1 },
        .{ .cap = .io_net, .bit = 2 },
        .{ .cap = .ffi, .bit = 3 },
        .{ .cap = .system, .bit = 4 },
        .{ .cap = .eval, .bit = 5 },
    };

    fn bitFor(cap: Capability) ?u3 {
        for (cap_bits) |entry| {
            if (entry.cap == cap) return entry.bit;
        }
        return null;
    }

    /// Grant a capability. Granting io/fs or io/net also grants io.
    pub fn grant(self: *SandboxSpec, cap: Capability) void {
        if (cap == .none) return;
        if (bitFor(cap)) |bit| {
            self.granted |= @as(u8, 1) << bit;
        }
        if (cap == .io_fs or cap == .io_net) {
            if (bitFor(.io)) |bit| {
                self.granted |= @as(u8, 1) << bit;
            }
        }
    }

    /// Returns true if the required capability is granted (or is .none).
    pub fn allows(self: SandboxSpec, required: Capability) bool {
        if (required == .none) return true;
        const bit = bitFor(required) orelse return false;
        return (self.granted & (@as(u8, 1) << bit)) != 0;
    }

    /// Map a user-facing string to a Capability.
    pub fn fromString(name: []const u8) ?Capability {
        if (std.mem.eql(u8, name, "io")) return .io;
        if (std.mem.eql(u8, name, "io/fs")) return .io_fs;
        if (std.mem.eql(u8, name, "io/net")) return .io_net;
        if (std.mem.eql(u8, name, "ffi")) return .ffi;
        if (std.mem.eql(u8, name, "system")) return .system;
        if (std.mem.eql(u8, name, "eval")) return .eval;
        return null;
    }

    /// Write the granted capabilities in display format.
    pub fn writeGranted(self: SandboxSpec, writer: anytype) !void {
        try writer.writeAll("sandbox{ ");
        var wrote_any = false;
        for (cap_bits) |entry| {
            if ((self.granted & (@as(u8, 1) << entry.bit)) != 0) {
                if (wrote_any) try writer.writeByte(' ');
                wrote_any = true;
                try writer.writeAll(switch (entry.cap) {
                    .io => "io",
                    .io_fs => "io/fs",
                    .io_net => "io/net",
                    .ffi => "ffi",
                    .system => "system",
                    .eval => "eval",
                    .none => unreachable,
                });
            }
        }
        if (wrote_any) try writer.writeByte(' ');
        try writer.writeByte('}');
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

test "SandboxSpec empty grants nothing" {
    const spec = SandboxSpec{};
    try testing.expect(!spec.allows(.io));
    try testing.expect(!spec.allows(.io_fs));
    try testing.expect(!spec.allows(.ffi));
    try testing.expect(spec.allows(.none));
}

test "SandboxSpec grant and allows" {
    var spec = SandboxSpec{};
    spec.grant(.ffi);
    try testing.expect(spec.allows(.ffi));
    try testing.expect(!spec.allows(.io));
    try testing.expect(!spec.allows(.system));
}

test "SandboxSpec hierarchy expansion" {
    var spec = SandboxSpec{};
    spec.grant(.io_fs);
    try testing.expect(spec.allows(.io_fs));
    try testing.expect(spec.allows(.io));
    try testing.expect(!spec.allows(.io_net));
}

test "SandboxSpec.fromString" {
    try testing.expectEqual(Capability.io, SandboxSpec.fromString("io").?);
    try testing.expectEqual(Capability.io_fs, SandboxSpec.fromString("io/fs").?);
    try testing.expectEqual(Capability.io_net, SandboxSpec.fromString("io/net").?);
    try testing.expectEqual(Capability.ffi, SandboxSpec.fromString("ffi").?);
    try testing.expectEqual(Capability.system, SandboxSpec.fromString("system").?);
    try testing.expectEqual(Capability.eval, SandboxSpec.fromString("eval").?);
    try testing.expect(SandboxSpec.fromString("bogus") == null);
}

test "SandboxSpec.writeGranted empty" {
    const spec = SandboxSpec{};
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try spec.writeGranted(fbs.writer());
    try testing.expectEqualStrings("sandbox{ }", fbs.getWritten());
}

test "SandboxSpec.writeGranted with capabilities" {
    var spec = SandboxSpec{};
    spec.grant(.eval);
    spec.grant(.ffi);
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try spec.writeGranted(fbs.writer());
    try testing.expectEqualStrings("sandbox{ ffi eval }", fbs.getWritten());
}
