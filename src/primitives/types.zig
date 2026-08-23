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
    // Build/platform error types
    BuildUnsupported,
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
    process,

    /// Returns true if `self` grants access to `required`.
    pub fn grants(self: Capability, required: Capability) bool {
        if (self == required) return true;
        if (required == .io) return self == .io_fs or self == .io_net;
        if (required == .process) return self == .io or self == .io_fs or self == .io_net;
        return false;
    }

    /// Returns the user-facing display name for this capability.
    pub fn displayName(self: Capability) []const u8 {
        return switch (self) {
            .none => "none",

            .io => "io",
            .io_fs => "io/fs",
            .io_net => "io/net",

            .ffi => "ffi",
            .system => "system",
            .eval => "eval",
            .process => "process",
        };
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
        .{ .cap = .process, .bit = 6 },
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
        for (cap_bits) |entry| {
            if ((self.granted & (@as(u8, 1) << entry.bit)) != 0 and entry.cap.grants(required)) {
                return true;
            }
        }
        return false;
    }

    /// Map a user-facing string to a Capability.
    pub fn fromString(name: []const u8) ?Capability {
        if (std.mem.eql(u8, name, "io")) return .io;
        if (std.mem.eql(u8, name, "io/fs")) return .io_fs;
        if (std.mem.eql(u8, name, "io/net")) return .io_net;

        if (std.mem.eql(u8, name, "ffi")) return .ffi;
        if (std.mem.eql(u8, name, "system")) return .system;
        if (std.mem.eql(u8, name, "eval")) return .eval;
        if (std.mem.eql(u8, name, "process")) return .process;

        return null;
    }

    /// Returns a sandbox spec granting only capabilities present in both specs.
    pub fn intersect(self: SandboxSpec, other: SandboxSpec) SandboxSpec {
        return .{ .granted = self.granted & other.granted };
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
                    .process => "process",

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
    /// Whether calling this native can install a word definition. Three ways in: reaching
    /// `Context.defineWord` / `Context.defineImportedWord` itself, executing arbitrary source that
    /// does, or invoking a word chosen at runtime that does.
    ///
    /// The compiled tier reads it to decide whether a quotation body needs the interpreter's
    /// transient lexical frame. The set has to stay complete: an unflagged definer lets a
    /// compiled quotation drop a binding into the durable frame the interpreter keeps it out
    /// of. A Debug-only assertion at both define choke points holds the set honest.
    defines_word: bool = false,
    markers: []const *Marker = &.{},
    capability: Capability = .none,
};

pub const RegistryEntry = struct {
    name: []const u8,
    func: NativeFn,
    stack_effect: ?[]const u8 = null,
    polymorphic: bool = false,
    /// Whether calling this native can install a word definition. See `Primitive.defines_word`.
    defines_word: bool = false,
    capability: Capability = .none,
};

const testing = @import("std").testing;

test "Capability.grants identity" {
    try testing.expect(Capability.none.grants(.none));
    try testing.expect(Capability.io.grants(.io));
    try testing.expect(Capability.process.grants(.process));
    try testing.expect(Capability.io_fs.grants(.io_fs));
    try testing.expect(Capability.io_net.grants(.io_net));
    try testing.expect(Capability.ffi.grants(.ffi));
    try testing.expect(Capability.system.grants(.system));
    try testing.expect(Capability.eval.grants(.eval));
}

test "Capability.grants hierarchy" {
    try testing.expect(Capability.io_fs.grants(.io));
    try testing.expect(Capability.io_net.grants(.io));
    try testing.expect(Capability.io.grants(.process));
    try testing.expect(Capability.io_fs.grants(.process));
    try testing.expect(Capability.io_net.grants(.process));
}

test "Capability.grants does not grant unrelated" {
    try testing.expect(!Capability.none.grants(.io));
    try testing.expect(!Capability.io.grants(.io_fs));
    try testing.expect(!Capability.io.grants(.io_net));
    try testing.expect(!Capability.ffi.grants(.io));
    try testing.expect(!Capability.system.grants(.ffi));
    try testing.expect(!Capability.io_fs.grants(.io_net));
    try testing.expect(!Capability.io_net.grants(.io_fs));
    try testing.expect(!Capability.process.grants(.io));
}

test "SandboxSpec empty grants nothing" {
    const spec = SandboxSpec{};
    try testing.expect(!spec.allows(.io));
    try testing.expect(!spec.allows(.io_fs));
    try testing.expect(!spec.allows(.ffi));
    try testing.expect(!spec.allows(.process));
    try testing.expect(spec.allows(.none));
}

test "SandboxSpec grant and allows" {
    var spec = SandboxSpec{};
    spec.grant(.ffi);
    try testing.expect(spec.allows(.ffi));
    try testing.expect(!spec.allows(.io));
    try testing.expect(!spec.allows(.system));
    try testing.expect(!spec.allows(.process));
}

test "SandboxSpec hierarchy expansion" {
    var spec = SandboxSpec{};
    spec.grant(.io_fs);
    try testing.expect(spec.allows(.io_fs));
    try testing.expect(spec.allows(.io));
    try testing.expect(!spec.allows(.io_net));
    try testing.expect(spec.allows(.process));
}

test "SandboxSpec.fromString" {
    try testing.expectEqual(Capability.io, SandboxSpec.fromString("io").?);
    try testing.expectEqual(Capability.io_fs, SandboxSpec.fromString("io/fs").?);
    try testing.expectEqual(Capability.io_net, SandboxSpec.fromString("io/net").?);
    try testing.expectEqual(Capability.ffi, SandboxSpec.fromString("ffi").?);
    try testing.expectEqual(Capability.system, SandboxSpec.fromString("system").?);
    try testing.expectEqual(Capability.eval, SandboxSpec.fromString("eval").?);
    try testing.expectEqual(Capability.process, SandboxSpec.fromString("process").?);
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
    spec.grant(.process);

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try spec.writeGranted(fbs.writer());
    try testing.expectEqualStrings("sandbox{ ffi eval process }", fbs.getWritten());
}

test "Capability.displayName" {
    try testing.expectEqualStrings("none", Capability.none.displayName());

    try testing.expectEqualStrings("io", Capability.io.displayName());
    try testing.expectEqualStrings("io/fs", Capability.io_fs.displayName());
    try testing.expectEqualStrings("io/net", Capability.io_net.displayName());

    try testing.expectEqualStrings("ffi", Capability.ffi.displayName());
    try testing.expectEqualStrings("system", Capability.system.displayName());
    try testing.expectEqualStrings("eval", Capability.eval.displayName());
    try testing.expectEqualStrings("process", Capability.process.displayName());
}

test "SandboxSpec.intersect" {
    var a = SandboxSpec{};
    a.grant(.io);
    a.grant(.ffi);
    var b = SandboxSpec{};
    b.grant(.io);
    b.grant(.system);
    const result = a.intersect(b);
    try testing.expect(result.allows(.io));
    try testing.expect(!result.allows(.ffi));
    try testing.expect(!result.allows(.system));
}

test "SandboxSpec.intersect with empty" {
    var a = SandboxSpec{};
    a.grant(.io);
    const result = a.intersect(SandboxSpec{});
    try testing.expect(!result.allows(.io));
}
