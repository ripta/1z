const std = @import("std");
const scheduler_mod = @import("../scheduler.zig");
const Callable = @import("../callable.zig").Callable;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const CapturedScope = context_mod.CapturedScope;
const LocalFrame = context_mod.LocalFrame;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const Instruction = value_mod.Instruction;
const HashTable = value_mod.HashTable;
const Closure = value_mod.Closure;
const Segment = value_mod.Segment;
const benchmark_mod = @import("../benchmark.zig");
const BenchmarkStats = benchmark_mod.BenchmarkStats;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const StackEffect = @import("../stack_effect.zig").StackEffect;
const container_backing = @import("../container_backing.zig");

const popQuotation = helpers.popQuotation;
const popFixnum = helpers.popFixnum;

pub const primitives = [_]Primitive{
    .{ .name = "curry", .stack_effect = "x quot -- quot'", .doc = "Partially apply a value to a quotation.", .func = nativeCurry },
    .{ .name = "compose", .stack_effect = "quot1 quot2 -- quot'", .doc = "Concatenate two quotations into one.", .func = nativeCompose },
    .{ .name = "(benchmark-n)", .stack_effect = "n quot -- hash", .doc = "Run quot n times in one timing window; return the raw timing hash.", .func = nativeBenchmarkNRaw },
};

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "attach-stack-effect", .func = nativeAttachStackEffect, .stack_effect = "quot stack-effect -- quot'" },
};

/// The callable instruction body of a quotation or closure, or null for a
/// non-callable value.
fn callableInstrs(val: Value) ?[]const Instruction {
    return switch (val) {
        .quotation => |q| q.instructions,
        .closure => |c| c.instructions,
        else => null,
    };
}

/// A base callable's segments plus whether the slice is a fresh allocation the
/// caller must free after copying it into the derived closure's own segments.
const SegmentsView = struct {
    segs: []const Segment,
    owned: bool,
};

/// Decompose a callable into closure segments when every base it covers is
/// already compiled (has a `code_ptr`), or null otherwise. A plain compiled
/// quotation is a single capture-free segment, freshly allocated and owned by
/// the caller; a closure's own segments are returned aliased, kept alive by
/// the base reference the caller retains. The captures borrow the constituent
/// values -- the owning references live in the closure's `instructions` -- and
/// `jitCallClosure` retains each capture when it pushes it.
fn segmentsOf(alloc: std.mem.Allocator, val: Value) !?SegmentsView {
    return switch (val) {
        .quotation => |q| if (q.code_ptr) |cp| blk: {
            const segs = try alloc.alloc(Segment, 1);
            segs[0] = .{ .captures = &.{}, .base_code_ptr = cp };
            break :blk .{ .segs = segs, .owned = true };
        } else null,
        // A scope-carrying closure over an uncompiled base has empty segments -- it is compiled in
        // no sense, so treat it like an uncompiled quotation and take the interpreter branch.
        .closure => |c| if (c.segments.len == 0) null else .{ .segs = c.segments, .owned = false },
        else => null,
    };
}

/// A base callable's carried scope plus whether it is a fresh copy the derived
/// closure takes ownership of, as opposed to an alias into a retained base.
const ScopeView = struct {
    scope: ?*const CapturedScope = null,
    owned: bool = false,
};

/// The lexical scope a base callable closes over, if any. A closure carries it on the value; a
/// plain quotation's scope lives in the capture side map, looked up here in this context and, for a
/// quotation created in an ancestor task, up the parent chain. `curry`/`compose` embed the result
/// onto the closure they build so it rides the value across spawn boundaries.
///
/// A closure's own `captured_scope` is returned aliased and not owned: the derived closure keeps
/// the base alive through its retained `bases` reference. A plain quotation's scope, if any, still
/// lives in the refcounted capture map, so `findCapturedScopeForBody` returns a fresh,
/// independently-owned copy on `alloc` rather than a shared pointer into it -- see
/// `Context.promoteToClosure`'s doc comment for why that copy is load-bearing.
fn baseCapturedScope(ctx: *Context, alloc: std.mem.Allocator, val: Value) !ScopeView {
    return switch (val) {
        .closure => |c| .{ .scope = c.captured_scope, .owned = false },
        .quotation => |q| blk: {
            const scope = try ctx.findCapturedScopeForBody(alloc, @intFromPtr(q.instructions.ptr));
            break :blk .{ .scope = scope, .owned = scope != null };
        },
        else => .{},
    };
}

/// The module a base callable's body was written in, for the derived closure to carry.
///
/// A `curry`/`compose` product allocates a fresh body, so nothing keyed by that body's address
/// can answer for it. Reading the base's module here and putting it on the value is what lets
/// the product resolve a bare word against the module its code came from, in whatever context
/// later runs it.
///
/// A closure that already carries one answers from the value. Otherwise the base body is
/// probed, this context's map first and then the shared stamp store. That probe is what covers
/// a push-time promotion, whose own field is null because it aliases a module literal rather
/// than allocating a body.
fn baseDefiningModule(ctx: *Context, val: Value) ?*const value_mod.Module {
    if (val == .closure) {
        if (val.closure.defining_module) |m| return m;
    }

    const instrs = callableInstrs(val) orelse return null;
    const key = @intFromPtr(instrs.ptr);
    if (ctx.quotation_scope_info.get(key)) |info| {
        if (info.defining_module) |m| return m;
    }
    return ctx.quotation_stamp_store.lookup(key);
}

/// Deep-copy the concatenation of two source scopes onto `alloc`, `a`'s frames before `b`'s.
/// `compose` runs `instrs1` then `instrs2`, so a name bound in both resolves to `b`'s binding,
/// matching `lookupInCapturedScope`'s most-recent-first walk. Only reached when both bases carry a
/// scope; the single-source case shares the base's scope with no copy.
fn mergeCapturedScopes(alloc: std.mem.Allocator, a: *const CapturedScope, b: *const CapturedScope) !*CapturedScope {
    const a_frames = a.lexical_frames;
    const b_frames = b.lexical_frames;

    const frames = try alloc.alloc(LocalFrame, a_frames.len + b_frames.len);
    var built: usize = 0;
    errdefer {
        for (frames[0..built]) |*f| {
            context_mod.releaseFrameBindings(f);
            f.deinit(alloc);
        }
        alloc.free(frames);
    }

    for ([_][]const LocalFrame{ a_frames, b_frames }) |group| {
        for (group) |*sf| {
            var clone: LocalFrame = .{};
            errdefer clone.deinit(alloc);
            var it = sf.iterator();
            while (it.next()) |e| try clone.put(alloc, e.key_ptr.*, e.value_ptr.*);
            context_mod.retainFrameBindings(&clone);
            frames[built] = clone;
            built += 1;
        }
    }

    // Concatenate both bases' ambient-deps snapshots. A module reachable from either source stays
    // reachable from the composed closure; duplicates are harmless to membership resolution.
    const deps = try alloc.alloc(*const value_mod.Module, a.deps_modules.len + b.deps_modules.len);
    errdefer alloc.free(deps);
    @memcpy(deps[0..a.deps_modules.len], a.deps_modules);
    @memcpy(deps[a.deps_modules.len..], b.deps_modules);

    const scope = try alloc.create(CapturedScope);
    scope.* = .{ .lexical_frames = frames, .deps_modules = deps, .allocator = alloc };
    return scope;
}

/// Build a deps-only scope carrying the base bodies' ambient-deps snapshot, so a module-private
/// word called inside a curried/composed body still resolves against its own module's deps frame
/// under the `.module_deps` visibility filter -- in whatever context later runs the closure, since
/// the scope rides the value. Returns null when neither the bases' recorded scopes nor the live
/// frames contribute any deps. The caller owns the returned scope.
///
/// Only called when `baseCapturedScope` carried nothing: a base with a genuine lexical scope
/// already carries its own `deps_modules` on that scope.
///
/// The base-scope probe reads this context's own map only, with no ancestor walk. `curry` runs
/// where the base was pushed, so its deps are in this context's map; the `appendLiveDepsModules`
/// fallback below covers a base pushed by compiled code. The one uncovered shape -- a base created
/// in a parent under a live deps frame, passed to a child, and curried in the child where that
/// frame is not live -- falls back to the child's live frames and can under-propagate the parent's
/// captured deps. Its worst case is a fail-loud `UnknownWord` for that pattern, never a wrong
/// resolution.
fn makeDepsOnlyScope(ctx: *Context, alloc: std.mem.Allocator, bases: []const []const Instruction) !?*CapturedScope {
    var deps: std.ArrayListUnmanaged(*const value_mod.Module) = .{};
    defer deps.deinit(ctx.allocator);
    for (bases) |base| {
        if (ctx.quotation_scope_info.get(@intFromPtr(base.ptr))) |info| {
            if (info.scope) |s| {
                for (s.deps_modules) |m| try deps.append(ctx.allocator, m);
            }
        }
    }

    // A base pushed by compiled code never ran `captureQuotationScope`, so it recorded no deps. Fall
    // back to the frames live at curry time: curry runs where the base was pushed, so those are the
    // module frames the curried body will resolve against.
    if (deps.items.len == 0) try ctx.appendLiveDepsModules(&deps, ctx.allocator);
    if (deps.items.len == 0) return null;

    const deps_copy = try alloc.dupe(*const value_mod.Module, deps.items);
    errdefer alloc.free(deps_copy);
    const scope = try alloc.create(CapturedScope);
    scope.* = .{ .lexical_frames = &.{}, .deps_modules = deps_copy, .allocator = alloc };
    return scope;
}

/// curry ( x quot -- quot' )
/// Example: 5 [ + ] curry creates [ 5 + ]
///
/// The result is always a closure that owns its fresh instruction body, so a
/// dropped curry product is reclaimed at the drop. When the base is already
/// compiled, the closure also carries the base's `code_ptr` and `x` as a
/// captured prefix, so it is callable in an interpreter-free AOT binary
/// (push-then-call); otherwise `segments` is empty and the interpreter runs
/// the body.
pub fn nativeCurry(ctx: *Context) anyerror!void {
    const quot_val = try ctx.stack.pop();
    const base_instrs = callableInstrs(quot_val) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", quot_val);
        container_backing.releaseValue(quot_val);
        return error.TypeMismatch;
    };
    const x = ctx.stack.pop() catch |err| {
        container_backing.releaseValue(quot_val);
        return err;
    };

    // Every errdefer below disarms once the closure exists: from that point the closure owns
    // each piece, and a push failure releases the closure itself.
    const alloc = ctx.allocator;
    var built = false;
    errdefer if (!built) container_backing.releaseValue(quot_val);

    const new_instrs = alloc.alloc(Instruction, 1 + base_instrs.len) catch |err| {
        container_backing.releaseValue(x);
        return err;
    };

    // First instruction: push the value x.
    // x came from a pop (transfer); embedding here is also a transfer,
    // no retain needed.
    new_instrs[0] = .{ .op = .{ .push_literal = x }, .line = 0 };

    // Copy original quotation instructions. Container literals shared with the
    // source quotation gain a second owner under the new body, so retain each;
    // the closure's destroy releases them when the body is dropped.
    @memcpy(new_instrs[1..], base_instrs);
    container_backing.retainInstructionsContainerLiterals(new_instrs[1..]);
    errdefer if (!built) {
        container_backing.releaseInstructionsContainerLiterals(new_instrs);
        alloc.free(new_instrs);
    };

    // Carry the base's captured lexical scope onto the new body so a curried closure resolves its
    // bare words at its creation site wherever it later runs. A scope-less base still contributes
    // its ambient deps as an owned deps-only scope, and the executing context's map is stamped too,
    // so a `;`-adopted word body that runs without a pop resolves the same way.
    var carried = try baseCapturedScope(ctx, alloc, quot_val);
    errdefer if (!built and carried.owned) @constCast(carried.scope.?).release();

    if (carried.scope == null) {
        if (try makeDepsOnlyScope(ctx, alloc, &.{base_instrs})) |scope| {
            carried = .{ .scope = scope, .owned = true };
            try ctx.stampCapturedScopeForExecution(new_instrs, scope);
        }
    }

    // Curried quotation has no effect - effect validation happens at parameter attachment time
    const segments: []const Segment = if (try segmentsOf(alloc, quot_val)) |sv| blk: {
        defer if (sv.owned) alloc.free(sv.segs);
        break :blk try prependCapture(alloc, sv.segs, x);
    } else &.{};
    errdefer if (!built) {
        for (segments) |seg| alloc.free(seg.captures);
        alloc.free(segments);
    };

    // A closure base's popped reference transfers into `bases`, keeping the aliased captures and
    // scope alive for this closure's lifetime.
    const bases: []const *Closure = if (quot_val == .closure) blk: {
        const b = try alloc.alloc(*Closure, 1);
        b[0] = quot_val.closure;
        break :blk b;
    } else &.{};
    errdefer if (!built) alloc.free(bases);

    const cl = try Closure.create(alloc, .{
        .instructions = new_instrs,
        .effect = null,
        .segments = segments,
        .captured_scope = carried.scope,
        .defining_module = baseDefiningModule(ctx, quot_val),
        .header = undefined,
        .owns_body = true,
        .owns_segments = true,
        .owns_scope = carried.owned,
        .bases = bases,
    });
    built = true;
    try helpers.pushMovedValue(ctx, .{ .closure = cl });
}

/// Prepend a captured value to the first segment of a closure body. The first
/// base runs after `x` and the segment's existing captures are on the stack.
/// Every captures slice in the result is a fresh allocation, so the derived
/// closure owns its segments uniformly; the capture values stay borrows.
fn prependCapture(alloc: std.mem.Allocator, segs: []const Segment, x: Value) ![]const Segment {
    const new_segs = try alloc.alloc(Segment, segs.len);
    var built: usize = 0;
    errdefer {
        for (new_segs[0..built]) |seg| alloc.free(seg.captures);
        alloc.free(new_segs);
    }

    const first = segs[0];
    const new_caps = try alloc.alloc(Value, 1 + first.captures.len);
    new_caps[0] = x;
    @memcpy(new_caps[1..], first.captures);
    new_segs[0] = .{ .captures = new_caps, .base_code_ptr = first.base_code_ptr };
    built = 1;

    for (segs[1..], 1..) |seg, i| {
        new_segs[i] = .{ .captures = try alloc.dupe(Value, seg.captures), .base_code_ptr = seg.base_code_ptr };
        built = i + 1;
    }
    return new_segs;
}

/// compose ( quot1 quot2 -- quot' )
/// Example: [ 2 * ] [ 3 + ] compose creates [ 2 * 3 + ]
///
/// The result is always a closure that owns its fresh instruction body, so a
/// dropped compose product is reclaimed at the drop. When both bases are
/// compiled, the closure's segments are the two bases' segments in order,
/// callable interpreter-free; otherwise `segments` is empty and the
/// interpreter runs the body.
pub fn nativeCompose(ctx: *Context) anyerror!void {
    const quot2_val = try ctx.stack.pop();
    const instrs2 = callableInstrs(quot2_val) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", quot2_val);
        container_backing.releaseValue(quot2_val);
        return error.TypeMismatch;
    };
    const quot1_val = ctx.stack.pop() catch |err| {
        container_backing.releaseValue(quot2_val);
        return err;
    };
    const instrs1 = callableInstrs(quot1_val) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", quot1_val);
        container_backing.releaseValue(quot1_val);
        container_backing.releaseValue(quot2_val);
        return error.TypeMismatch;
    };

    // Every errdefer below disarms once the closure exists: from that point the closure owns
    // each piece, and a push failure releases the closure itself.
    const alloc = ctx.allocator;
    var built = false;
    errdefer if (!built) {
        container_backing.releaseValue(quot1_val);
        container_backing.releaseValue(quot2_val);
    };

    const new_instrs = try alloc.alloc(Instruction, instrs1.len + instrs2.len);

    // Copy quot1 then quot2; container literals shared with the source
    // quotations gain a second owner under the new body, so retain each; the
    // closure's destroy releases them when the body is dropped.
    @memcpy(new_instrs[0..instrs1.len], instrs1);
    @memcpy(new_instrs[instrs1.len..], instrs2);
    container_backing.retainInstructionsContainerLiterals(new_instrs);
    errdefer if (!built) {
        container_backing.releaseInstructionsContainerLiterals(new_instrs);
        alloc.free(new_instrs);
    };

    // Carry the bases' captured lexical scopes onto the composed body. A single source is carried
    // as-is; two are merged into one fresh scope, `quot1`'s frames before `quot2`'s, and a merged
    // input the composing side owned is released once the merge subsumes it.
    var sa = try baseCapturedScope(ctx, alloc, quot1_val);
    errdefer if (!built and sa.owned) @constCast(sa.scope.?).release();
    var sb = try baseCapturedScope(ctx, alloc, quot2_val);
    errdefer if (!built and sb.owned) @constCast(sb.scope.?).release();

    var carried: ?*const CapturedScope = null;
    var carried_owned = false;
    if (sa.scope != null and sb.scope != null) {
        carried = try mergeCapturedScopes(alloc, sa.scope.?, sb.scope.?);
        carried_owned = true;
        if (sa.owned) {
            @constCast(sa.scope.?).release();
            sa.owned = false;
        }
        if (sb.owned) {
            @constCast(sb.scope.?).release();
            sb.owned = false;
        }
    } else if (sa.scope != null) {
        carried = sa.scope;
        carried_owned = sa.owned;
        sa.owned = false;
    } else if (sb.scope != null) {
        carried = sb.scope;
        carried_owned = sb.owned;
        sb.owned = false;
    }
    errdefer if (!built and carried_owned) @constCast(carried.?).release();

    if (carried == null) {
        if (try makeDepsOnlyScope(ctx, alloc, &.{ instrs1, instrs2 })) |scope| {
            carried = scope;
            carried_owned = true;
            try ctx.stampCapturedScopeForExecution(new_instrs, scope);
        }
    }

    // Composed quotation has no effect - effect validation happens at parameter attachment time
    const s1 = try segmentsOf(alloc, quot1_val);
    defer if (s1) |sv| if (sv.owned) alloc.free(sv.segs);
    const s2 = try segmentsOf(alloc, quot2_val);
    defer if (s2) |sv| if (sv.owned) alloc.free(sv.segs);

    const segments: []const Segment = if (s1 != null and s2 != null) blk: {
        const new_segments = try alloc.alloc(Segment, s1.?.segs.len + s2.?.segs.len);
        var seg_built: usize = 0;
        errdefer {
            for (new_segments[0..seg_built]) |seg| alloc.free(seg.captures);
            alloc.free(new_segments);
        }
        for (s1.?.segs, 0..) |seg, i| {
            new_segments[i] = .{ .captures = try alloc.dupe(Value, seg.captures), .base_code_ptr = seg.base_code_ptr };
            seg_built = i + 1;
        }
        for (s2.?.segs, 0..) |seg, j| {
            new_segments[s1.?.segs.len + j] = .{ .captures = try alloc.dupe(Value, seg.captures), .base_code_ptr = seg.base_code_ptr };
            seg_built = s1.?.segs.len + j + 1;
        }
        break :blk new_segments;
    } else &.{};
    errdefer if (!built) {
        for (segments) |seg| alloc.free(seg.captures);
        alloc.free(segments);
    };

    // A closure base's popped reference transfers into `bases`, keeping the aliased captures and
    // scope alive for this closure's lifetime.
    var base_count: usize = 0;
    if (quot1_val == .closure) base_count += 1;
    if (quot2_val == .closure) base_count += 1;
    const bases: []const *Closure = if (base_count > 0) blk: {
        const b = try alloc.alloc(*Closure, base_count);
        var i: usize = 0;
        if (quot1_val == .closure) {
            b[i] = quot1_val.closure;
            i += 1;
        }
        if (quot2_val == .closure) {
            b[i] = quot2_val.closure;
            i += 1;
        }
        break :blk b;
    } else &.{};
    errdefer if (!built) alloc.free(bases);

    // The composed body is two halves, so it carries a defining module only where both halves
    // agree on one. Taking `quot1`'s alone would show `quot2`'s half a module it was not written
    // in; the disagreeing case rides the `deps_modules` merged above instead.
    const module1 = baseDefiningModule(ctx, quot1_val);
    const module2 = baseDefiningModule(ctx, quot2_val);

    const cl = try Closure.create(alloc, .{
        .instructions = new_instrs,
        .effect = null,
        .segments = segments,
        .captured_scope = carried,
        .defining_module = if (module1 == module2) module1 else null,
        .header = undefined,
        .owns_body = true,
        .owns_segments = true,
        .owns_scope = carried_owned,
        .bases = bases,
    });
    built = true;
    try helpers.pushMovedValue(ctx, .{ .closure = cl });
}

/// attach-stack-effect ( quot stack-effect -- quot' )
///
/// The write direction of `quotation>effect`: returns the callable with the declared effect
/// attached, sharing instructions, segments, and captured scope with the input.
///
/// Runtime-built quotations carry no effect, because `curry` and `compose` cannot know the
/// new shape. A builder that does know it -- e.g. `ffi-def{` deriving one from an FFI
/// signature -- attaches it here, so consumers like `>module` see a declared effect.
fn nativeAttachStackEffect(ctx: *Context) anyerror!void {
    const eff_val = try ctx.stack.pop();
    const effect = switch (eff_val) {
        .stack_effect => |e| e,
        else => {
            helpers.setTypeMismatchError(ctx, "stack-effect", eff_val);
            container_backing.releaseValue(eff_val);
            return error.TypeMismatch;
        },
    };

    // Shallow copy, like `;` lifting a popped stack-effect into a word definition: the
    // effect's slices are owned by the quotation allocator and stack-effect values are not
    // refcounted, so the boxed copy shares them safely for the context's lifetime.
    const alloc = ctx.quotationAllocator();
    const eff_ptr = try alloc.create(StackEffect);
    eff_ptr.* = effect;

    const quot_val = try ctx.stack.pop();
    switch (quot_val) {
        .quotation => |q| {
            try ctx.stack.push(.{ .quotation = .{
                .instructions = q.instructions,
                .effect = eff_ptr,
                .code_ptr = q.code_ptr,
            } });
        },
        .closure => |c| {
            // The derived closure shares the source's body, segments, and scope, owning none
            // of them; the popped source reference transfers into `bases` so the shared
            // memory stays alive for the derived closure's lifetime.
            const bases = ctx.allocator.alloc(*Closure, 1) catch |err| {
                container_backing.releaseValue(quot_val);
                return err;
            };
            bases[0] = c;
            const cl = Closure.create(ctx.allocator, .{
                .instructions = c.instructions,
                .effect = eff_ptr,
                .segments = c.segments,
                .captured_scope = c.captured_scope,
                .defining_module = c.defining_module,
                .header = undefined,
                .bases = bases,
            }) catch |err| {
                ctx.allocator.free(bases);
                container_backing.releaseValue(quot_val);
                return err;
            };
            try helpers.pushMovedValue(ctx, .{ .closure = cl });
        },
        else => {
            helpers.setTypeMismatchError(ctx, "quotation", quot_val);
            container_backing.releaseValue(quot_val);
            return error.TypeMismatch;
        },
    }
}

/// Execute a quotation N times inside a single timing window.
fn executeBenchmarkN(ctx: *Context, callable: Callable, n: u64) !*HashTable {
    // Create temporary benchmark stats for this execution
    var local_stats = BenchmarkStats{};
    defer local_stats.deinit(ctx.allocator);

    // Save and replace context benchmark pointer
    const saved_benchmark = ctx.benchmark;
    ctx.benchmark = &local_stats;

    // Snapshot allocation counters from CLI-level stats (if --benchmark is active)
    const alloc_before: ?struct { allocs: usize, bytes: usize } = if (saved_benchmark) |sb|
        .{ .allocs = sb.total_allocations, .bytes = sb.total_bytes }
    else
        null;

    // Time and execute
    const start_time = scheduler_mod.elapsedTimerNowNs();
    var exec_result: anyerror!void = {};
    // A while loop with an explicit u64 counter, not `for (0..n)`: n is u64 (a fixnum count),
    // and `for` range bounds must fit usize, which is only 32 bits on wasm32.
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        exec_result = callable.executeWithFrame(ctx);
        if (exec_result) |_| {} else |_| break;
    }

    const end_time = scheduler_mod.elapsedTimerNowNs();
    const elapsed_ns = end_time - start_time;

    // Compute allocation deltas before restoring benchmark pointer
    const alloc_delta: ?struct { allocs: usize, bytes: usize } = if (saved_benchmark) |sb|
        if (alloc_before) |before|
            .{ .allocs = sb.total_allocations - before.allocs, .bytes = sb.total_bytes - before.bytes }
        else
            null
    else
        null;

    // Restore original benchmark pointer
    ctx.benchmark = saved_benchmark;

    // Propagate execution error after restoring state
    try exec_result;

    // Build result hash
    const hash = HashTable.create(ctx.allocator) catch return error.OutOfMemory;
    errdefer hash.header.release();
    const hash_alloc = hash.header.allocator;

    const key1 = hash_alloc.dupe(u8, "elapsed_ns") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key1, .{ .fixnum = @intCast(elapsed_ns) }) catch return error.OutOfMemory;

    const key2 = hash_alloc.dupe(u8, "push_literal") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key2, .{ .fixnum = @intCast(local_stats.push_literal_count) }) catch return error.OutOfMemory;

    const key3 = hash_alloc.dupe(u8, "call_word") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key3, .{ .fixnum = @intCast(local_stats.call_word_count) }) catch return error.OutOfMemory;

    const key4 = hash_alloc.dupe(u8, "total_instructions") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key4, .{ .fixnum = @intCast(local_stats.totalInstructions()) }) catch return error.OutOfMemory;

    const key5 = hash_alloc.dupe(u8, "peak_stack_depth") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key5, .{ .fixnum = @intCast(local_stats.peak_stack_depth) }) catch return error.OutOfMemory;

    const key_iter = hash_alloc.dupe(u8, "iterations") catch return error.OutOfMemory;
    hash.map.put(hash_alloc, key_iter, .{ .fixnum = @intCast(n) }) catch return error.OutOfMemory;

    // Add allocation stats only when --benchmark is active
    if (alloc_delta) |delta| {
        const key6 = hash_alloc.dupe(u8, "total_allocations") catch return error.OutOfMemory;
        hash.map.put(hash_alloc, key6, .{ .fixnum = @intCast(delta.allocs) }) catch return error.OutOfMemory;

        const key7 = hash_alloc.dupe(u8, "total_bytes") catch return error.OutOfMemory;
        hash.map.put(hash_alloc, key7, .{ .fixnum = @intCast(delta.bytes) }) catch return error.OutOfMemory;
    }

    return hash;
}

/// (benchmark-n) ( n quot -- hash )
///
/// The building block for the 1z benchmark words.
pub fn nativeBenchmarkNRaw(ctx: *Context) anyerror!void {
    const pc = try popQuotation(ctx);
    defer pc.release();
    const n_raw = try popFixnum(ctx);
    if (n_raw < 1) return error.InvalidArgument;
    const hash = try executeBenchmarkN(ctx, pc, @intCast(n_raw));
    try ctx.stack.pushMoved(.{ .hash = hash });
}

test "curry over a compiled base produces a closure carrying the base code_ptr" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dummy_code: *const anyopaque = @ptrFromInt(0x1000);
    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = dummy_code } });
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result == .closure);
    const cl = result.closure;
    try std.testing.expectEqual(@as(usize, 1), cl.segments.len);
    try std.testing.expectEqual(@as(usize, 1), cl.segments[0].captures.len);
    try std.testing.expectEqual(@as(i64, 7), cl.segments[0].captures[0].fixnum);
    try std.testing.expectEqual(dummy_code, cl.segments[0].base_code_ptr);
}

test "curry over an uncompiled base produces an interpreter-run closure" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{} } });
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result == .closure);
    try std.testing.expectEqual(@as(usize, 0), result.closure.segments.len);
    try std.testing.expect(result.closure.owns_body);
}

test "compose over compiled bases produces a closure with both segments in order" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const code_a: *const anyopaque = @ptrFromInt(0x1000);
    const code_b: *const anyopaque = @ptrFromInt(0x2000);
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = code_a } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = code_b } });
    try nativeCompose(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result == .closure);
    const cl = result.closure;
    try std.testing.expectEqual(@as(usize, 2), cl.segments.len);
    try std.testing.expectEqual(code_a, cl.segments[0].base_code_ptr);
    try std.testing.expectEqual(code_b, cl.segments[1].base_code_ptr);
}

test "attach-stack-effect sets the effect on a plain quotation" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dummy_code: *const anyopaque = @ptrFromInt(0x1000);
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = dummy_code } });
    try ctx.stack.push(.{ .stack_effect = try helpers.makeSimpleEffect(ctx.quotationAllocator(), "a b -- r") });
    try nativeAttachStackEffect(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .quotation);
    try std.testing.expectEqual(@as(usize, 2), result.quotation.effect.?.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), result.quotation.effect.?.outputs.len);
    try std.testing.expectEqual(dummy_code, result.quotation.code_ptr);
}

test "attach-stack-effect sets the effect on a curried closure" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dummy_code: *const anyopaque = @ptrFromInt(0x1000);
    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = dummy_code } });
    try nativeCurry(&ctx);

    try ctx.stack.push(.{ .stack_effect = try helpers.makeSimpleEffect(ctx.quotationAllocator(), "x -- y") });
    try nativeAttachStackEffect(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result == .closure);
    const cl = result.closure;
    try std.testing.expectEqual(@as(usize, 1), cl.effect.?.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), cl.effect.?.outputs.len);
    try std.testing.expectEqual(@as(usize, 1), cl.segments.len);
    try std.testing.expectEqual(dummy_code, cl.segments[0].base_code_ptr);
    try std.testing.expectEqual(@as(usize, 1), cl.bases.len);
}

test "attach-stack-effect type-mismatches a non-effect and a non-quotation" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{} } });
    try ctx.stack.push(.{ .fixnum = 1 });
    try std.testing.expectError(error.TypeMismatch, nativeAttachStackEffect(&ctx));

    try ctx.stack.push(.{ .fixnum = 1 });
    try ctx.stack.push(.{ .stack_effect = try helpers.makeSimpleEffect(ctx.quotationAllocator(), "-- r") });
    try std.testing.expectError(error.TypeMismatch, nativeAttachStackEffect(&ctx));
}

test "nested curry prepends a capture to the first segment" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    const dummy_code: *const anyopaque = @ptrFromInt(0x1000);
    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{}, .code_ptr = dummy_code } });
    try nativeCurry(&ctx);

    const inner = try ctx.stack.pop();
    try ctx.stack.push(.{ .fixnum = 9 });
    // Transfer the popped reference back to the slot; the outer curry then
    // moves it into its retained `bases`.
    try ctx.stack.pushMoved(inner);
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result == .closure);
    const cl = result.closure;
    try std.testing.expectEqual(@as(usize, 1), cl.segments.len);
    try std.testing.expectEqual(@as(usize, 2), cl.segments[0].captures.len);
    try std.testing.expectEqual(@as(i64, 9), cl.segments[0].captures[0].fixnum);
    try std.testing.expectEqual(@as(i64, 7), cl.segments[0].captures[1].fixnum);
    try std.testing.expectEqual(dummy_code, cl.segments[0].base_code_ptr);
    try std.testing.expectEqual(@as(usize, 1), cl.bases.len);
    try std.testing.expectEqual(inner.closure, cl.bases[0]);
}

/// A stamped one-instruction body, standing in for a quotation literal written inside `module`.
fn stampedBase(ctx: *Context, module: *const value_mod.Module) !Value {
    const instrs = try ctx.arena.allocator().alloc(Instruction, 1);
    instrs[0] = .{ .op = .{ .push_literal = .{ .fixnum = 0 } }, .line = 1 };
    _ = try ctx.quotation_stamp_store.stamp(@intFromPtr(instrs.ptr), module);
    return .{ .quotation = .{ .instructions = instrs } };
}

test "curry: the product carries the base body's defining module" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(try stampedBase(&ctx, &module));
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    // The product's body is a fresh allocation, so nothing keyed by its address knows the module.
    try std.testing.expectEqual(@as(?*const value_mod.Module, &module), result.closure.defining_module);
}

test "curry: an unstamped base leaves the product with no defining module" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{} } });
    try nativeCurry(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expectEqual(@as(?*const value_mod.Module, null), result.closure.defining_module);
}

test "compose: the product carries a defining module only where both bases agree" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var module_a: value_mod.Module = .{ .name = "a", .words = .{} };
    var module_b: value_mod.Module = .{ .name = "b", .words = .{} };

    try ctx.stack.push(try stampedBase(&ctx, &module_a));
    try ctx.stack.push(try stampedBase(&ctx, &module_a));
    try nativeCompose(&ctx);
    const agreed = try ctx.stack.pop();
    defer container_backing.releaseValue(agreed);
    try std.testing.expectEqual(@as(?*const value_mod.Module, &module_a), agreed.closure.defining_module);

    // Two modules, one field: naming either would show the other half a module it was not written
    // in, so the composed body carries none and rides its merged deps instead.
    try ctx.stack.push(try stampedBase(&ctx, &module_a));
    try ctx.stack.push(try stampedBase(&ctx, &module_b));
    try nativeCompose(&ctx);
    const split = try ctx.stack.pop();
    defer container_backing.releaseValue(split);
    try std.testing.expectEqual(@as(?*const value_mod.Module, null), split.closure.defining_module);

    // Two unstamped bases agree on null, which the equality test must read as "no module" rather
    // than as an agreement worth recording.
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{} } });
    try ctx.stack.push(.{ .quotation = .{ .instructions = &.{} } });
    try nativeCompose(&ctx);
    const neither = try ctx.stack.pop();
    defer container_backing.releaseValue(neither);
    try std.testing.expectEqual(@as(?*const value_mod.Module, null), neither.closure.defining_module);
}

test "attach-stack-effect: the derived closure inherits the base's defining module" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var module: value_mod.Module = .{ .name = "m", .words = .{} };
    try ctx.stack.push(.{ .fixnum = 7 });
    try ctx.stack.push(try stampedBase(&ctx, &module));
    try nativeCurry(&ctx);

    // The derived closure aliases the base's body, so `ownsBodyTransitively` still reports true
    // through `bases` and body entry reads the module off this value rather than the map.
    try ctx.stack.push(.{ .stack_effect = try helpers.makeSimpleEffect(ctx.quotationAllocator(), "x -- y") });
    try nativeAttachStackEffect(&ctx);

    const result = try ctx.stack.pop();
    defer container_backing.releaseValue(result);
    try std.testing.expect(result.closure.ownsBodyTransitively());
    try std.testing.expectEqual(@as(?*const value_mod.Module, &module), result.closure.defining_module);
}
