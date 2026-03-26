const std = @import("std");
const StackEffect = @import("stack_effect.zig").StackEffect;
const BenchmarkReport = @import("benchmark.zig").BenchmarkReport;
const Task = @import("task.zig").Task;
const Iterator = @import("iterator.zig").Iterator;
const dictionary_mod = @import("dictionary.zig");
const NativeFn = dictionary_mod.NativeFn;
const WordProvenance = dictionary_mod.WordProvenance;
const FfiSignature = @import("ffi/signature.zig").FfiSignature;
pub const SandboxSpec = @import("primitives/types.zig").SandboxSpec;

pub const BigIntManaged = std.math.big.int.Managed;

/// Instruction represents a single operation in a compiled quotation.
pub const Instruction = struct {
    op: Op,
    line: usize, // 1-based line number from source
    column: usize = 0, // 1-based column number from source

    pub const Op = union(enum) {
        push_literal: Value,
        call_word: []const u8,
    };
};

/// Hash table type for H{ } literals.
pub const HashTable = std.StringHashMapUnmanaged(Value);

/// Vector type for V{ } literals - mutable, dynamically-sized sequences.
pub const Vector = std.ArrayListUnmanaged(Value);

/// ByteArray type for B{ } literals - mutable, dynamically-sized byte sequences.
pub const ByteArray = std.ArrayListUnmanaged(u8);

/// Context for hashing and comparing Values in hash-based containers.
pub const ValueContext = struct {
    pub fn hash(self: @This(), key: Value) u32 {
        _ = self;
        // Truncate 64-bit hash to 32-bit as required by ArrayHashMap
        return @truncate(key.hashValue());
    }

    pub fn eql(self: @This(), a: Value, b: Value, index: usize) bool {
        _ = self;
        _ = index;
        return a.eql(b);
    }
};

/// Set type for S{ } literals - immutable collections of unique values.
/// Uses hash-based storage for O(1) average-case membership testing.
pub const Set = std.ArrayHashMapUnmanaged(Value, void, ValueContext, true);

/// MutableMap type for M{ } literals - mutable key-value store.
pub const MutableMap = std.StringHashMapUnmanaged(Value);

/// StreamMode indicates how a stream was opened.
pub const StreamMode = enum {
    read,
    write,
    append,
    read_write,

    pub fn toString(self: StreamMode) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .append => "append",
            .read_write => "read-write",
        };
    }
};

/// BufferingMode indicates how a stream is buffered.
pub const BufferingMode = enum {
    none,
    line,
    block,

    pub fn toSymbol(self: BufferingMode) []const u8 {
        return switch (self) {
            .none => "none",
            .line => "line",
            .block => "block",
        };
    }
};

/// VTable for stream I/O dispatch. Each wrapper layer provides its own vtable.
pub const StreamVTable = struct {
    read: *const fn (*Stream, []u8, *@import("context.zig").Context) anyerror!usize,
    write: *const fn (*Stream, []const u8, *@import("context.zig").Context) anyerror!usize,
    close: *const fn (*Stream) void,
    flush: *const fn (*Stream) anyerror!void,
};

/// Stream wraps a file descriptor for I/O operations. Wrappers (TLS,
/// compression, etc.) form a singly-linked list via `inner`, each with
/// its own vtable. The `fd` field always holds the bottom-level file
/// descriptor for scheduler integration and fcntl operations.
pub const Stream = struct {
    vtable: *const StreamVTable,
    fd: std.posix.fd_t,
    mode: StreamMode,
    closed: bool = false,
    // For display: "stdout", "stderr", file path
    name: []const u8,
    buffering: BufferingMode = .none,
    nonblocking_set: bool = false,
    // Wrapper-specific state, e.g., TLS session state or compressor context.
    impl: ?*anyopaque = null,
    // Wrapped stream, where base streams have null inner.
    inner: ?*Stream = null,
};

/// Resource wraps an opaque C pointer for FFI interop.
/// All instances of the same resource type share a type_name string.
/// The ptr is nulled on close as defense-in-depth alongside the closed flag.
pub const FfiCloseFn = struct {
    fn_ptr: *anyopaque,
};

pub const CloseFn = union(enum) {
    none,
    native: *const fn (*anyopaque) void,
    ffi: *const FfiCloseFn,
};

pub const Resource = struct {
    type_name: []const u8,
    ptr: ?*anyopaque = null,
    closed: bool = false,
    close_fn: CloseFn = .none,
    ffi_signature: ?*const FfiSignature = null,
};

/// Parameter represents a dynamically-scoped variable with a lazy default.
/// The default quotation is evaluated each time the parameter is accessed
/// without a binding in the current dynamic scope.
pub const Parameter = struct {
    name: []const u8,
    default_quotation: Quotation, // Lazy default - evaluated on get if unbound
};

/// Marker represents a named marker for attaching metadata to definitions.
/// Markers are pure metadata values that can be attached to word definitions.
/// Anonymous markers (created by `marker` word) have empty name until defined.
pub const Marker = struct {
    name: []const u8, // Empty for anonymous, actual name when defined with ;
};

/// VirtualType represents the definition of a virtual type.
///
/// All instances of the same virtual type share a single VirtualType allocation,
/// enabling pointer equality for type identity checks.
///
/// The `parent_type` field models a variant-to-parent relationship. For example,
/// when `define-enum` creates variants like `color:red`, it set each variant's
/// `parent_type` to point at the parent enum's `TypeValue`. This chain is
/// exactly one level deep: a variant points to its enum, and the enum itself
/// has no parent. This constraint is structural: only VirtualType carries
/// `parent_type`, and an enum's TypeValue is not  backed by any VirtualType.
///
/// `instance-of?` uses the parent_type field as a one-level fallback: it first
/// compares the value's own TypeValue pointer against the query type, then
/// checks the value's `parent_type` if set. This allows:
///
///   color:red instance-of? color
///
/// to return true.
///
/// `parent_type` is unrelated to value containment. A nested array like
/// `{ { 1 } }` has type `array`, not `array(array(fixnum))`. The type
/// system does not currently track inner element types at the value level.
///
/// Parameterized virtual types use `base_type` to record what base type they
/// wrap (e.g., array) and `type_params` to record element constraints (e.g.,
/// fixnum). The validating wrap word checks each element against type_params
/// during construction.
pub const VirtualType = struct {
    // Type name, e.g., "duration"
    name: []const u8,
    // Expected inner type name, e.g., "fixnum"
    inner_type: []const u8,
    // Anonymous struct backing, if struct-backed
    anon_struct: ?*const StructType = null,
    // Parent enum type for enum variants, e.g., the "color" TypeValue for "color:red"
    parent_type: ?*const TypeValue = null,
    // Base type for parameterized types, e.g., the "array" TypeValue for "array(fixnum)"
    base_type: ?*const TypeValue = null,
    // Type parameters for parameterized types, e.g., [fixnum] for "array(fixnum)"
    type_params: ?[]*const TypeValue = null,
    // First-class type value for this virtual type, set during type registration
    type_val: ?*TypeValue = null,
};

/// StructType represents the definition of a struct type.
/// Created by `struct{ field1 field2 ... }` syntax.
pub const StructType = struct {
    name: []const u8, // Type name (e.g., "point")
    fields: []const []const u8, // Field names in order (e.g., ["x", "y"])
    // First-class type value for this struct type, set during type registration
    type_val: ?*TypeValue = null,
};

/// FormatSpec controls padding/alignment when rendering a template placeholder.
pub const FormatSpec = struct {
    width: ?usize = null,
    fill: u8 = ' ',
    align_left: bool = false,
};

/// TemplateSegment is one piece of a parsed template: either literal text or a placeholder.
pub const TemplateSegment = union(enum) {
    literal: []const u8,
    identity: FormatSpec,
    named: struct {
        name: []const u8,
        spec: FormatSpec,
    },
    indexed: struct {
        index: usize,
        spec: FormatSpec,
    },
};

/// TypeValue represents a first-class type value that can be pushed onto the stack.
/// Created when type names are used as words.
pub const TypeValue = struct {
    name: []const u8,
    descriptor: ?*HashTable,
};

/// StructInstance represents an instance of a struct type.
/// Created by make-NAME or >NAME words.
pub const StructInstance = struct {
    struct_type: *const StructType, // Reference to the type definition
    fields: []Value, // Field values in order (mutable for setter support)
};

/// ModuleWord represents a word definition captured from a loaded file
/// or registered in a virtual module.
pub const ModuleWord = struct {
    stack_effect: ?StackEffect = null,
    polymorphic: bool = false,
    markers: []const *Marker = &.{},
    source_module: ?*const Module = null,
    doc: ?[]const u8 = null,
    source_file: ?[]const u8 = null,
    source_line: usize = 0,
    source_column: usize = 0,
    provenance: ?WordProvenance = null,
    capability: @import("primitives/types.zig").Capability = .none,
    action: union(enum) {
        compound: []const Instruction,
        native: NativeFn,
    },
};

/// Module represents a collection of word definitions loaded from a file.
/// Created by `load` and used for qualified name access (e.g., math.double).
pub const Module = struct {
    name: []const u8,
    words: std.StringHashMapUnmanaged(ModuleWord),
    /// Dependencies: words imported from other modules during loading.
    /// These are not part of the module's public API but are needed at
    /// runtime by the module's own words (late binding resolution).
    deps: std.StringHashMapUnmanaged(ModuleWord) = .{},
    /// Whether this module can be imported with `import`. Virtual modules
    /// like `native` set this to false.
    importable: bool = true,
};

/// StackFrame represents a single frame in a stack trace.
pub const StackFrame = struct {
    word_name: []const u8,
    source: []const u8,
    line: usize,
};

/// ErrorObject represents a structured error with type, message, optional data, and optional stack trace.
pub const ErrorObject = struct {
    error_type: []const u8,
    message: []const u8,
    data: ?*const Value = null,
    stack_trace: ?[]const StackFrame = null,

    pub fn write(self: ErrorObject, writer: anytype) !void {
        try writer.print("<error {s}: {s}", .{ self.error_type, self.message });
        if (self.data) |data| {
            try writer.writeAll(" data=");
            try data.write(writer);
        }

        if (self.stack_trace) |trace| {
            try writer.writeAll(" [");
            for (trace, 0..) |frame, i| {
                if (i > 0) try writer.writeAll(" <- ");
                try writer.print("{s}:{d}:{s}", .{ frame.source, frame.line, frame.word_name });
            }
            try writer.writeAll("]");
        }
        try writer.writeAll(">");
    }

    pub fn eql(self: ErrorObject, other: ErrorObject) bool {
        if (!std.mem.eql(u8, self.error_type, other.error_type)) return false;
        if (!std.mem.eql(u8, self.message, other.message)) return false;

        // Compare data
        if (self.data == null and other.data == null) {
            // both null, ok
        } else if (self.data != null and other.data != null) {
            if (!self.data.?.eql(other.data.?.*)) return false;
        } else {
            return false;
        }

        // Compare stack traces
        if (self.stack_trace == null and other.stack_trace == null) return true;
        if (self.stack_trace == null or other.stack_trace == null) return false;

        const a = self.stack_trace.?;
        const b = other.stack_trace.?;
        if (a.len != b.len) return false;
        for (a, b) |fa, fb| {
            if (!std.mem.eql(u8, fa.word_name, fb.word_name)) return false;
            if (fa.line != fb.line) return false;
        }
        return true;
    }
};

fn formatSpecEql(a: FormatSpec, b: FormatSpec) bool {
    return a.width == b.width and a.fill == b.fill and a.align_left == b.align_left;
}

fn templateSegmentEql(a: TemplateSegment, b: TemplateSegment) bool {
    const Tag = std.meta.Tag(TemplateSegment);
    if (@as(Tag, a) != @as(Tag, b)) return false;
    return switch (a) {
        .literal => |text| std.mem.eql(u8, text, b.literal),
        .identity => |spec| formatSpecEql(spec, b.identity),
        .named => |n| std.mem.eql(u8, n.name, b.named.name) and formatSpecEql(n.spec, b.named.spec),
        .indexed => |idx| idx.index == b.indexed.index and formatSpecEql(idx.spec, b.indexed.spec),
    };
}

fn instructionEql(a: Instruction, b: Instruction) bool {
    const Tag = std.meta.Tag(Instruction.Op);
    if (@as(Tag, a.op) != @as(Tag, b.op)) return false;
    return switch (a.op) {
        .push_literal => |va| va.eql(b.op.push_literal),
        .call_word => |na| std.mem.eql(u8, na, b.op.call_word),
    };
}

/// Quotation represents executable code with optional stack effect annotation.
pub const Quotation = struct {
    instructions: []const Instruction,
    /// If non-null, the expected stack effect for this quotation.
    /// Used for validation when the quotation is executed.
    effect: ?*const StackEffect = null,
    /// If non-null, a JIT-compiled native code pointer for this quotation's body.
    /// Used by the JIT compiler for indirect calls via `call`.
    code_ptr: ?*const anyopaque = null,

    pub fn eql(self: Quotation, other: Quotation) bool {
        if (self.instructions.len != other.instructions.len) return false;
        for (self.instructions, other.instructions) |ai, bi| {
            if (!instructionEql(ai, bi)) return false;
        }
        // Compare effects
        if (self.effect == null and other.effect == null) return true;
        if (self.effect == null or other.effect == null) return false;
        return self.effect.?.eql(other.effect.?.*);
    }
};

fn writeTemplateSegment(writer: anytype, seg: TemplateSegment) !void {
    // XXX(ripta): omg, ew
    switch (seg) {
        .literal => |text| {
            for (text) |ch| {
                if (ch == '{' or ch == '}' or ch == '"' or ch == '\\') {
                    try writer.writeByte('\\');
                }
                try writer.writeByte(ch);
            }
        },
        .identity => |spec| {
            try writer.writeByte('{');
            try writeFormatSpec(writer, spec);
            try writer.writeByte('}');
        },
        .named => |n| {
            try writer.writeByte('{');
            try writer.writeAll(n.name);
            try writeFormatSpec(writer, n.spec);
            try writer.writeByte('}');
        },
        .indexed => |idx| {
            try writer.writeByte('{');
            try writer.print("{d}", .{idx.index});
            try writeFormatSpec(writer, idx.spec);
            try writer.writeByte('}');
        },
    }
}

fn writeFormatSpec(writer: anytype, spec: FormatSpec) !void {
    const has_spec = spec.width != null or spec.fill != ' ' or spec.align_left;
    if (!has_spec) return;
    try writer.writeByte(':');
    var need_comma = false;
    if (spec.width) |w| {
        try writer.print("width={d}", .{w});
        need_comma = true;
    }
    if (spec.fill != ' ') {
        if (need_comma) try writer.writeByte(',');
        try writer.print("fill={c}", .{spec.fill});
        need_comma = true;
    }
    if (spec.align_left) {
        if (need_comma) try writer.writeByte(',');
        try writer.writeAll("align=left");
    }
}

/// Value represents any value that can be stored on the stack.
pub const Value = union(enum) {
    fixnum: i64,
    float: f64,
    bignum: BigIntManaged,
    boolean: bool,
    string: []const u8,
    symbol: []const u8,
    array: []const Value,
    quotation: Quotation,
    hash: *HashTable,
    vector: *Vector,
    byte_array: *ByteArray,
    set: *Set,
    mutable_map: *MutableMap,
    stream: *Stream,
    resource: *Resource,
    parameter: *Parameter,
    module: *Module,
    marker: *Marker,
    struct_type: *StructType,
    struct_instance: *StructInstance,
    tagged: struct { tag: *const VirtualType, inner: *const Value },
    template: []const TemplateSegment,
    benchmark_report: *BenchmarkReport,
    stack_effect: StackEffect,
    error_value: ErrorObject,
    task: *Task,
    channel: *@import("channel.zig").Channel,
    iterator: *Iterator,
    doc_string: []const u8,
    type_val: *TypeValue,
    sandbox_spec: *SandboxSpec,
    unit: void,

    pub fn write(self: Value, writer: anytype) anyerror!void {
        switch (self) {
            .fixnum => |i| try writer.print("{d}", .{i}),
            .float => |f| {
                if (std.math.isNan(f)) {
                    try writer.writeAll("nan");
                } else if (std.math.isInf(f)) {
                    if (f < 0) try writer.writeByte('-');
                    try writer.writeAll("inf");
                } else {
                    var buf: [64]u8 = undefined;
                    const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
                    try writer.writeAll(formatted);
                    if (std.mem.indexOfScalar(u8, formatted, '.') == null) {
                        try writer.writeAll(".0");
                    }
                }
            },
            .bignum => |b| {
                const str = try b.toConst().toStringAlloc(b.allocator, 10, .lower);
                try writer.writeAll(str);
            },
            .boolean => |b| try writer.writeAll(if (b) "t" else "f"),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .symbol => |s| try writer.print("{s}:", .{s}),
            .array => |items| {
                try writer.writeAll("{ ");
                for (items) |item| {
                    try item.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .quotation => |quot| {
                try writer.writeAll("[ ");
                for (quot.instructions) |instr| {
                    switch (instr.op) {
                        .push_literal => |v| {
                            try v.write(writer);
                            try writer.writeAll(" ");
                        },
                        .call_word => |name| try writer.print("{s} ", .{name}),
                    }
                }
                try writer.writeAll("]");
            },
            // TODO(ripta): This is currently tightly-coupled to the internal
            // representation of HashTable, despite H{ } being a non-native
            // implementation in the prelude.
            .hash => |h| {
                try writer.writeAll("H{ ");
                var iter = h.iterator();
                while (iter.next()) |entry| {
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .vector => |v| {
                try writer.writeAll("V{ ");
                for (v.items) |item| {
                    try item.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .byte_array => |b| {
                try writer.writeAll("B{ ");
                for (b.items) |byte| {
                    try writer.print("0x{X:0>2} ", .{byte});
                }
                try writer.writeAll("}");
            },
            .set => |s| {
                try writer.writeAll("S{ ");
                for (s.keys()) |key| {
                    try key.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .mutable_map => |m| {
                try writer.writeAll("M{ ");
                var iter = m.iterator();
                while (iter.next()) |entry| {
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .stream => |s| {
                if (s.closed) {
                    try writer.print("<stream {s} (closed)>", .{s.name});
                } else {
                    try writer.writeAll("<stream ");
                    // Walk the wrapper chain from outermost to innermost to
                    // build labels like "tls fd" or "compress tls fd".
                    var cur: ?*const Stream = s;
                    var first = true;
                    while (cur) |c| {
                        if (!first) try writer.writeAll(" ");
                        first = false;
                        try writer.writeAll(c.name);
                        cur = c.inner;
                    }
                    try writer.print(" {s}>", .{s.mode.toString()});
                }
            },
            .resource => |r| {
                if (r.closed) {
                    try writer.print("<resource:{s} (closed)>", .{r.type_name});
                } else {
                    try writer.print("<resource:{s}>", .{r.type_name});
                }
            },
            .parameter => |p| try writer.print("<parameter:{s}>", .{p.name}),
            .module => |m| try writer.print("<module:{s} ({d} words)>", .{ m.name, m.words.count() }),
            .marker => |mk| {
                if (mk.name.len == 0) {
                    try writer.writeAll("<marker>");
                } else {
                    try writer.print("<marker:{s}>", .{mk.name});
                }
            },
            .struct_type => |st| try writer.print("<struct-type:{s}>", .{st.name}),
            .struct_instance => |si| {
                try writer.print("{s}{{ ", .{si.struct_type.name});
                for (si.struct_type.fields, 0..) |field, i| {
                    try writer.print("{s}: ", .{field});
                    try si.fields[i].write(writer);
                    try writer.writeAll(" ");
                }
                try writer.writeAll("}");
            },
            .tagged => |t| {
                try writer.print("<{s} ", .{t.tag.name});
                try t.inner.write(writer);
                try writer.writeAll(">");
            },
            .template => |segments| {
                try writer.writeAll("T\"");
                for (segments) |seg| {
                    try writeTemplateSegment(writer, seg);
                }
                try writer.writeByte('"');
            },
            .benchmark_report => |br| {
                try writer.print("<benchmark-report ({d} entries)>", .{br.entries.items.len});
            },
            .stack_effect => |effect| try effect.write(writer),
            .error_value => |err| try err.write(writer),
            .task => |t| {
                const status = t.getStatus();
                if (t.name) |name| {
                    try writer.print("<task #{d} ({s}) {s}>", .{
                        t.id,
                        name,
                        @tagName(status),
                    });
                } else {
                    try writer.print("<task #{d} {s}>", .{
                        t.id,
                        @tagName(status),
                    });
                }
            },
            .channel => |ch| {
                if (ch.capacity == 0) {
                    try writer.writeAll("<channel unbuffered>");
                } else {
                    try writer.print("<channel capacity={d}>", .{ch.capacity});
                }
            },
            .iterator => |it| {
                try writer.print("<iterator {s} ", .{it.kindName()});
                try it.progressDisplay(writer);
                try writer.writeAll(">");
            },
            .doc_string => |s| try writer.print("<doc-string \"{s}\">", .{s}),
            .type_val => |tv| try writer.print("<type:{s}>", .{tv.name}),
            .sandbox_spec => |spec| try spec.writeGranted(writer),
            .unit => try writer.writeAll("unit"),
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        const Tag = std.meta.Tag(Value);
        if (@as(Tag, self) != @as(Tag, other)) {
            return false;
        }

        return switch (self) {
            .fixnum => |a| a == other.fixnum,
            .float => |a| a == other.float,
            .bignum => |a| a.toConst().eql(other.bignum.toConst()),
            .boolean => |a| a == other.boolean,
            .string => |a| std.mem.eql(u8, a, other.string),
            .symbol => |a| std.mem.eql(u8, a, other.symbol),
            .array => |a| {
                const b = other.array;
                if (a.len != b.len) return false;
                for (a, b) |ai, bi| {
                    if (!ai.eql(bi)) return false;
                }
                return true;
            },
            .quotation => |a| a.eql(other.quotation),
            // TODO(ripta): This is currently tightly-coupled to the internal
            // representation of HashTable, despite H{ } being a non-native
            // implementation in the prelude.
            .hash => |a| {
                const b = other.hash;
                if (a.count() != b.count()) return false;
                var iter = a.iterator();
                while (iter.next()) |entry| {
                    if (b.get(entry.key_ptr.*)) |bval| {
                        if (!entry.value_ptr.eql(bval)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            },
            .vector => |a| {
                const b = other.vector;
                if (a.items.len != b.items.len) return false;
                for (a.items, b.items) |ai, bi| {
                    if (!ai.eql(bi)) return false;
                }
                return true;
            },
            .byte_array => |a| {
                const b = other.byte_array;
                return std.mem.eql(u8, a.items, b.items);
            },
            // Sets use order-independent equality: two sets are equal if they
            // contain the same elements regardless of iteration order.
            .set => |a| {
                const b = other.set;
                if (a.count() != b.count()) return false;
                // Check that every element in a exists in b (O(n) with O(1) lookups)
                for (a.keys()) |key| {
                    if (!b.contains(key)) return false;
                }
                return true;
            },
            .mutable_map => |a| {
                const b = other.mutable_map;
                if (a.count() != b.count()) return false;
                var iter = a.iterator();
                while (iter.next()) |entry| {
                    if (b.get(entry.key_ptr.*)) |bval| {
                        if (!entry.value_ptr.eql(bval)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            },
            // Streams are equal if they refer to the same underlying file handle
            .stream => |a| a == other.stream,
            // Resources are equal if same type name and same pointer
            .resource => |a| {
                const b = other.resource;
                return std.mem.eql(u8, a.type_name, b.type_name) and a.ptr == b.ptr;
            },
            // Parameters are equal if they refer to the same parameter object
            .parameter => |a| a == other.parameter,
            // Modules are equal if they refer to the same module object
            .module => |a| a == other.module,
            // Markers are equal if they refer to the same marker object
            .marker => |a| a == other.marker,
            // Struct types are equal if they refer to the same type object
            .struct_type => |a| a == other.struct_type,
            // Struct instances are equal if same type and all fields equal
            .struct_instance => |a| {
                const b = other.struct_instance;
                if (a.struct_type != b.struct_type) return false;
                for (a.fields, b.fields) |af, bf| {
                    if (!af.eql(bf)) return false;
                }
                return true;
            },
            // Tagged values are equal if same tag pointer and inner values equal
            .tagged => |a| {
                const b = other.tagged;
                return a.tag == b.tag and a.inner.eql(b.inner.*);
            },
            .template => |a| {
                const b = other.template;

                if (a.len != b.len) return false;
                for (a, b) |sa, sb| {
                    if (!templateSegmentEql(sa, sb)) return false;
                }
                return true;
            },
            // Benchmark reports are equal if they refer to the same object
            .benchmark_report => |a| a == other.benchmark_report,
            .stack_effect => |a| a.eql(other.stack_effect),
            .error_value => |a| a.eql(other.error_value),
            .task => |a| a == other.task,
            .channel => |a| a == other.channel,
            .iterator => |a| a == other.iterator,
            .doc_string => |a| std.mem.eql(u8, a, other.doc_string),
            .type_val => |a| a == other.type_val,
            .sandbox_spec => |a| a == other.sandbox_spec,
            .unit => true,
        };
    }

    /// Compute a hash value for this Value.
    /// Used by hash-based containers like Set.
    pub fn hashValue(self: Value) u64 {
        const Hasher = std.hash.Wyhash;
        var hasher = Hasher.init(0);

        // Hash the tag first to distinguish types
        const tag = @intFromEnum(self);
        hasher.update(std.mem.asBytes(&tag));

        switch (self) {
            .fixnum => |i| hasher.update(std.mem.asBytes(&i)),
            .float => |f| {
                var canonical = f;
                if (canonical == 0.0) canonical = 0.0;
                hasher.update(std.mem.asBytes(&canonical));
            },
            .bignum => |b| {
                const c = b.toConst();
                const positive_byte: u8 = if (c.positive) 1 else 0;
                hasher.update(&.{positive_byte});
                for (c.limbs[0..c.limbs.len]) |limb| {
                    hasher.update(std.mem.asBytes(&limb));
                }
            },
            .boolean => |b| hasher.update(std.mem.asBytes(&b)),
            .string, .symbol => |s| hasher.update(s),
            .array => |arr| {
                for (arr) |elem| {
                    const elem_hash = elem.hashValue();
                    hasher.update(std.mem.asBytes(&elem_hash));
                }
            },
            .quotation => |quot| {
                for (quot.instructions) |instr| {
                    const line_hash = instr.line;
                    hasher.update(std.mem.asBytes(&line_hash));
                    switch (instr.op) {
                        .push_literal => |v| {
                            const v_hash = v.hashValue();
                            hasher.update(std.mem.asBytes(&v_hash));
                        },
                        .call_word => |name| hasher.update(name),
                    }
                }
            },
            .hash => |h| {
                // Order-independent hash using XOR
                var combined: u64 = 0;
                var iter = h.iterator();
                while (iter.next()) |entry| {
                    var pair_hasher = Hasher.init(0);
                    pair_hasher.update(entry.key_ptr.*);
                    const val_hash = entry.value_ptr.hashValue();
                    pair_hasher.update(std.mem.asBytes(&val_hash));
                    combined ^= pair_hasher.final();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            .vector => |v| {
                for (v.items) |elem| {
                    const elem_hash = elem.hashValue();
                    hasher.update(std.mem.asBytes(&elem_hash));
                }
            },
            .byte_array => |b| hasher.update(b.items),
            .set => |s| {
                // Order-independent hash using XOR
                var combined: u64 = 0;
                for (s.keys()) |key| {
                    combined ^= key.hashValue();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            .mutable_map => |m| {
                // Order-independent hash using XOR (same as immutable hash)
                var combined: u64 = 0;
                var iter = m.iterator();
                while (iter.next()) |entry| {
                    var pair_hasher = Hasher.init(0);
                    pair_hasher.update(entry.key_ptr.*);
                    const val_hash = entry.value_ptr.hashValue();
                    pair_hasher.update(std.mem.asBytes(&val_hash));
                    combined ^= pair_hasher.final();
                }
                hasher.update(std.mem.asBytes(&combined));
            },
            // Streams hash by pointer identity (same as equality)
            .stream => |s| {
                const ptr_val = @intFromPtr(s);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Resources hash by type name and pointer address
            .resource => |r| {
                hasher.update(r.type_name);
                const ptr_val = @intFromPtr(r.ptr);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Parameters hash by pointer identity (same as equality)
            .parameter => |p| {
                const ptr_val = @intFromPtr(p);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Modules hash by pointer identity (same as equality)
            .module => |m| {
                const ptr_val = @intFromPtr(m);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Markers hash by pointer identity (same as equality)
            .marker => |mk| {
                const ptr_val = @intFromPtr(mk);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Struct types hash by pointer identity (same as equality)
            .struct_type => |st| {
                const ptr_val = @intFromPtr(st);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            // Struct instances hash by type pointer and field values
            .struct_instance => |si| {
                const ptr_val = @intFromPtr(si.struct_type);
                hasher.update(std.mem.asBytes(&ptr_val));
                for (si.fields) |field| {
                    const field_hash = field.hashValue();
                    hasher.update(std.mem.asBytes(&field_hash));
                }
            },
            // Tagged values hash by tag pointer and inner value
            .tagged => |t| {
                const ptr_val = @intFromPtr(t.tag);
                hasher.update(std.mem.asBytes(&ptr_val));
                const inner_hash = t.inner.hashValue();
                hasher.update(std.mem.asBytes(&inner_hash));
            },
            .template => |segments| {
                for (segments) |seg| {
                    switch (seg) {
                        .literal => |text| hasher.update(text),
                        .identity => hasher.update("{}"),
                        .named => |n| hasher.update(n.name),
                        .indexed => |idx| hasher.update(std.mem.asBytes(&idx.index)),
                    }
                }
            },
            // Benchmark reports hash by pointer identity
            .benchmark_report => |br| {
                const ptr_val = @intFromPtr(br);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .stack_effect => |effect| {
                for (effect.inputs) |param| {
                    hasher.update(param.name);
                }
                hasher.update("--");
                for (effect.outputs) |param| {
                    hasher.update(param.name);
                }
            },
            .error_value => |err| {
                hasher.update(err.error_type);
                hasher.update(err.message);
                if (err.data) |data| {
                    const data_hash = data.hashValue();
                    hasher.update(std.mem.asBytes(&data_hash));
                }
            },
            // Tasks hash by pointer identity (same as equality)
            .task => |t| {
                const ptr_val = @intFromPtr(t);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .channel => |ch| {
                const ptr_val = @intFromPtr(ch);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .iterator => |it| {
                const ptr_val = @intFromPtr(it);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .doc_string => |s| hasher.update(s),
            .type_val => |tv| {
                const ptr_val = @intFromPtr(tv);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .sandbox_spec => |spec| {
                const ptr_val = @intFromPtr(spec);
                hasher.update(std.mem.asBytes(&ptr_val));
            },
            .unit => {},
        }

        return hasher.final();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "fixnum format" {
    const val = Value{ .fixnum = 42 };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("42", fbs.getWritten());
}

test "negative fixnum format" {
    const val = Value{ .fixnum = -123 };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("-123", fbs.getWritten());
}

test "fixnum equality" {
    const a = Value{ .fixnum = 42 };
    const b = Value{ .fixnum = 42 };
    const c = Value{ .fixnum = 100 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "float format" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = 3.14 };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("3.14", fbs.getWritten());
}

test "float format whole number" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = 3.0 };
    try val.write(fbs.writer());
    const written = fbs.getWritten();
    try std.testing.expect(std.mem.indexOfScalar(u8, written, '.') != null);
}

test "float format nan" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = std.math.nan(f64) };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("nan", fbs.getWritten());
}

test "float format inf" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = std.math.inf(f64) };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("inf", fbs.getWritten());
}

test "float format negative inf" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const val = Value{ .float = -std.math.inf(f64) };
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("-inf", fbs.getWritten());
}

test "float equality" {
    const a = Value{ .float = 3.14 };
    const b = Value{ .float = 3.14 };
    const c = Value{ .float = 2.71 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "float nan inequality" {
    const a = Value{ .float = std.math.nan(f64) };
    const b = Value{ .float = std.math.nan(f64) };
    try std.testing.expect(!a.eql(b));
}

test "float signed zero equality" {
    const pos = Value{ .float = 0.0 };
    const neg = Value{ .float = -0.0 };
    try std.testing.expect(pos.eql(neg));
}

test "float signed zero hash equality" {
    const pos = Value{ .float = 0.0 };
    const neg = Value{ .float = -0.0 };
    try std.testing.expectEqual(pos.hashValue(), neg.hashValue());
}

test "float vs fixnum not equal" {
    const f = Value{ .float = 42.0 };
    const i = Value{ .fixnum = 42 };
    try std.testing.expect(!f.eql(i));
}

test "stack effect format" {
    const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
    const val = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("( n -- n )", fbs.getWritten());
}

test "stack effect equality" {
    const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
    const a = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const b = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const c = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{ .{ .name = "a" }, .{ .name = "b" } },
        .outputs = &[_]StackEffectParam{.{ .name = "c" }},
    } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "stack effect not equal to other types" {
    const StackEffectParam = @import("stack_effect.zig").StackEffectParam;
    const effect = Value{ .stack_effect = StackEffect{
        .inputs = &[_]StackEffectParam{.{ .name = "n" }},
        .outputs = &[_]StackEffectParam{.{ .name = "n" }},
    } };
    const str = Value{ .string = "n -- n" };
    const sym = Value{ .symbol = "n -- n" };

    try std.testing.expect(!effect.eql(str));
    try std.testing.expect(!effect.eql(sym));
}

test "marker format" {
    var anon = Marker{ .name = "" };
    var named = Marker{ .name = "test-marker" };

    const anon_marker = Value{ .marker = &anon };
    const named_marker = Value{ .marker = &named };

    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try anon_marker.write(fbs.writer());
    try std.testing.expectEqualStrings("<marker>", fbs.getWritten());

    fbs.reset();

    try named_marker.write(fbs.writer());
    try std.testing.expectEqualStrings("<marker:test-marker>", fbs.getWritten());
}

test "marker equality" {
    var m1 = Marker{ .name = "marker" };
    var m2 = Marker{ .name = "marker" };

    const marker1 = &m1;
    const marker2 = &m2;
    const marker3 = marker1;

    const val1 = Value{ .marker = marker1 };
    const val2 = Value{ .marker = marker2 };
    const val3 = Value{ .marker = marker3 };

    try std.testing.expect(!val1.eql(val2));
    try std.testing.expect(val1.eql(val3));
}

test "boolean equality" {
    const t1 = Value{ .boolean = true };
    const t2 = Value{ .boolean = true };
    const f1 = Value{ .boolean = false };

    try std.testing.expect(t1.eql(t2));
    try std.testing.expect(!t1.eql(f1));
}

test "string equality" {
    const a = Value{ .string = "hello" };
    const b = Value{ .string = "hello" };
    const c = Value{ .string = "world" };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "symbol equality" {
    const a = Value{ .symbol = "foo" };
    const b = Value{ .symbol = "foo" };
    const c = Value{ .symbol = "bar" };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "array equality" {
    const arr1 = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } };
    const arr2 = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 2 } };
    const arr3 = &[_]Value{ .{ .fixnum = 1 }, .{ .fixnum = 3 } };
    const arr4 = &[_]Value{.{ .fixnum = 1 }};

    const a = Value{ .array = arr1 };
    const b = Value{ .array = arr2 };
    const c = Value{ .array = arr3 };
    const d = Value{ .array = arr4 };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
}

test "quotation equality" {
    const instrs1 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const instrs2 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 },
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    };
    const instrs3 = &[_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
    };

    const a = Value{ .quotation = .{ .instructions = instrs1 } };
    const b = Value{ .quotation = .{ .instructions = instrs2 } };
    const c = Value{ .quotation = .{ .instructions = instrs3 } };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "cross-type inequality" {
    const int_val = Value{ .fixnum = 42 };
    const bool_val = Value{ .boolean = true };
    const str_val = Value{ .string = "42" };
    const sym_val = Value{ .symbol = "42" };
    const arr_val = Value{ .array = &[_]Value{} };

    // Different types are never equal
    try std.testing.expect(!int_val.eql(bool_val));
    try std.testing.expect(!int_val.eql(str_val));
    try std.testing.expect(!str_val.eql(sym_val));
    try std.testing.expect(!arr_val.eql(int_val));
}

test "resource format open" {
    var r = Resource{ .type_name = "sqlite-db" };
    const val = Value{ .resource = &r };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("<resource:sqlite-db>", fbs.getWritten());
}

test "resource format closed" {
    var r = Resource{ .type_name = "sqlite-db", .closed = true };
    const val = Value{ .resource = &r };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try val.write(fbs.writer());
    try std.testing.expectEqualStrings("<resource:sqlite-db (closed)>", fbs.getWritten());
}

test "resource equality same type and ptr" {
    var sentinel: u8 = 0;
    var r1 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    var r2 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expect(val1.eql(val2));
}

test "resource inequality different ptr" {
    var s1: u8 = 0;
    var s2: u8 = 0;
    var r1 = Resource{ .type_name = "test", .ptr = @ptrCast(&s1) };
    var r2 = Resource{ .type_name = "test", .ptr = @ptrCast(&s2) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expect(!val1.eql(val2));
}

test "resource inequality different type name" {
    var sentinel: u8 = 0;
    var r1 = Resource{ .type_name = "type-a", .ptr = @ptrCast(&sentinel) };
    var r2 = Resource{ .type_name = "type-b", .ptr = @ptrCast(&sentinel) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expect(!val1.eql(val2));
}

test "resource hash consistent with equality" {
    var sentinel: u8 = 0;
    var r1 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    var r2 = Resource{ .type_name = "test", .ptr = @ptrCast(&sentinel) };
    const val1 = Value{ .resource = &r1 };
    const val2 = Value{ .resource = &r2 };
    try std.testing.expectEqual(val1.hashValue(), val2.hashValue());
}
