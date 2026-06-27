//! Freeze-time classification of module-private values for the AOT runtime
//! image. Walks `ctx.module_cache_value` and decides, per word, whether the
//! word's literal payload can be emitted as either:
//!
//! - the structural path, as a static C struct initializer; or
//! - the blob path, which has to round-trip through runtime relocation.
//!
//! This file produces no C output and doesn't mutate any context state.
//! Instead, it performs a read-only analysis that returns a manifest
//! describing the per-word path.
//!
//! The principal driver of the blob path is `TypeValue.descriptor`, which is
//! ia `HashTable` that can grow at runtime and resists static-layout.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Module = value_mod.Module;
const ModuleWord = value_mod.ModuleWord;
const Instruction = value_mod.Instruction;

const Context = @import("context.zig").Context;

/// Module names that the runtime loads independently of the image. The
/// startup loader does not need to, and must not, recreate entries for
/// these. Today the prelude lives in the dictionary and local frames, not
/// in `module_cache_value`, but a defensive skip here keeps the policy
/// reviewable in one place.
const skipped_module_names = [_][]const u8{
    "prelude",
};

/// Which serialization path a value or word will travel.
pub const ImagePath = enum {
    /// Expressable as a static C struct initializer with link-time-resolvable
    /// cross-references. No runtime allocation or relocation will be needed.
    structural,
    /// Requires runtime construction: the loader allocates, decodes, and
    /// patches cross-references after the prelude finishes loading.
    blob,
};

/// Why a value lands on the blob path. Used for diagnostic dump output and
/// to make codegen decisions explicit. `none` means the value is on the
/// structural path.
pub const BlobReason = enum {
    none,
    /// A bare `hash` literal. The reason name predates the mutable_map
    /// slot-table mechanism, when both hash and mutable_map shared this
    /// classification; the enum value is retained so diagnostic output
    /// stays stable for the hash case.
    mutable_map,
    /// A `vector`, `byte_array`, or `set` literal -- dynamically sized
    /// containers.
    dynamic_container,
    /// A `parameter` literal. The `default_quotation` is structural but
    /// the runtime binding state is not.
    parameter_runtime_state,
    /// A `bignum` literal. Arbitrary-precision integers carry heap state.
    bignum,
    /// A `template` literal. Template segments include slices that need
    /// runtime fixup.
    template,
    /// A Value variant that should not appear in `module.words` at all
    /// (e.g., `module`, `stream`, `task`). Surfaces as an invariant
    /// violation in the dump output but does not panic.
    unexpected_variant,
};

/// Worst-case combine: structural is the unit, blob dominates.
fn worse(a: ImagePath, b: ImagePath) ImagePath {
    if (a == .blob or b == .blob) return .blob;
    return .structural;
}

fn worseReason(a: BlobReason, b: BlobReason) BlobReason {
    // Prefer the more specific reason if either side has one.
    if (a == .none) return b;
    if (b == .none) return a;
    // Both non-none; first wins to keep diagnostic output deterministic.
    return a;
}

/// Result of classifying a single Value. Carries the path and, when
/// blob, the reason for downstream diagnostics.
pub const Classification = struct {
    path: ImagePath,
    reason: BlobReason = .none,

    pub const structural_unit: Classification = .{ .path = .structural };

    pub fn blobOf(reason: BlobReason) Classification {
        return .{ .path = .blob, .reason = reason };
    }

    fn combine(self: Classification, other: Classification) Classification {
        const p = worse(self.path, other.path);
        if (p == .structural) return Classification.structural_unit;
        return .{
            .path = .blob,
            .reason = worseReason(self.reason, other.reason),
        };
    }
};

/// Recursively classify a single Value. Pointer-typed children of
/// type-infrastructure structs (`VirtualType`, `StructType`) are treated
/// as link-time-resolvable: the pointer itself is the link target, and
/// the pointee classifies independently when emitted as its own
/// top-level value.
pub fn classifyValue(val: Value) Classification {
    return switch (val) {
        // Scalars and static-string variants: structural by construction.
        .fixnum, .float, .boolean, .unit => Classification.structural_unit,
        .string, .symbol, .doc_string => Classification.structural_unit,
        .marker, .stack_effect => Classification.structural_unit,
        // `struct_type` is a Value variant; `virtual_type` is not -- VirtualType
        // is only reached transitively as a `tagged.tag` and is treated as a
        // link-resolvable pointer when tagged is structural.
        .struct_type => Classification.structural_unit,

        .array => |elems| blk: {
            var acc = Classification.structural_unit;
            for (elems) |elem| {
                acc = acc.combine(classifyValue(elem));
            }
            break :blk acc;
        },

        .quotation => |q| classifyInstructions(q.instructions),

        .tagged => |t| classifyValue(t.inner.*),

        // `type_val` is routed structurally via the static C data path
        // emitted by `aot_image_emit.emitTypeValueData`. Each TypeValue's
        // descriptor renders as a C struct initializer with slot-indexed
        // cross-references resolved by the loader.
        .type_val => Classification.structural_unit,

        // Blob path: leaf reasons.
        .hash => Classification.blobOf(.mutable_map),
        // `mutable_map` is structural via the runtime image's mutable_map
        // slot table: each unique freeze-time pointer is allocated once
        // at load and shared by every push site that referenced it, so
        // identity matches the in-process AOT behavior.
        .mutable_map => Classification.structural_unit,
        // A mutable vector is structural via the runtime image's vector slot
        // table: it is allocated once at load and shared by every push site
        // that referenced it, so identity (and runtime mutation) matches the
        // in-process AOT behavior. Its elements classify independently and are
        // serialized into the slot's description; a vector holding a blob
        // element falls to blob and falls back, exactly like an `.array`.
        .vector => |v| blk: {
            var acc = Classification.structural_unit;
            for (v.list.items) |elem| {
                acc = acc.combine(classifyValue(elem));
            }
            break :blk acc;
        },
        .byte_array, .set => Classification.blobOf(.dynamic_container),
        .parameter => Classification.blobOf(.parameter_runtime_state),
        .bignum => Classification.blobOf(.bignum),
        .template => Classification.blobOf(.template),

        // A struct instance is structural: its `StructType` is a
        // link-resolvable reference carried by the struct-type slot table,
        // and its field values classify independently. An instance with a
        // blob field falls to blob, exactly like an `.array`.
        .struct_instance => |si| blk: {
            var acc = Classification.structural_unit;
            for (si.fields) |field| {
                acc = acc.combine(classifyValue(field));
            }
            break :blk acc;
        },

        // Out-of-scope variants. These should not appear in `module.words`
        // at freeze time -- finding one means either a freeze-time invariant
        // was violated or this list needs updating. Surface it as an
        // unexpected blob entry so the dump flag highlights it.
        .module,
        .stream,
        .resource,
        .benchmark_report,
        .error_value,
        .task,
        .channel,
        .iterator,
        .sandbox_spec,
        .type_descriptor,
        .protocol_descriptor,
        .constraint_combinator,
        => Classification.blobOf(.unexpected_variant),
    };
}

/// Walk an instruction stream and classify it. The result is structural
/// iff every `push_literal` operand classifies structural; `call_word`
/// operands are link-time symbols and never affect the path.
fn classifyInstructions(instrs: []const Instruction) Classification {
    var acc = Classification.structural_unit;
    for (instrs) |instr| {
        switch (instr.op) {
            .push_literal => |lit| acc = acc.combine(classifyValue(lit)),
            .call_word, .call_word_direct => {},
        }
    }
    return acc;
}

/// Classify a single ModuleWord. Returns null for actions that the image
/// does not need to materialize (`.native`, `.host_callback`); the runtime
/// resolver handles those independently.
pub fn classifyModuleWord(mw: ModuleWord) ?Classification {
    return switch (mw.action) {
        .native, .host_callback => null,
        .compound => |body| classifyInstructions(body),
    };
}

/// One entry in the runtime image: a single program-defined word with its
/// classification.
pub const ImageEntry = struct {
    module_name: []const u8,
    word_name: []const u8,
    path: ImagePath,
    /// `.none` when `path == .structural`; populated otherwise.
    blob_reason: BlobReason = .none,
};

/// The result of walking `ctx.module_cache_value`. Owns its `entries`
/// slice; callers must `deinit` after use. The string fields inside
/// `ImageEntry` reference the underlying Context-owned storage and do
/// not need separate ownership tracking.
pub const ImageManifest = struct {
    entries: []ImageEntry,
    structural_count: u32,
    blob_count: u32,
    total_count: u32,

    pub fn deinit(self: *ImageManifest, allocator: Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Walk every module in `ctx.module_cache_value`, skip the prelude,
/// classify each module-private word, and assemble a manifest. Returns
/// an empty manifest (zero-length entries, all counts zero) when no
/// non-prelude modules are loaded -- this is the normal case for trivial
/// programs that do not `use` anything.
pub fn buildImageManifest(ctx: *Context, allocator: Allocator) Allocator.Error!ImageManifest {
    var entries: std.ArrayListUnmanaged(ImageEntry) = .{};
    errdefer entries.deinit(allocator);

    var structural_count: u32 = 0;
    var blob_count: u32 = 0;

    // Collect modules first so the manifest is sorted deterministically by
    // module name. Hash-map iteration order is not stable across runs.
    var module_names: std.ArrayListUnmanaged([]const u8) = .{};
    defer module_names.deinit(allocator);
    var module_ptrs: std.ArrayListUnmanaged(*Module) = .{};
    defer module_ptrs.deinit(allocator);

    var cache_iter = ctx.module_cache_value.map.iterator();
    while (cache_iter.next()) |entry| {
        if (entry.value_ptr.* != .module) continue;
        const mod = entry.value_ptr.*.module;
        if (isSkippedModuleName(mod.name)) continue;
        try module_names.append(allocator, mod.name);
        try module_ptrs.append(allocator, mod);
    }

    sortStringsWithPtrs(module_names.items, module_ptrs.items);

    for (module_ptrs.items) |mod| {
        // Collect word names under this module deterministically too.
        var word_names: std.ArrayListUnmanaged([]const u8) = .{};
        defer word_names.deinit(allocator);

        var word_iter = mod.words.iterator();
        while (word_iter.next()) |word_entry| {
            try word_names.append(allocator, word_entry.key_ptr.*);
        }
        std.mem.sort([]const u8, word_names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (word_names.items) |word_name| {
            const mw = mod.words.get(word_name) orelse continue;
            const classification = classifyModuleWord(mw) orelse continue;
            try entries.append(allocator, .{
                .module_name = mod.name,
                .word_name = word_name,
                .path = classification.path,
                .blob_reason = classification.reason,
            });
            switch (classification.path) {
                .structural => structural_count += 1,
                .blob => blob_count += 1,
            }
        }
    }

    const owned = try entries.toOwnedSlice(allocator);
    return .{
        .entries = owned,
        .structural_count = structural_count,
        .blob_count = blob_count,
        .total_count = @intCast(owned.len),
    };
}

fn isSkippedModuleName(name: []const u8) bool {
    for (skipped_module_names) |skipped| {
        if (std.mem.eql(u8, name, skipped)) return true;
    }
    return false;
}

/// Sort `names` lexicographically, applying the same permutation to
/// `ptrs`. Both slices must have equal length.
fn sortStringsWithPtrs(names: [][]const u8, ptrs: []*Module) void {
    std.debug.assert(names.len == ptrs.len);
    // Insertion sort: module counts are tiny (typically <20).
    var i: usize = 1;
    while (i < names.len) : (i += 1) {
        var j: usize = i;
        while (j > 0 and std.mem.lessThan(u8, names[j], names[j - 1])) : (j -= 1) {
            std.mem.swap([]const u8, &names[j], &names[j - 1]);
            std.mem.swap(*Module, &ptrs[j], &ptrs[j - 1]);
        }
    }
}

/// Render a manifest in the format consumed by the
/// `--dump-aot-image-classification` flag. Output is deterministic: modules
/// sorted alphabetically, entries sorted alphabetically within each module,
/// counts pre-aggregated. Suitable for golden file comparison.
pub fn writeManifestDump(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    manifest: ImageManifest,
) Allocator.Error!void {
    try out.appendSlice(allocator, "image-manifest:\n");

    // Aggregate module count in a single pass since `entries` is already
    // sorted by module then word.
    var module_count: u32 = 0;
    {
        var i: usize = 0;
        while (i < manifest.entries.len) {
            module_count += 1;
            const m = manifest.entries[i].module_name;
            while (i < manifest.entries.len and std.mem.eql(u8, manifest.entries[i].module_name, m)) : (i += 1) {}
        }
    }

    var num_buf: [32]u8 = undefined;
    try out.appendSlice(allocator, "  modules: ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{module_count}) catch unreachable);
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "  total: ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{manifest.total_count}) catch unreachable);
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "  structural: ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{manifest.structural_count}) catch unreachable);
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "  blob: ");
    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{manifest.blob_count}) catch unreachable);
    try out.append(allocator, '\n');

    if (manifest.blob_count > 0) {
        try out.appendSlice(allocator, "  blob breakdown:\n");
        var counts = std.EnumArray(BlobReason, u32).initFill(0);
        for (manifest.entries) |e| {
            if (e.path == .blob) {
                counts.set(e.blob_reason, counts.get(e.blob_reason) + 1);
            }
        }
        inline for (@typeInfo(BlobReason).@"enum".fields) |field| {
            const reason: BlobReason = @field(BlobReason, field.name);
            if (reason != .none) {
                const count = counts.get(reason);
                if (count != 0) {
                    try out.appendSlice(allocator, "    ");
                    try out.appendSlice(allocator, blobReasonLabel(reason));
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch unreachable);
                    try out.append(allocator, '\n');
                }
            }
        }
    }

    try out.appendSlice(allocator, "  per-module:\n");
    {
        var i: usize = 0;
        while (i < manifest.entries.len) {
            const mod_name = manifest.entries[i].module_name;
            var mod_struct: u32 = 0;
            var mod_blob: u32 = 0;
            const start = i;
            while (i < manifest.entries.len and std.mem.eql(u8, manifest.entries[i].module_name, mod_name)) : (i += 1) {
                switch (manifest.entries[i].path) {
                    .structural => mod_struct += 1,
                    .blob => mod_blob += 1,
                }
            }
            try out.appendSlice(allocator, "    ");
            try out.appendSlice(allocator, mod_name);
            try out.appendSlice(allocator, ": structural=");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{mod_struct}) catch unreachable);
            try out.appendSlice(allocator, " blob=");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{mod_blob}) catch unreachable);
            try out.appendSlice(allocator, " total=");
            try out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{@as(u32, @intCast(i - start))}) catch unreachable);
            try out.append(allocator, '\n');
        }
    }

    if (manifest.blob_count > 0) {
        try out.appendSlice(allocator, "  blob entries:\n");
        for (manifest.entries) |e| {
            if (e.path != .blob) continue;
            try out.appendSlice(allocator, "    ");
            try out.appendSlice(allocator, e.module_name);
            try out.append(allocator, '.');
            try out.appendSlice(allocator, e.word_name);
            try out.appendSlice(allocator, " (");
            try out.appendSlice(allocator, blobReasonLabel(e.blob_reason));
            try out.appendSlice(allocator, ")\n");
        }
    }
}

fn blobReasonLabel(reason: BlobReason) []const u8 {
    return switch (reason) {
        .none => "none",
        .mutable_map => "mutable-map literal",
        .dynamic_container => "dynamic container",
        .parameter_runtime_state => "parameter runtime state",
        .bignum => "bignum literal",
        .template => "template literal",
        .unexpected_variant => "unexpected variant",
    };
}

// -- Tests --------------------------------------------------------------

const testing = std.testing;

test "classifyValue: scalars and static-string variants are structural" {
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .fixnum = 42 }).path);
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .float = 1.5 }).path);
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .boolean = true }).path);
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .unit = {} }).path);
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .string = "hi" }).path);
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .symbol = "foo" }).path);
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .doc_string = "doc" }).path);
}

test "classifyValue: stack-effect is structural" {
    const stack_effect_mod = @import("stack_effect.zig");
    const effect = stack_effect_mod.StackEffect{ .inputs = &.{}, .outputs = &.{} };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .stack_effect = effect }).path);
}

test "classifyValue: marker is structural" {
    var marker = value_mod.Marker{ .name = "test-marker" };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .marker = &marker }).path);
}

test "classifyValue: array of structurals is structural" {
    const elems = [_]Value{
        .{ .fixnum = 1 },
        .{ .symbol = "two" },
        .{ .boolean = false },
    };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .array = &elems }).path);
}

test "classifyValue: array of structural values is structural" {
    var desc = value_mod.TypeDescriptor{ .kind = .{ .builtin = {} } };
    var tv = value_mod.TypeValue{ .name = "t", .descriptor = &desc };
    const elems = [_]Value{
        .{ .fixnum = 1 },
        .{ .type_val = &tv },
    };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .array = &elems }).path);
}

test "classifyValue: type_val is structural via the static C data path" {
    var desc = value_mod.TypeDescriptor{ .kind = .{ .builtin = {} } };
    var tv = value_mod.TypeValue{ .name = "color", .descriptor = &desc };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .type_val = &tv }).path);
}

test "classifyValue: tagged with structural inner is structural" {
    var virt = value_mod.VirtualType{ .name = "stdio-mode", .inner_type = "symbol" };
    const inner: Value = .{ .symbol = "inherit" };
    const c = classifyValue(.{ .tagged = .{ .tag = &virt, .inner = &inner } });
    try testing.expectEqual(ImagePath.structural, c.path);
}

test "classifyValue: tagged wrapping a type_val is structural" {
    var virt = value_mod.VirtualType{ .name = "wrapper", .inner_type = "type" };
    var desc = value_mod.TypeDescriptor{ .kind = .{ .builtin = {} } };
    var tv = value_mod.TypeValue{ .name = "inner-type", .descriptor = &desc };
    const inner: Value = .{ .type_val = &tv };
    const c = classifyValue(.{ .tagged = .{ .tag = &virt, .inner = &inner } });
    try testing.expectEqual(ImagePath.structural, c.path);
}

test "classifyValue: empty quotation is structural" {
    const q = value_mod.Quotation{ .instructions = &.{} };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .quotation = q }).path);
}

test "classifyValue: quotation with only call_word and structural literals is structural" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
        .{ .op = .{ .call_word = "+" }, .line = 0, .column = 0 },
    };
    const q = value_mod.Quotation{ .instructions = &instrs };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .quotation = q }).path);
}

test "classifyValue: quotation with type_val literal is structural" {
    var desc = value_mod.TypeDescriptor{ .kind = .{ .builtin = {} } };
    var tv = value_mod.TypeValue{ .name = "t", .descriptor = &desc };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 0, .column = 0 },
    };
    const q = value_mod.Quotation{ .instructions = &instrs };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .quotation = q }).path);
}

test "classifyValue: quotation with blob literal is blob" {
    var ht = value_mod.HashTable{};
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .hash = &ht } }, .line = 0, .column = 0 },
    };
    const q = value_mod.Quotation{ .instructions = &instrs };
    try testing.expectEqual(ImagePath.blob, classifyValue(.{ .quotation = q }).path);
}

test "classifyValue: hash is blob; mutable_map and empty vector are structural" {
    var ht = value_mod.HashTable{};
    try testing.expectEqual(ImagePath.blob, classifyValue(.{ .hash = &ht }).path);
    try testing.expectEqual(BlobReason.mutable_map, classifyValue(.{ .hash = &ht }).reason);

    const mm = try value_mod.MutableMap.create(testing.allocator);
    defer mm.header.release();
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .mutable_map = mm }).path);

    // A vector is structural via the vector slot table; its elements classify
    // independently.
    const vec = try value_mod.Vector.create(testing.allocator);
    defer vec.header.release();
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .vector = vec }).path);
}

test "classifyValue: parameter is blob" {
    var param = value_mod.Parameter{
        .name = "p",
        .default_quotation = .{ .instructions = &.{} },
    };
    const c = classifyValue(.{ .parameter = &param });
    try testing.expectEqual(ImagePath.blob, c.path);
    try testing.expectEqual(BlobReason.parameter_runtime_state, c.reason);
}

test "classifyValue: struct_type is structural" {
    var st = value_mod.StructType{ .name = "point", .fields = &.{ "x", "y" } };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .struct_type = &st }).path);
}

test "classifyValue: struct_instance with structural fields is structural" {
    var st = value_mod.StructType{ .name = "rec", .fields = &.{ "a", "b" } };
    var fields = [_]Value{ .{ .fixnum = 1 }, .{ .symbol = "two" } };
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .struct_instance = &si }).path);
}

test "classifyValue: struct_instance with a blob field is blob" {
    var st = value_mod.StructType{ .name = "rec", .fields = &.{"a"} };
    var ht = value_mod.HashTable{};
    var fields = [_]Value{.{ .hash = &ht }};
    var si = value_mod.StructInstance{ .struct_type = &st, .fields = &fields };
    const c = classifyValue(.{ .struct_instance = &si });
    try testing.expectEqual(ImagePath.blob, c.path);
}

test "classifyValue: empty vector is structural" {
    var vec = value_mod.Vector{ .header = undefined, .list = .{} };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .vector = &vec }).path);
}

test "classifyValue: populated vector with structural elements is structural" {
    var elems = [_]Value{ .{ .fixnum = 1 }, .{ .symbol = "two" } };
    var vec = value_mod.Vector{ .header = undefined, .list = .{ .items = &elems, .capacity = elems.len } };
    try testing.expectEqual(ImagePath.structural, classifyValue(.{ .vector = &vec }).path);
}

test "classifyValue: vector with a blob element is blob" {
    var ht = value_mod.HashTable{};
    var elems = [_]Value{.{ .hash = &ht }};
    var vec = value_mod.Vector{ .header = undefined, .list = .{ .items = &elems, .capacity = elems.len } };
    const c = classifyValue(.{ .vector = &vec });
    try testing.expectEqual(ImagePath.blob, c.path);
    try testing.expectEqual(BlobReason.mutable_map, c.reason);
}

test "classifyModuleWord: native and host_callback return null" {
    const mw_native = ModuleWord{
        .action = .{ .native = struct {
            fn f(_: *Context) anyerror!void {}
        }.f },
    };
    try testing.expect(classifyModuleWord(mw_native) == null);
}

test "classifyModuleWord: compound with structural body is structural" {
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    };
    const mw = ModuleWord{ .action = .{ .compound = &instrs } };
    const c = classifyModuleWord(mw) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(ImagePath.structural, c.path);
}

test "classifyModuleWord: compound containing a type_val literal is structural" {
    var desc = value_mod.TypeDescriptor{ .kind = .{ .builtin = {} } };
    var tv = value_mod.TypeValue{ .name = "t", .descriptor = &desc };
    const instrs = [_]Instruction{
        .{ .op = .{ .push_literal = .{ .type_val = &tv } }, .line = 0, .column = 0 },
    };
    const mw = ModuleWord{ .action = .{ .compound = &instrs } };
    const c = classifyModuleWord(mw) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(ImagePath.structural, c.path);
}

test "buildImageManifest: empty cache yields empty manifest" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    var manifest = try buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), manifest.total_count);
    try testing.expectEqual(@as(u32, 0), manifest.structural_count);
    try testing.expectEqual(@as(u32, 0), manifest.blob_count);
}

test "buildImageManifest: synthetic modules produce sorted, classified entries" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    // Synthetic compound bodies. The instruction slices must outlive the
    // manifest call; arena allocation guarantees that within this test.
    const struct_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    });

    // A bare hash literal forces the blob path: dynamic-container
    // contents carry heap state that no static initializer can express.
    const blob_ht_ptr = try arena.create(value_mod.HashTable);
    blob_ht_ptr.* = .{};
    const blob_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .hash = blob_ht_ptr } }, .line = 0, .column = 0 },
    });

    // Module "zeta" -- comes second alphabetically, both words structural.
    const zeta = try arena.create(Module);
    zeta.* = .{ .name = "zeta", .words = .{} };
    try zeta.words.put(arena, "alpha", .{ .action = .{ .compound = struct_instrs } });
    try zeta.words.put(arena, "beta", .{ .action = .{ .compound = struct_instrs } });

    // Module "alpha" -- comes first alphabetically; one structural, one blob.
    const alpha = try arena.create(Module);
    alpha.* = .{ .name = "alpha", .words = .{} };
    try alpha.words.put(arena, "good", .{ .action = .{ .compound = struct_instrs } });
    try alpha.words.put(arena, "needs-blob", .{ .action = .{ .compound = blob_instrs } });
    // A native -- must be skipped.
    try alpha.words.put(arena, "skip-me", .{ .action = .{ .native = struct {
        fn f(_: *Context) anyerror!void {}
    }.f } });

    const cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(cache_alloc, try cache_alloc.dupe(u8, "zeta"), .{ .module = zeta });
    try ctx.module_cache_value.map.put(cache_alloc, try cache_alloc.dupe(u8, "alpha"), .{ .module = alpha });

    var manifest = try buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 4), manifest.total_count);
    try testing.expectEqual(@as(u32, 3), manifest.structural_count);
    try testing.expectEqual(@as(u32, 1), manifest.blob_count);

    // Modules sorted alphabetically; words sorted within each module.
    try testing.expectEqualStrings("alpha", manifest.entries[0].module_name);
    try testing.expectEqualStrings("good", manifest.entries[0].word_name);
    try testing.expectEqual(ImagePath.structural, manifest.entries[0].path);

    try testing.expectEqualStrings("alpha", manifest.entries[1].module_name);
    try testing.expectEqualStrings("needs-blob", manifest.entries[1].word_name);
    try testing.expectEqual(ImagePath.blob, manifest.entries[1].path);
    try testing.expectEqual(BlobReason.mutable_map, manifest.entries[1].blob_reason);

    try testing.expectEqualStrings("zeta", manifest.entries[2].module_name);
    try testing.expectEqualStrings("alpha", manifest.entries[2].word_name);
    try testing.expectEqualStrings("zeta", manifest.entries[3].module_name);
    try testing.expectEqualStrings("beta", manifest.entries[3].word_name);
}

test "buildImageManifest: skipped modules are excluded" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 0, .column = 0 },
    });

    const prelude_mod = try arena.create(Module);
    prelude_mod.* = .{ .name = "prelude", .words = .{} };
    try prelude_mod.words.put(arena, "should-not-appear", .{ .action = .{ .compound = instrs } });

    const prelude_cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(prelude_cache_alloc, try prelude_cache_alloc.dupe(u8, "prelude"), .{ .module = prelude_mod });

    var manifest = try buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), manifest.total_count);
}

test "writeManifestDump: deterministic output" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const arena = ctx.quotationAllocator();

    const struct_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 7 } }, .line = 0, .column = 0 },
    });
    const blob_ht_ptr = try arena.create(value_mod.HashTable);
    blob_ht_ptr.* = .{};
    const blob_instrs = try arena.dupe(Instruction, &.{
        .{ .op = .{ .push_literal = .{ .hash = blob_ht_ptr } }, .line = 0, .column = 0 },
    });

    const m = try arena.create(Module);
    m.* = .{ .name = "demo", .words = .{} };
    try m.words.put(arena, "ok", .{ .action = .{ .compound = struct_instrs } });
    try m.words.put(arena, "needs-blob", .{ .action = .{ .compound = blob_instrs } });
    const demo_cache_alloc = ctx.module_cache_value.header.allocator;
    try ctx.module_cache_value.map.put(demo_cache_alloc, try demo_cache_alloc.dupe(u8, "demo"), .{ .module = m });

    var manifest = try buildImageManifest(&ctx, testing.allocator);
    defer manifest.deinit(testing.allocator);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);
    try writeManifestDump(&buf, testing.allocator, manifest);

    const expected =
        "image-manifest:\n" ++
        "  modules: 1\n" ++
        "  total: 2\n" ++
        "  structural: 1\n" ++
        "  blob: 1\n" ++
        "  blob breakdown:\n" ++
        "    mutable-map literal: 1\n" ++
        "  per-module:\n" ++
        "    demo: structural=1 blob=1 total=2\n" ++
        "  blob entries:\n" ++
        "    demo.needs-blob (mutable-map literal)\n";

    try testing.expectEqualStrings(expected, buf.items);
}
