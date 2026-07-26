//! Freeze-time call-site parameter type inference for closed-world AOT builds.
//!
//! A compiled word or quotation parameter starts opaque, so arithmetic and comparison on a
//! parameter the user did not annotate take a runtime generic-dispatch path. This pass proves, for
//! a program whose every call site is known at freeze time, that a given parameter receives the
//! same concrete type at every one of them, and records that on the word and quotation descriptors
//! for codegen to narrow from.
//!
//! The proof is only as good as the census it rests on. `CallerIndex` is documented as an
//! under-approximation of a word's real call sites, so it is not the census here. This pass walks
//! every word body and every discovered quotation body itself, which together hold every call
//! instruction the freezer found, and uses the caller index only to cross-check that walk. Anything
//! the walk cannot model yields `unknown`, which forces the callee opaque -- always the safe
//! direction.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;

const ir_codegen = @import("ir_codegen.zig");
const AotWordDesc = ir_codegen.AotWordDesc;
const InferredParamType = ir_codegen.InferredParamType;

const aot_freeze = @import("aot_freeze.zig");
const FreezeResult = aot_freeze.FreezeResult;

const stack_effect_mod = @import("stack_effect.zig");

/// Deepest chain of compound callee bodies the simulator will step into before falling back to the
/// callee's declared arity. Descent exists to resolve shuffle words defined in 1z, which are short
/// and shallow.
const max_descent_depth: u32 = 8;

/// Capacity of one abstract stack. A body that would exceed it abandons its stack rather than
/// growing, since a deeper shape is past the point where the pass proves anything useful.
const max_abstract_depth: usize = 256;

/// How far the scan for quotation bodies buried in a literal descends through nested containers.
const max_value_scan_depth: u32 = 16;

/// Instruction budget for one census round, across every body walked. Exhausting it discards the
/// whole table: a partial census cannot support an agree-only proof.
const max_round_steps: u64 = 8_000_000;

/// Round ceilings for the two fixpoint loops. Both descend a finite lattice and terminate on their
/// own, so these only bound the work.
///
/// Seeding folds each observation into the table as it is made, and words are walked in the
/// freezer's discovery order, which is a breadth-first walk from the entry and so reaches a caller
/// before its callees. A chain of any depth therefore converges in a couple of rounds rather than
/// one round per level. Running out of seed rounds stops proposing candidates and moves on, since
/// verification is what proves them; running out of verify rounds means the demotions never
/// settled, which discards the table.
const max_seed_rounds: u32 = 16;
const max_verify_rounds: u32 = 16;

pub const Options = struct {
    /// True under `--interpreter-fallback=false --lock-interpreter-setting`, which lets the pass
    /// type the result of fixnum arithmetic.
    ///
    /// `+`, `-`, and `*` promote to bignum on fixnum overflow, and `div` promotes on `minInt / -1`,
    /// so none of those results is a fixnum in general. Compiled concrete arithmetic bails on each
    /// of those cases instead, and on the division-by-zero cases `rem` and `%` share. An AOT bail
    /// aborts rather than resuming interpreted, so the only promoting path left inside compiled
    /// code is the per-op native fallback. A locked build rejects any build that emits one, so an
    /// execution that would falsify the rule cannot occur in a binary this flag ever ships in.
    arithmetic_result_types: bool = false,
    /// Interned builtin type values for trusting a callee's declared output annotations. When set,
    /// a call to a word whose every declared output carries one of these annotations yields those
    /// types directly instead of descending into the body (which abandons on the first row-variable
    /// callee, e.g. `dip`, leaving the result unknown).
    ///
    /// Output annotations are never validated by the callee, so a trusted result carries the
    /// `_declared` taint, and codegen enforces every taint-fed proof with a tag check at the
    /// consuming word's entry. Same-body flows are enforced by the call-site check output
    /// narrowing emits, which a relaxed `type-check` pragma disables; the caller sets these fields
    /// null under that pragma and outside locked builds, which disables the trust.
    fixnum_type: ?*const value_mod.TypeValue = null,
    float_type: ?*const value_mod.TypeValue = null,
};

/// One value on the abstract stack.
///
/// `boolean` is tracked for branch and comparison precision even though it is never exported;
/// codegen seeds only unboxed fixnum and float parameters.
///
/// The `_declared` variants carry provenance: the type rests (at least in part) on a callee's
/// declared output annotation rather than an observed fact. A proof fed such a value must be
/// enforced with a tag check at the consuming word's entry, since the annotation itself is never
/// validated at runtime. Taint spreads through joins and arithmetic, and through parameter
/// seeding, so it survives any number of hops.
const AbstractValue = union(enum) {
    unknown,
    fixnum,
    float,
    fixnum_declared,
    float_declared,
    boolean,
    quotation: []const Instruction,

    fn eql(a: AbstractValue, b: AbstractValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .quotation => |body| body.ptr == b.quotation.ptr,
            else => true,
        };
    }

    fn isFixnumish(v: AbstractValue) bool {
        return v == .fixnum or v == .fixnum_declared;
    }

    fn isFloatish(v: AbstractValue) bool {
        return v == .float or v == .float_declared;
    }

    fn isDeclared(v: AbstractValue) bool {
        return v == .fixnum_declared or v == .float_declared;
    }
};

/// What the fixpoint has established about one parameter.
///
/// The lattice: `unseeded` sits at the top, `conflicted` at the bottom, and within one numeric
/// family the `_declared` state sits below the plain one (it demands entry-check enforcement, a
/// strictly stronger requirement). Seeding moves a slot down the lattice via `joinScalar` and
/// never back up, and verification only moves a slot to `conflicted`, so both loops terminate.
const ParamState = enum {
    unseeded,
    fixnum,
    float,
    fixnum_declared,
    float_declared,
    conflicted,

    fn fromAbstract(v: AbstractValue) ?ParamState {
        return switch (v) {
            .fixnum => .fixnum,
            .float => .float,
            .fixnum_declared => .fixnum_declared,
            .float_declared => .float_declared,
            .unknown, .boolean, .quotation => null,
        };
    }

    fn toInferred(self: ParamState) InferredParamType {
        return switch (self) {
            .fixnum => .fixnum,
            .float => .float,
            .fixnum_declared => .fixnum_declared,
            .float_declared => .float_declared,
            .unseeded, .conflicted => .unknown,
        };
    }

    /// The join of two seeded scalar states: same-family states merge onto the declared one, and
    /// cross-family states conflict. Neither operand is `unseeded`/`conflicted`; callers handle
    /// those directly.
    fn joinScalar(a: ParamState, b: ParamState) ParamState {
        if (a == b) return a;
        const a_fix = a == .fixnum or a == .fixnum_declared;
        const b_fix = b == .fixnum or b == .fixnum_declared;
        if (a_fix and b_fix) return .fixnum_declared;
        const a_flt = a == .float or a == .float_declared;
        const b_flt = b == .float or b == .float_declared;
        if (a_flt and b_flt) return .float_declared;
        return .conflicted;
    }
};

/// What one census round saw at every call site targeting a single parameter.
const RoundObs = struct {
    /// Join of the round's scalar observations, ignoring the rest. Seeding reads this so a
    /// self-recursive word can be seeded from its external caller while its own recursive argument
    /// is still unresolved.
    scalar: ParamState = .unseeded,
    /// Set when some observation was not a scalar, which verification treats as disagreement.
    non_scalar: bool = false,
    count: u32 = 0,

    fn record(self: *RoundObs, v: AbstractValue) void {
        self.count += 1;
        const scalar = ParamState.fromAbstract(v) orelse {
            self.non_scalar = true;
            return;
        };
        self.scalar = switch (self.scalar) {
            .unseeded => scalar,
            .conflicted => .conflicted,
            else => ParamState.joinScalar(self.scalar, scalar),
        };
    }
};

/// Identity of one visited call instruction, for the caller-index cross-check.
const CallKey = struct {
    body: usize,
    index: u32,
};

/// Whether a walk contributes to the census or only moves the abstract stack.
///
/// A compound callee's body is walked once on its own with `record`, so stepping into it from a
/// call site records nothing: the standalone walk starts from the callee's inferred parameters,
/// which is the join over every site and therefore never less conservative. Silent walks also leave
/// no visited mark, so a body reached only that way still gets an unknown-entry walk from the
/// leftover pass rather than escaping the census.
const Mode = enum { record, silent };

const Frame = struct {
    values: []AbstractValue,
    sp: usize = 0,
    /// False once the simulator lost track of the stack shape. The walk keeps visiting
    /// instructions, since the census depends on seeing every call; it just reports `unknown` for
    /// every operand from here on.
    usable: bool = true,
};

const Inference = struct {
    allocator: Allocator,
    result: *FreezeResult,
    options: Options,

    /// Word descriptor index by name, last insert winning, mirroring the name-keyed resolver map
    /// `emitProgramC` builds. Every call site in compiled code binds the same way.
    by_name: std.StringHashMapUnmanaged(u32) = .{},
    /// Names carried by more than one descriptor. Those descriptors collapse onto one binding in
    /// codegen, so neither can claim its own call sites.
    ambiguous: std.StringHashMapUnmanaged(void) = .{},

    /// Quotation descriptor index by body pointer.
    quot_by_body: std.AutoHashMapUnmanaged(usize, u32) = .{},

    /// Quotation bodies buried in a literal that the freezer never gave a descriptor, keyed by body
    /// pointer. A `parameter{ [ ... ] }` default is the case that reaches here: freeze seeds its
    /// callees into the worklist but appends the body itself to neither `words` nor `quotations`, so
    /// the census has to walk it directly or the calls inside it go unrecorded.
    orphan_bodies: std.AutoHashMapUnmanaged(usize, []const Instruction) = .{},

    /// Parameter states for every target, words first and quotations after, sliced by `offsets`.
    states: []ParamState = &.{},
    obs: []RoundObs = &.{},
    offsets: []u32 = &.{},

    /// Quotation bodies with at least one use the walk could not model. Sticky across rounds: a use
    /// that escapes once is a real path whether or not a later round happens to re-model it.
    escaped: []bool = &.{},

    /// Backing store for the per-arm frame copies `applyIf` makes, two frames' worth per descent
    /// depth, indexed by `armScratch`.
    arm_scratch: []AbstractValue = &.{},

    /// Bodies stepped into by a recording walk this round.
    visited: std.AutoHashMapUnmanaged(usize, void) = .{},
    /// Call instructions a recording walk reached this round.
    visited_calls: std.AutoHashMapUnmanaged(CallKey, void) = .{},

    /// Word descriptor indices currently being descended into, so a recursive callee falls back to
    /// its declared arity instead of unrolling forever.
    descending: std.ArrayListUnmanaged(u32) = .{},

    steps: u64 = 0,
    /// Set when a round ran out of budget, so the census is partial and the table is discarded.
    exhausted: bool = false,

    /// True while the seed phase is running, so an observation is folded into the table as it is
    /// made rather than at the end of the round.
    seeding: bool = false,
    /// Set when seeding moved a slot this round.
    seed_changed: bool = false,

    fn deinit(self: *Inference) void {
        self.by_name.deinit(self.allocator);
        self.ambiguous.deinit(self.allocator);
        self.quot_by_body.deinit(self.allocator);
        self.orphan_bodies.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.visited_calls.deinit(self.allocator);
        self.descending.deinit(self.allocator);
        self.allocator.free(self.states);
        self.allocator.free(self.obs);
        self.allocator.free(self.offsets);
        self.allocator.free(self.escaped);
        self.allocator.free(self.arm_scratch);
    }

    fn wordCount(self: *const Inference) usize {
        return self.result.words.len;
    }

    fn paramCount(self: *const Inference, target: usize) u32 {
        return self.offsets[target + 1] - self.offsets[target];
    }

    fn quotTarget(self: *const Inference, quot_idx: u32) usize {
        return self.wordCount() + quot_idx;
    }

    // ── Setup ──

    fn build(allocator: Allocator, result: *FreezeResult, options: Options) Allocator.Error!Inference {
        var self = Inference{ .allocator = allocator, .result = result, .options = options };
        errdefer self.deinit();

        for (result.words, 0..) |w, i| {
            const gop = try self.by_name.getOrPut(allocator, w.name);
            if (gop.found_existing) try self.ambiguous.put(allocator, w.name, {});
            gop.value_ptr.* = @intCast(i);
        }

        for (result.quotations, 0..) |q, i| {
            if (q.instructions.len == 0) continue;
            try self.quot_by_body.put(allocator, @intFromPtr(q.instructions.ptr), @intCast(i));
        }

        const target_count = result.words.len + result.quotations.len;
        self.offsets = try allocator.alloc(u32, target_count + 1);
        var total: u32 = 0;
        for (result.words, 0..) |w, i| {
            self.offsets[i] = total;
            // A native has no compiled body whose prologue could narrow anything, so it carries no
            // slots and every observation against it costs nothing.
            total += if (w.is_native) 0 else w.input_count;
        }
        for (result.quotations, 0..) |q, i| {
            self.offsets[result.words.len + i] = total;
            total += if (q.inferred_effect) |eff| eff.input_count else 0;
        }
        self.offsets[target_count] = total;

        self.states = try allocator.alloc(ParamState, total);
        @memset(self.states, .unseeded);
        self.obs = try allocator.alloc(RoundObs, total);
        self.escaped = try allocator.alloc(bool, result.quotations.len);
        @memset(self.escaped, false);
        self.arm_scratch = try allocator.alloc(AbstractValue, 2 * max_descent_depth * max_abstract_depth);

        // A quotation the freezer only ever reached through a composite literal or a dispatch entry
        // has no call site the walk can attribute types to.
        for (result.quotations, 0..) |q, i| {
            if (q.is_method_body or q.from_composite) self.escaped[i] = true;
        }

        return self;
    }

    // ── Abstract stack ──

    fn push(self: *Inference, frame: *Frame, v: AbstractValue) void {
        if (!frame.usable) {
            self.markEscapedValue(v);
            return;
        }
        if (frame.sp >= frame.values.len) {
            self.abandon(frame);
            self.markEscapedValue(v);
            return;
        }
        frame.values[frame.sp] = v;
        frame.sp += 1;
    }

    /// Pop an operand that is about to be consumed by something the pass does not model, so a
    /// quotation value leaving this way is a use it cannot account for.
    fn pop(self: *Inference, frame: *Frame) AbstractValue {
        const v = self.popRaw(frame);
        self.markEscapedValue(v);
        return v;
    }

    /// Pop an operand a modelled combinator is about to interpret itself, leaving a quotation
    /// value's uses accounted for.
    fn popRaw(self: *Inference, frame: *Frame) AbstractValue {
        if (!frame.usable) return .unknown;
        if (frame.sp == 0) {
            self.abandon(frame);
            return .unknown;
        }
        frame.sp -= 1;
        return frame.values[frame.sp];
    }

    /// Give up on this frame's shape. Every quotation still on it flows somewhere unmodelled.
    fn abandon(self: *Inference, frame: *Frame) void {
        if (!frame.usable) return;
        for (frame.values[0..frame.sp]) |v| self.markEscapedValue(v);
        frame.sp = 0;
        frame.usable = false;
    }

    /// Record every quotation body reachable inside a literal that is not itself a quotation.
    ///
    /// A body the freezer gave a descriptor is marked escaped, since the path that reaches it here
    /// is one this walk does not follow. A body with no descriptor is queued for the leftover pass,
    /// which is the only way the calls inside it enter the census at all.
    fn noteBuriedBodies(self: *Inference, val: value_mod.Value, depth: u32) Allocator.Error!void {
        if (depth >= max_value_scan_depth) return;
        switch (val) {
            .quotation => |q| try self.noteBuriedBody(q.instructions),
            .parameter => |p| try self.noteBuriedBody(p.default_quotation.instructions),
            .array => |arr| for (arr.items) |elem| try self.noteBuriedBodies(elem, depth + 1),
            .vector => |v| for (v.list.items) |elem| try self.noteBuriedBodies(elem, depth + 1),
            .hash => |h| {
                var it = h.map.iterator();
                while (it.next()) |entry| try self.noteBuriedBodies(entry.value_ptr.*, depth + 1);
            },
            .mutable_map => |m| {
                var it = m.map.iterator();
                while (it.next()) |entry| try self.noteBuriedBodies(entry.value_ptr.*, depth + 1);
            },
            .struct_instance => |si| for (si.fields) |field| try self.noteBuriedBodies(field, depth + 1),
            else => {},
        }
    }

    fn noteBuriedBody(self: *Inference, body: []const Instruction) Allocator.Error!void {
        if (body.len == 0) return;
        const key = @intFromPtr(body.ptr);
        if (self.quot_by_body.get(key)) |idx| {
            self.escaped[idx] = true;
            return;
        }
        try self.orphan_bodies.put(self.allocator, key, body);
    }

    fn markEscapedValue(self: *Inference, v: AbstractValue) void {
        const body = switch (v) {
            .quotation => |b| b,
            else => return,
        };
        if (body.len == 0) return;
        if (self.quot_by_body.get(@intFromPtr(body.ptr))) |idx| self.escaped[idx] = true;
    }

    // ── Observations ──

    fn observe(self: *Inference, target: usize, frame: *const Frame, count: u32) void {
        if (count == 0) return;
        const base = self.offsets[target];
        const have_shape = frame.usable and frame.sp >= count;
        for (0..count) |i| {
            const v: AbstractValue = if (have_shape)
                frame.values[frame.sp - count + i]
            else
                .unknown;
            self.obs[base + i].record(v);
            if (self.seeding) self.seedSlot(base + i, v);
        }
    }

    /// Fold one observation into the table, reporting nothing and moving the slot only downward.
    ///
    /// Non-scalar observations are ignored here. That is what lets a self-recursive word be seeded
    /// from its external caller while its own recursive argument is still unresolved; verification
    /// is where an untypable site counts against a candidate.
    fn seedSlot(self: *Inference, slot: usize, v: AbstractValue) void {
        const scalar = ParamState.fromAbstract(v) orelse return;
        const current = self.states[slot];
        const next: ParamState = switch (current) {
            .unseeded => scalar,
            .conflicted => .conflicted,
            else => ParamState.joinScalar(current, scalar),
        };
        if (next == current) return;
        self.states[slot] = next;
        self.seed_changed = true;
    }

    // ── Walking ──

    fn walk(self: *Inference, body: []const Instruction, frame: *Frame, depth: u32, mode: Mode) Allocator.Error!void {
        for (body, 0..) |instr, idx| {
            self.steps += 1;
            if (self.steps > max_round_steps) {
                self.exhausted = true;
                return;
            }

            switch (instr.op) {
                .push_literal => |val| {
                    // A quotation pushed on its own is tracked on the abstract stack. One buried in
                    // any other literal is reached by a path this walk does not follow, so it is
                    // recorded for the leftover pass instead.
                    if (val != .quotation) try self.noteBuriedBodies(val, 0);
                    self.push(frame, abstractForLiteral(val));
                },
                .call_word, .call_word_direct => {
                    const name = instr.op.callTargetName().?;
                    if (mode == .record) {
                        try self.visited_calls.put(self.allocator, .{
                            .body = @intFromPtr(body.ptr),
                            .index = @intCast(idx),
                        }, {});
                    }
                    try self.applyCall(name, frame, depth, mode);
                },
            }
        }
    }

    fn applyCall(self: *Inference, name: []const u8, frame: *Frame, depth: u32, mode: Mode) Allocator.Error!void {
        if (self.ambiguous.contains(name)) {
            self.abandon(frame);
            return;
        }
        const desc_idx = self.by_name.get(name) orelse {
            self.abandon(frame);
            return;
        };
        const desc = &self.result.words[desc_idx];

        // The rules below are keyed on a name, so they may only speak for a call the program
        // actually binds to that primitive. A word of the same name defined in 1z takes the
        // ordinary compound path and is stepped into like any other.
        //
        // This still assumes a call reaching a modelled native with operands of the type the rule
        // covers runs the builtin rather than a method registered over it. Compiled code makes the
        // same assumption: codegen emits concrete arithmetic for narrowed operands with no dispatch
        // check, which is what the declared-annotation narrowing already relies on.
        if (desc.is_native and try self.applyModelledNative(name, frame, depth, mode)) return;

        // A row variable makes the call's operand count depend on the caller's stack, which the
        // pass has no way to pin down.
        if (desc.stack_effect) |eff| {
            if (stack_effect_mod.hasAnyRowVariable(eff)) {
                self.abandon(frame);
                return;
            }
        }

        if (mode == .record) self.observe(desc_idx, frame, self.paramCount(desc_idx));

        // A fully-annotated callee yields its declared result types directly. This is what lets a
        // computed result cross a callee whose body cannot be descended into -- `fib`'s body calls
        // through `dip`, whose row variable abandons the descent frame. The results carry the
        // declared taint, so any proof they feed gets entry-check enforcement in codegen.
        if (self.annotatedOutputs(desc)) |outs| {
            for (0..desc.input_count) |_| _ = self.pop(frame);
            for (outs) |param| {
                const tv = param.type_annotation.?.type;
                self.push(frame, if (tv == self.options.fixnum_type.?) .fixnum_declared else .float_declared);
            }
            return;
        }

        if (!desc.is_native and desc.instructions.len > 0 and depth < max_descent_depth and !self.isDescending(desc_idx)) {
            try self.descending.append(self.allocator, desc_idx);
            defer _ = self.descending.pop();

            const before: isize = @intCast(frame.sp);
            try self.walk(desc.instructions, frame, depth + 1, .silent);

            // A descent stands in for the call only when the body it walked moved the stack the
            // way the callee's declared arity says it does.
            //
            // A generated struct constructor is one shape where it does not. Its body ends in a
            // polymorphic native, which the freeze records with zero declared arity, so the walk
            // consumes none of the field values the real word consumes. Every later operand in
            // this frame is off by that much.
            const expected = before - desc.input_count + desc.output_count;
            if (@as(isize, @intCast(frame.sp)) != expected) self.abandon(frame);
            return;
        }

        for (0..desc.input_count) |_| _ = self.pop(frame);
        for (0..desc.output_count) |_| self.push(frame, .unknown);
    }

    /// The callee's declared outputs, when every one of them carries a builtin fixnum/float
    /// annotation the pass may trust (see `Options.fixnum_type`). Mirrors the shape checks of
    /// codegen's output narrowing: a row variable or an alternative-output effect makes the
    /// declared shape unreliable, and a count disagreement means the effect does not model the
    /// arity the freeze recorded.
    fn annotatedOutputs(self: *const Inference, desc: *const AotWordDesc) ?[]const stack_effect_mod.StackEffectParam {
        const fixnum_tv = self.options.fixnum_type orelse return null;
        const float_tv = self.options.float_type orelse return null;

        const eff = desc.stack_effect orelse return null;
        const outs = eff.outputs;
        if (outs.len == 0 or outs.len != desc.output_count) return null;
        if (stack_effect_mod.paramsHaveAlternativeOutput(outs)) return null;

        for (outs) |param| {
            if (param.is_row_variable) return null;
            const ann = param.type_annotation orelse return null;
            const tv = switch (ann) {
                .type => |t| t,
                .protocol, .combination => return null,
            };
            if (tv != fixnum_tv and tv != float_tv) return null;
        }
        return outs;
    }

    fn isDescending(self: *const Inference, desc_idx: u32) bool {
        for (self.descending.items) |d| {
            if (d == desc_idx) return true;
        }
        return false;
    }

    /// Apply a native this pass models directly, reporting whether it handled the call.
    fn applyModelledNative(self: *Inference, name: []const u8, frame: *Frame, depth: u32, mode: Mode) Allocator.Error!bool {
        if (eq(name, "dup")) {
            const v = self.popRaw(frame);
            self.push(frame, v);
            self.push(frame, v);
            return true;
        }
        if (eq(name, "drop")) {
            _ = self.pop(frame);
            return true;
        }
        if (eq(name, "swap")) {
            const b = self.popRaw(frame);
            const a = self.popRaw(frame);
            self.push(frame, b);
            self.push(frame, a);
            return true;
        }
        if (eq(name, "over")) {
            const b = self.popRaw(frame);
            const a = self.popRaw(frame);
            self.push(frame, a);
            self.push(frame, b);
            self.push(frame, a);
            return true;
        }
        if (eq(name, "t") or eq(name, "f")) {
            self.push(frame, .boolean);
            return true;
        }
        if (eq(name, "=") or eq(name, "<") or eq(name, ">")) {
            _ = self.pop(frame);
            _ = self.pop(frame);
            self.push(frame, .boolean);
            return true;
        }
        if (arithKind(name)) |kind| {
            const b = self.pop(frame);
            const a = self.pop(frame);
            self.push(frame, self.arithResult(kind, a, b));
            return true;
        }
        if (eq(name, "call")) {
            const quot = self.popRaw(frame);
            try self.enterQuotation(quot, frame, depth, mode);
            return true;
        }
        if (eq(name, "dip")) {
            const quot = self.popRaw(frame);
            const saved = self.popRaw(frame);
            try self.enterQuotation(quot, frame, depth, mode);
            self.push(frame, saved);
            return true;
        }
        if (eq(name, "if")) {
            const else_q = self.popRaw(frame);
            const then_q = self.popRaw(frame);
            _ = self.pop(frame);
            try self.applyIf(then_q, else_q, frame, depth, mode);
            return true;
        }
        return false;
    }

    const ArithKind = enum { checked, guarded };

    fn arithKind(name: []const u8) ?ArithKind {
        if (eq(name, "+") or eq(name, "-") or eq(name, "*")) return .checked;
        if (eq(name, "div") or eq(name, "rem") or eq(name, "%")) return .guarded;
        return null;
    }

    fn arithResult(self: *const Inference, kind: ArithKind, a: AbstractValue, b: AbstractValue) AbstractValue {
        const tainted = a.isDeclared() or b.isDeclared();
        if (a.isFloatish() and b.isFloatish()) {
            // Float arithmetic never promotes, so this holds in every build mode. `div` and `rem`
            // are integer-only and have no float form; `%` does accept floats, and reporting it as
            // unknown is imprecision rather than a missing form.
            if (kind != .checked) return .unknown;
            return if (tainted) .float_declared else .float;
        }
        if (a.isFixnumish() and b.isFixnumish() and self.options.arithmetic_result_types) {
            return if (tainted) .fixnum_declared else .fixnum;
        }
        return .unknown;
    }

    /// Run a quotation operand's body on the current stack, recording its parameters.
    fn enterQuotation(self: *Inference, quot: AbstractValue, frame: *Frame, depth: u32, mode: Mode) Allocator.Error!void {
        const body = switch (quot) {
            .quotation => |b| b,
            else => {
                // The combinator runs something the pass cannot see, so the resulting stack shape
                // is unknown from here on.
                self.abandon(frame);
                return;
            },
        };
        if (depth >= max_descent_depth) {
            // The body still runs here, so it has a use this walk never accounted for.
            self.markEscapedValue(quot);
            self.abandon(frame);
            return;
        }

        if (body.len > 0) {
            if (self.quot_by_body.get(@intFromPtr(body.ptr))) |quot_idx| {
                if (mode == .record) {
                    try self.visited.put(self.allocator, @intFromPtr(body.ptr), {});
                    const target = self.quotTarget(quot_idx);
                    self.observe(target, frame, self.paramCount(target));
                }
            }
        }

        try self.walk(body, frame, depth + 1, mode);
    }

    fn applyIf(self: *Inference, then_q: AbstractValue, else_q: AbstractValue, frame: *Frame, depth: u32, mode: Mode) Allocator.Error!void {
        if (then_q != .quotation or else_q != .quotation) {
            self.markEscapedValue(then_q);
            self.markEscapedValue(else_q);
            self.abandon(frame);
            return;
        }
        if (!frame.usable or depth >= max_descent_depth) {
            self.markEscapedValue(then_q);
            self.markEscapedValue(else_q);
            self.abandon(frame);
            return;
        }

        // Each arm runs on its own copy of the entry stack. The buffers come from a pool indexed by
        // depth rather than a fresh allocation per `if`, since a census round walks every body and
        // every round repeats it.
        var then_frame = self.cloneFrame(frame, self.armScratch(depth, 0));
        try self.enterQuotation(then_q, &then_frame, depth, mode);

        var else_frame = self.cloneFrame(frame, self.armScratch(depth, 1));
        try self.enterQuotation(else_q, &else_frame, depth, mode);

        if (!then_frame.usable or !else_frame.usable or then_frame.sp != else_frame.sp) {
            self.abandon(&then_frame);
            self.abandon(&else_frame);
            self.abandon(frame);
            return;
        }

        frame.sp = then_frame.sp;
        for (0..frame.sp) |i| {
            const a = then_frame.values[i];
            const b = else_frame.values[i];
            if (a.eql(b)) {
                frame.values[i] = a;
                continue;
            }
            // Same-family scalars merge onto the declared side, keeping a proof alive when one arm
            // rests on an annotation.
            if (a.isFixnumish() and b.isFixnumish()) {
                frame.values[i] = .fixnum_declared;
                continue;
            }
            if (a.isFloatish() and b.isFloatish()) {
                frame.values[i] = .float_declared;
                continue;
            }
            // Only one arm's value reaches the caller, and the merge cannot say which, so a
            // quotation on either side has a use this walk stops following here.
            self.markEscapedValue(a);
            self.markEscapedValue(b);
            frame.values[i] = .unknown;
        }
    }

    /// The scratch buffer for one arm of an `if` at `depth`. Two per depth, and `applyIf` only
    /// reaches here below `max_descent_depth`, so the slices never overlap a live frame.
    fn armScratch(self: *Inference, depth: u32, arm: usize) []AbstractValue {
        const slot = @as(usize, depth) * 2 + arm;
        const base = slot * max_abstract_depth;
        return self.arm_scratch[base .. base + max_abstract_depth];
    }

    fn cloneFrame(self: *Inference, frame: *const Frame, into: []AbstractValue) Frame {
        _ = self;
        @memcpy(into[0..frame.sp], frame.values[0..frame.sp]);
        return .{ .values = into, .sp = frame.sp, .usable = frame.usable };
    }

    // ── Census ──

    fn runCensus(self: *Inference) Allocator.Error!void {
        @memset(self.obs, .{});
        self.visited.clearRetainingCapacity();
        self.visited_calls.clearRetainingCapacity();
        self.steps = 0;

        const values = try self.allocator.alloc(AbstractValue, max_abstract_depth);
        defer self.allocator.free(values);

        for (self.result.words, 0..) |*w, i| {
            if (w.is_native or w.instructions.len == 0) continue;
            if (self.exhausted) return;

            var frame = Frame{ .values = values };
            const base = self.offsets[i];
            const param_count = self.paramCount(i);
            if (param_count > values.len) {
                self.abandon(&frame);
            } else {
                for (0..param_count) |p| self.push(&frame, abstractForState(self.states[base + p]));
            }
            try self.walk(w.instructions, &frame, 0, .record);
            // Whatever the body leaves behind flows out to callers the pass does not follow.
            self.abandon(&frame);
        }

        try self.walkLeftoverQuotations(values);
    }

    /// Walk every quotation body the recording pass did not reach with a known entry stack.
    ///
    /// A body is covered here when no modelled combinator stepped into it, or when some other use
    /// of it escaped: either way an execution reaches it with operands this pass cannot name, and
    /// the census must still see the calls inside it. Repeats because walking one body can escape
    /// or turn up another.
    fn walkLeftoverQuotations(self: *Inference, values: []AbstractValue) Allocator.Error!void {
        const walked = try self.allocator.alloc(bool, self.result.quotations.len);
        defer self.allocator.free(walked);
        @memset(walked, false);

        var walked_orphans = std.AutoHashMapUnmanaged(usize, void){};
        defer walked_orphans.deinit(self.allocator);

        var progress = true;
        while (progress) {
            progress = false;
            for (self.result.quotations, 0..) |q, i| {
                if (self.exhausted) return;
                if (walked[i] or q.instructions.len == 0) continue;
                const covered = self.visited.contains(@intFromPtr(q.instructions.ptr)) and !self.escaped[i];
                if (covered) continue;

                walked[i] = true;
                progress = true;
                self.escaped[i] = true;

                const input_count: u32 = if (q.inferred_effect) |eff| eff.input_count else 0;
                try self.walkWithUnknownEntry(q.instructions, values, input_count);
            }

            var it = self.orphan_bodies.iterator();
            while (it.next()) |entry| {
                if (self.exhausted) return;
                if (walked_orphans.contains(entry.key_ptr.*)) continue;

                try walked_orphans.put(self.allocator, entry.key_ptr.*, {});
                progress = true;
                // A buried body has no descriptor, so nothing records its arity. Starting empty
                // leaves the first pop to abandon the stack, which is the conservative reading.
                try self.walkWithUnknownEntry(entry.value_ptr.*, values, 0);
                // `walk` can add orphans, invalidating the iterator.
                break;
            }
        }
    }

    fn walkWithUnknownEntry(self: *Inference, body: []const Instruction, values: []AbstractValue, input_count: u32) Allocator.Error!void {
        var frame = Frame{ .values = values };
        for (0..input_count) |_| self.push(&frame, .unknown);
        try self.walk(body, &frame, 0, .record);
        self.abandon(&frame);
    }

    // ── Fixpoint ──

    fn converge(self: *Inference) Allocator.Error!bool {
        self.seeding = true;
        var round: u32 = 0;
        while (round < max_seed_rounds) : (round += 1) {
            self.seed_changed = false;
            try self.runCensus();
            if (self.exhausted) return false;
            const escapes_moved = self.applyEscapes();
            if (!self.seed_changed and !escapes_moved) break;
        }
        self.seeding = false;

        // Before verification, not after, so a demotion the cross-check causes propagates to
        // whatever was proved from the demoted parameter.
        try self.crossCheckAgainstCallerIndex();

        round = 0;
        while (true) : (round += 1) {
            if (round >= max_verify_rounds) return false;
            try self.runCensus();
            if (self.exhausted) return false;
            if (!self.applyVerify()) break;
        }
        return true;
    }

    /// Demote every parameter some call site this round disagreed with, reporting whether anything
    /// moved. Disagreement includes a non-scalar observation and a parameter with no observed
    /// site. A plain observation against a declared state agrees -- the state already carries the
    /// stronger enforcement requirement -- so the keep condition is join-compatibility, not
    /// equality.
    fn applyVerify(self: *Inference) bool {
        var changed = false;
        for (self.states, self.obs) |*state, o| {
            switch (state.*) {
                .unseeded, .conflicted => continue,
                else => {},
            }
            if (o.count > 0 and !o.non_scalar and ParamState.joinScalar(state.*, o.scalar) == state.*) continue;
            state.* = .conflicted;
            changed = true;
        }
        const escapes_moved = self.applyEscapes();
        return changed or escapes_moved;
    }

    fn applyEscapes(self: *Inference) bool {
        var changed = false;
        for (self.escaped, 0..) |escaped, i| {
            if (!escaped) continue;
            const target = self.quotTarget(@intCast(i));
            for (self.offsets[target]..self.offsets[target + 1]) |slot| {
                if (self.states[slot] == .conflicted) continue;
                self.states[slot] = .conflicted;
                changed = true;
            }
        }
        return changed;
    }

    /// Demote any word whose caller index names a call site the walk did not reach.
    ///
    /// The walk is the census, so this is a check on the walk rather than a source of sites. A row
    /// `locateCallSite` rejects needs no action: it addresses a method or composite-buried body,
    /// which the leftover pass already walked with unknown operands.
    fn crossCheckAgainstCallerIndex(self: *Inference) Allocator.Error!void {
        var index = try aot_freeze.buildCallerIndex(self.result, self.allocator);
        defer index.deinit(self.allocator);

        for (self.result.words, 0..) |w, desc_idx| {
            if (self.paramCount(desc_idx) == 0) continue;
            for (index.callSites(w.word_id)) |row| {
                const located = aot_freeze.locateCallSite(self.result, index.entryAt(row)) orelse continue;
                const key = CallKey{ .body = @intFromPtr(located.body.ptr), .index = located.index };
                if (self.visited_calls.contains(key)) continue;

                for (self.offsets[desc_idx]..self.offsets[desc_idx + 1]) |slot| {
                    self.states[slot] = .conflicted;
                }
                break;
            }
        }
    }

    // ── Export ──

    fn publish(self: *Inference) Allocator.Error!void {
        var needed: usize = 0;
        for (0..self.offsets.len - 1) |target| {
            if (self.hasProof(target)) needed += self.paramCount(target);
        }
        if (needed == 0) return;

        const slab = try self.allocator.alloc(InferredParamType, needed);
        self.result.inferred_param_storage = slab;

        var cursor: usize = 0;
        for (0..self.offsets.len - 1) |target| {
            if (!self.hasProof(target)) continue;
            const count = self.paramCount(target);
            const slice = slab[cursor .. cursor + count];
            cursor += count;
            for (slice, self.offsets[target]..) |*out, slot| out.* = self.states[slot].toInferred();

            if (target < self.wordCount()) {
                self.result.words[target].inferred_param_types = slice;
            } else {
                self.result.quotations[target - self.wordCount()].inferred_param_types = slice;
            }
        }
    }

    fn hasProof(self: *const Inference, target: usize) bool {
        for (self.offsets[target]..self.offsets[target + 1]) |slot| {
            switch (self.states[slot]) {
                .fixnum, .float, .fixnum_declared, .float_declared => return true,
                .unseeded, .conflicted => {},
            }
        }
        return false;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn abstractForLiteral(val: value_mod.Value) AbstractValue {
    return switch (val) {
        .fixnum => .fixnum,
        .float => .float,
        .boolean => .boolean,
        .quotation => |q| .{ .quotation = q.instructions },
        else => .unknown,
    };
}

fn abstractForState(state: ParamState) AbstractValue {
    return switch (state) {
        .fixnum => .fixnum,
        .float => .float,
        .fixnum_declared => .fixnum_declared,
        .float_declared => .float_declared,
        .unseeded, .conflicted => .unknown,
    };
}

/// Prove parameter types from call sites and attach them to `result`'s descriptors.
///
/// Only callers that have established a closed world should run this: every call site must be
/// visible at freeze time, which rules out a build where `eval-string` or a runtime `load` can
/// introduce one later. Proving nothing is a normal outcome and leaves every descriptor untouched.
pub fn inferParamTypes(result: *FreezeResult, options: Options, allocator: Allocator) Allocator.Error!void {
    var inference = try Inference.build(allocator, result, options);
    defer inference.deinit();

    if (!try inference.converge()) return;
    try inference.publish();
}

// ── Tests ──

const testing = std.testing;

const FixtureWord = struct {
    name: []const u8,
    body: []const Instruction = &.{},
    input_count: u8 = 0,
    output_count: u8 = 0,
    is_native: bool = false,
    stack_effect: ?stack_effect_mod.StackEffect = null,
};

const FixtureQuot = struct {
    body: []const Instruction,
    input_count: u8 = 0,
    output_count: u8 = 0,
    is_method_body: bool = false,
    from_composite: bool = false,
};

/// Every name `applyModelledNative` has a rule for. A real freeze always discovers a called
/// primitive, so the fixture registers each as a native descriptor unless the test declared a word
/// of that name itself.
///
/// Keep this in step with `applyModelledNative`. A rule whose name is missing here gets no native
/// descriptor in any fixture, so `desc.is_native` is false and the rule never fires under test.
const modelled_native_names = [_][]const u8{
    "dup", "drop", "swap", "over", "t", "f",   "=",
    "<",   ">",    "+",    "-",    "*", "div", "rem",
    "%",   "call", "dip",  "if",
};

/// Assemble a `FreezeResult` from literal word and quotation lists, so a test states the program it
/// needs instead of driving a real freeze.
///
/// Every body and name is borrowed, so they must outlive the result. `call_targets` is copied
/// instead, since `FreezeResult.deinit` owns that slice. Word ids are the descriptor index, matching
/// what `buildAotDescs` produces, and the appended natives come last so a test can index the words
/// it declared.
fn fixture(
    allocator: Allocator,
    words: []const FixtureWord,
    quots: []const FixtureQuot,
    call_targets: []const aot_freeze.CallTargetEntry,
) Allocator.Error!FreezeResult {
    // `toOwnedSlice` empties the list, so this covers both the error paths above it and the
    // no-op it becomes on success.
    var built = std.ArrayListUnmanaged(AotWordDesc){};
    defer built.deinit(allocator);

    for (words) |w| try built.append(allocator, .{
        .name = w.name,
        .instructions = w.body,
        .input_count = w.input_count,
        .output_count = w.output_count,
        .word_id = @intCast(built.items.len),
        .is_native = w.is_native,
        .stack_effect = w.stack_effect,
    });
    for (modelled_native_names) |native| {
        for (words) |w| {
            if (eq(w.name, native)) break;
        } else try built.append(allocator, .{
            .name = native,
            .instructions = &.{},
            .input_count = 0,
            .output_count = 0,
            .word_id = @intCast(built.items.len),
            .is_native = true,
        });
    }

    const descs = try built.toOwnedSlice(allocator);
    errdefer allocator.free(descs);

    const qdescs = try allocator.alloc(aot_freeze.AotQuotationDesc, quots.len);
    var named: usize = 0;
    errdefer {
        for (qdescs[0..named]) |q| allocator.free(q.c_name);
        allocator.free(qdescs);
    }
    for (quots, 0..) |q, i| {
        qdescs[i] = .{
            .quotation_id = @intCast(i),
            .instructions = q.body,
            .c_name = try std.fmt.allocPrint(allocator, "onez_q_{d}", .{i}),
            .inferred_effect = .{ .input_count = q.input_count, .output_count = q.output_count },
            .is_method_body = q.is_method_body,
            .from_composite = q.from_composite,
        };
        named = i + 1;
    }

    const rows = try allocator.dupe(aot_freeze.CallTargetEntry, call_targets);

    return .{
        .words = descs,
        .quotations = qdescs,
        .entry_word_id = 0,
        .max_word_id = if (descs.len == 0) 0 else @intCast(descs.len - 1),
        .max_quotation_id = if (quots.len == 0) 0 else @intCast(quots.len - 1),
        .skipped_words = &.{},
        .entry_instrs = &.{},
        .call_targets = rows,
    };
}

fn at(op: Instruction.Op) Instruction {
    return .{ .op = op, .line = 1 };
}

fn wordParams(result: *const FreezeResult, name: []const u8) []const InferredParamType {
    for (result.words) |w| {
        if (eq(w.name, name)) return w.inferred_param_types;
    }
    unreachable;
}

test "a parameter fed the same literal type at every call site narrows" {
    const allocator = testing.allocator;

    const scale_body = [_]Instruction{
        at(.{ .call_word = "dup" }),
        at(.{ .call_word = "drop" }),
    };
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .call_word = "scale" }),
        at(.{ .call_word = "drop" }),
        at(.{ .push_literal = .{ .fixnum = 4 } }),
        at(.{ .call_word = "scale" }),
        at(.{ .call_word = "drop" }),
    };

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "scale", .body = &scale_body, .input_count = 1, .output_count = 1 },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqualSlices(InferredParamType, &.{.fixnum}, wordParams(&result, "scale"));
}

test "a parameter fed different types at different call sites stays opaque" {
    const allocator = testing.allocator;

    const scale_body = [_]Instruction{at(.{ .call_word = "drop" })};
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .call_word = "scale" }),
        at(.{ .push_literal = .{ .float = 1.5 } }),
        at(.{ .call_word = "scale" }),
    };

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "scale", .body = &scale_body, .input_count = 1 },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqual(@as(usize, 0), wordParams(&result, "scale").len);
}

test "shuffle natives carry a literal's type through to the call site" {
    const allocator = testing.allocator;

    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .push_literal = .{ .float = 1.5 } }),
        at(.{ .call_word = "swap" }),
        at(.{ .call_word = "take2" }),
    };

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "take2", .body = &[_]Instruction{at(.{ .call_word = "drop" })}, .input_count = 2 },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqualSlices(
        InferredParamType,
        &.{ .float, .fixnum },
        wordParams(&result, "take2"),
    );
}

test "stepping into a compound callee resolves a shuffle word defined in 1z" {
    const allocator = testing.allocator;

    // The shape of `<rot-: ( a b c -- b c a ) [ [ swap ] dip swap ]`, the prelude word the
    // motivating program routes its arguments through.
    const swap_body = [_]Instruction{at(.{ .call_word = "swap" })};
    const rot_body = [_]Instruction{
        at(.{ .push_literal = .{ .quotation = .{ .instructions = &swap_body } } }),
        at(.{ .call_word = "dip" }),
        at(.{ .call_word = "swap" }),
    };
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .float = 1.5 } }),
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .push_literal = .{ .fixnum = 4 } }),
        at(.{ .call_word = "rot3" }),
        at(.{ .call_word = "take3" }),
    };

    var result = try fixture(
        allocator,
        &.{
            .{ .name = "__entry__", .body = &entry_body },
            .{ .name = "rot3", .body = &rot_body, .input_count = 3, .output_count = 3 },
            .{ .name = "take3", .body = &[_]Instruction{at(.{ .call_word = "drop" })}, .input_count = 3 },
        },
        &.{.{ .body = &swap_body, .input_count = 2, .output_count = 2 }},
        &.{},
    );
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqualSlices(
        InferredParamType,
        &.{ .fixnum, .fixnum, .float },
        wordParams(&result, "take3"),
    );
    // The dipped quotation is narrowed through the combinator that invokes it, from the entry
    // stack `dip` hands it.
    try testing.expectEqualSlices(
        InferredParamType,
        &.{ .float, .fixnum },
        result.quotations[0].inferred_param_types,
    );
}

test "a descent whose net effect contradicts the callee's arity is discarded" {
    const allocator = testing.allocator;

    // A word whose body calls a polymorphic native, which the freeze records with zero declared
    // arity. The body therefore consumes nothing while the word declares one input, and the two
    // literals it pushed stay behind for a later call in the caller's body to read as its own
    // operands. This is the shape a generated struct constructor has.
    const wrap_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 0 } }),
        at(.{ .push_literal = .{ .fixnum = 0 } }),
        at(.{ .call_word = "ctor" }),
    };
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .float = 1.5 } }),
        at(.{ .call_word = "wrap" }),
        at(.{ .call_word = "take2" }),
    };

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "wrap", .body = &wrap_body, .input_count = 1, .output_count = 1 },
        .{ .name = "ctor", .is_native = true },
        .{ .name = "take2", .body = &[_]Instruction{at(.{ .call_word = "drop" })}, .input_count = 2 },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqual(@as(usize, 0), wordParams(&result, "take2").len);
}

test "if merges its arms, and disagreeing arms leave the result opaque" {
    const allocator = testing.allocator;

    const then_body = [_]Instruction{at(.{ .push_literal = .{ .fixnum = 1 } })};
    const agree_else = [_]Instruction{at(.{ .push_literal = .{ .fixnum = 2 } })};
    const differ_else = [_]Instruction{at(.{ .push_literal = .{ .float = 2.0 } })};

    const agree_entry = [_]Instruction{
        at(.{ .call_word = "t" }),
        at(.{ .push_literal = .{ .quotation = .{ .instructions = &then_body } } }),
        at(.{ .push_literal = .{ .quotation = .{ .instructions = &agree_else } } }),
        at(.{ .call_word = "if" }),
        at(.{ .call_word = "take1" }),
    };
    const differ_entry = [_]Instruction{
        at(.{ .call_word = "t" }),
        at(.{ .push_literal = .{ .quotation = .{ .instructions = &then_body } } }),
        at(.{ .push_literal = .{ .quotation = .{ .instructions = &differ_else } } }),
        at(.{ .call_word = "if" }),
        at(.{ .call_word = "take1" }),
    };

    var agreed = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &agree_entry },
        .{ .name = "take1", .body = &[_]Instruction{at(.{ .call_word = "drop" })}, .input_count = 1 },
    }, &.{}, &.{});
    defer agreed.deinit(allocator);
    try inferParamTypes(&agreed, .{}, allocator);
    try testing.expectEqualSlices(InferredParamType, &.{.fixnum}, wordParams(&agreed, "take1"));

    var differed = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &differ_entry },
        .{ .name = "take1", .body = &[_]Instruction{at(.{ .call_word = "drop" })}, .input_count = 1 },
    }, &.{}, &.{});
    defer differed.deinit(allocator);
    try inferParamTypes(&differed, .{}, allocator);
    try testing.expectEqual(@as(usize, 0), wordParams(&differed, "take1").len);
}

test "float arithmetic is typed without the lock, fixnum arithmetic only with it" {
    const allocator = testing.allocator;

    // `count` recurses on `n - 1`, so its own parameter is only provable once the pass may type the
    // result of fixnum arithmetic. `widen` never recurses and stays on the float rule, which holds
    // in every build mode because float arithmetic does not promote.
    const count_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 1 } }),
        at(.{ .call_word = "-" }),
        at(.{ .call_word = "count" }),
    };
    const widen_body = [_]Instruction{
        at(.{ .push_literal = .{ .float = 1.0 } }),
        at(.{ .call_word = "+" }),
        at(.{ .call_word = "take-float" }),
    };
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 5 } }),
        at(.{ .call_word = "count" }),
        at(.{ .push_literal = .{ .float = 2.0 } }),
        at(.{ .call_word = "widen" }),
    };

    const words = [_]FixtureWord{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "count", .body = &count_body, .input_count = 1, .output_count = 1 },
        .{ .name = "widen", .body = &widen_body, .input_count = 1, .output_count = 1 },
        .{ .name = "take-float", .body = &[_]Instruction{at(.{ .call_word = "drop" })}, .input_count = 1, .output_count = 1 },
    };

    var unlocked = try fixture(allocator, &words, &.{}, &.{});
    defer unlocked.deinit(allocator);
    try inferParamTypes(&unlocked, .{ .arithmetic_result_types = false }, allocator);
    try testing.expectEqual(@as(usize, 0), wordParams(&unlocked, "count").len);
    try testing.expectEqualSlices(InferredParamType, &.{.float}, wordParams(&unlocked, "take-float"));

    var locked = try fixture(allocator, &words, &.{}, &.{});
    defer locked.deinit(allocator);
    try inferParamTypes(&locked, .{ .arithmetic_result_types = true }, allocator);
    try testing.expectEqualSlices(InferredParamType, &.{.fixnum}, wordParams(&locked, "count"));
    try testing.expectEqualSlices(InferredParamType, &.{.float}, wordParams(&locked, "take-float"));
}

test "a fully annotated callee output feeds the caller's proof under trust" {
    const allocator = testing.allocator;

    const fixnum_tv = value_mod.TypeValue{ .name = "fixnum", .descriptor = null };
    const float_tv = value_mod.TypeValue{ .name = "float", .descriptor = null };

    // `compute`'s body ends in an unmodelled native, so a descent yields unknown. Only the
    // declared output annotation can type its result, and only when the options trust it.
    const compute_effect = stack_effect_mod.StackEffect{
        .inputs = &.{},
        .outputs = &.{.{ .name = "r", .type_annotation = .{ .type = &fixnum_tv } }},
    };
    const compute_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 1 } }),
        at(.{ .call_word = "opaque-native" }),
    };
    const use_body = [_]Instruction{at(.{ .call_word = "drop" })};
    const entry_body = [_]Instruction{
        at(.{ .call_word = "compute" }),
        at(.{ .call_word = "use" }),
    };

    const words = [_]FixtureWord{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "compute", .body = &compute_body, .output_count = 1, .stack_effect = compute_effect },
        .{ .name = "use", .body = &use_body, .input_count = 1 },
        .{ .name = "opaque-native", .input_count = 1, .output_count = 1, .is_native = true },
    };

    var trusted = try fixture(allocator, &words, &.{}, &.{});
    defer trusted.deinit(allocator);
    try inferParamTypes(&trusted, .{ .fixnum_type = &fixnum_tv, .float_type = &float_tv }, allocator);
    try testing.expectEqualSlices(InferredParamType, &.{.fixnum_declared}, wordParams(&trusted, "use"));

    var untrusted = try fixture(allocator, &words, &.{}, &.{});
    defer untrusted.deinit(allocator);
    try inferParamTypes(&untrusted, .{}, allocator);
    try testing.expectEqual(@as(usize, 0), wordParams(&untrusted, "use").len);
}

test "verification demotes a parameter whose recursive call site cannot be typed" {
    const allocator = testing.allocator;

    // Seeding ignores the unknown the recursive site reports, so `x` is fixnum after the seed
    // rounds. Only verification, which treats an untypable site as disagreement, takes it back.
    const recur_body = [_]Instruction{
        at(.{ .call_word = "opaque-native" }),
        at(.{ .call_word = "recur" }),
    };
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .call_word = "recur" }),
    };

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "recur", .body = &recur_body, .input_count = 1, .output_count = 1 },
        .{ .name = "opaque-native", .input_count = 1, .output_count = 1, .is_native = true },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{ .arithmetic_result_types = true }, allocator);

    try testing.expectEqual(@as(usize, 0), wordParams(&result, "recur").len);
}

test "a quotation with a use the pass cannot model stays opaque" {
    const allocator = testing.allocator;

    // One `dip` site the pass models, and one push into a native it does not. The second use is a
    // real execution with operands the pass cannot name, so neither site may narrow the body.
    const quot_body = [_]Instruction{at(.{ .call_word = "dup" })};
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .push_literal = .{ .fixnum = 4 } }),
        at(.{ .push_literal = .{ .quotation = .{ .instructions = &quot_body } } }),
        at(.{ .call_word = "dip" }),
        at(.{ .push_literal = .{ .quotation = .{ .instructions = &quot_body } } }),
        at(.{ .call_word = "stash" }),
    };

    const words = [_]FixtureWord{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "stash", .input_count = 1, .is_native = true },
    };
    const quots = [_]FixtureQuot{.{ .body = &quot_body, .input_count = 1, .output_count = 2 }};

    var escaped = try fixture(allocator, &words, &quots, &.{});
    defer escaped.deinit(allocator);
    try inferParamTypes(&escaped, .{}, allocator);
    try testing.expectEqual(@as(usize, 0), escaped.quotations[0].inferred_param_types.len);

    // The same program without the unmodelled push narrows the body, so the escape rule is what
    // made the difference rather than some other gap.
    const modelled_entry = entry_body[0..4];
    var modelled = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = modelled_entry },
    }, &quots, &.{});
    defer modelled.deinit(allocator);
    try inferParamTypes(&modelled, .{}, allocator);
    try testing.expectEqualSlices(
        InferredParamType,
        &.{.fixnum},
        modelled.quotations[0].inferred_param_types,
    );
}

test "a word defined in 1z under a modelled native's name does not get the native's rule" {
    const allocator = testing.allocator;

    // The rules are keyed on a name, so a program that binds `dup` to its own definition must take
    // the ordinary compound path. Applying the native rule here would hand `take1` a fixnum the
    // program never produces.
    const dup_body = [_]Instruction{at(.{ .call_word = "opaque-native" })};
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .call_word = "dup" }),
        at(.{ .call_word = "take1" }),
    };

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "dup", .body = &dup_body, .input_count = 1, .output_count = 1 },
        .{ .name = "take1", .body = &[_]Instruction{at(.{ .call_word = "drop" })}, .input_count = 1 },
        .{ .name = "opaque-native", .input_count = 1, .output_count = 1, .is_native = true },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqual(@as(usize, 0), wordParams(&result, "take1").len);
}

test "a call inside a parameter default counts against the callee" {
    const allocator = testing.allocator;

    // A `parameter{ [ ... ] }` default body lands in neither `words` nor `quotations`: freeze seeds
    // its callees into the worklist without recording the body. Missing it would leave `scale` with
    // only the entry's fixnum site and prove a type the float site contradicts.
    const default_body = [_]Instruction{
        at(.{ .push_literal = .{ .float = 1.5 } }),
        at(.{ .call_word = "scale" }),
    };
    const thing = value_mod.Parameter{
        .name = "thing",
        .default_quotation = .{ .instructions = &default_body },
    };
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 5 } }),
        at(.{ .call_word = "scale" }),
        at(.{ .call_word = "drop" }),
        at(.{ .push_literal = .{ .parameter = @constCast(&thing) } }),
        at(.{ .call_word = "drop" }),
    };

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "scale", .body = &[_]Instruction{at(.{ .call_word = "dup" })}, .input_count = 1, .output_count = 1 },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqual(@as(usize, 0), wordParams(&result, "scale").len);
}

test "two descriptors sharing a name disqualify both" {
    const allocator = testing.allocator;

    // Codegen resolves every call site through one name-keyed map, so same-named descriptors
    // collapse onto a single binding and neither can claim the call sites naming it.
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .call_word = "amb" }),
    };
    const amb_body = [_]Instruction{at(.{ .call_word = "drop" })};

    var result = try fixture(allocator, &.{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "amb", .body = &amb_body, .input_count = 1 },
        .{ .name = "amb", .body = &amb_body, .input_count = 1 },
    }, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqual(@as(usize, 0), result.words[1].inferred_param_types.len);
    try testing.expectEqual(@as(usize, 0), result.words[2].inferred_param_types.len);
}

test "the caller index demotes a callee whose recorded call site the walk did not reach" {
    const allocator = testing.allocator;

    // `skipped` stands in for a body the census misses. It is marked native so `runCensus` passes
    // over it while `locateCallSite` still resolves a row against it, which is the shape the
    // cross-check exists to catch.
    const probe_body = [_]Instruction{at(.{ .call_word = "drop" })};
    const skipped_body = [_]Instruction{
        at(.{ .push_literal = .{ .float = 1.5 } }),
        at(.{ .call_word = "probe" }),
    };
    const entry_body = [_]Instruction{
        at(.{ .push_literal = .{ .fixnum = 3 } }),
        at(.{ .call_word = "probe" }),
    };

    const words = [_]FixtureWord{
        .{ .name = "__entry__", .body = &entry_body },
        .{ .name = "probe", .body = &probe_body, .input_count = 1 },
        .{ .name = "skipped", .body = &skipped_body, .is_native = true },
    };

    var unchecked = try fixture(allocator, &words, &.{}, &.{});
    defer unchecked.deinit(allocator);
    try inferParamTypes(&unchecked, .{}, allocator);
    try testing.expectEqualSlices(InferredParamType, &.{.fixnum}, wordParams(&unchecked, "probe"));

    const rows = [_]aot_freeze.CallTargetEntry{.{
        .caller_word_id = 2,
        .instruction_index = 1,
        .quotation_path = &.{},
        .resolved = .{ .compound = 1 },
    }};
    var checked = try fixture(allocator, &words, &.{}, &rows);
    defer checked.deinit(allocator);
    try inferParamTypes(&checked, .{}, allocator);
    try testing.expectEqual(@as(usize, 0), wordParams(&checked, "probe").len);
}

test "a parameter threaded through a call chain deeper than the round ceiling still converges" {
    const allocator = testing.allocator;
    const depth: usize = 40;

    var names = std.ArrayListUnmanaged([]u8){};
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var bodies = std.ArrayListUnmanaged([]Instruction){};
    defer {
        for (bodies.items) |b| allocator.free(b);
        bodies.deinit(allocator);
    }
    var words = std.ArrayListUnmanaged(FixtureWord){};
    defer words.deinit(allocator);

    for (0..depth) |i| {
        try names.append(allocator, try std.fmt.allocPrint(allocator, "w{d}", .{i}));
    }

    const entry = try allocator.alloc(Instruction, 3);
    defer allocator.free(entry);
    entry[0] = at(.{ .push_literal = .{ .fixnum = 7 } });
    entry[1] = at(.{ .call_word = names.items[0] });
    entry[2] = at(.{ .call_word = "drop" });
    try words.append(allocator, .{ .name = "__entry__", .body = entry });

    // Each link passes its own parameter straight to the next, so the last word's type is only
    // provable once the whole chain has been seeded. Seeding folds each observation in as it is
    // made, so this converges in a round or two rather than one round per link.
    for (0..depth) |i| {
        const body = try allocator.alloc(Instruction, if (i + 1 < depth) 1 else 2);
        if (i + 1 < depth) {
            body[0] = at(.{ .call_word = names.items[i + 1] });
        } else {
            body[0] = at(.{ .call_word = "dup" });
            body[1] = at(.{ .call_word = "drop" });
        }
        try bodies.append(allocator, body);
        try words.append(allocator, .{
            .name = names.items[i],
            .body = body,
            .input_count = 1,
            .output_count = 1,
        });
    }

    var result = try fixture(allocator, words.items, &.{}, &.{});
    defer result.deinit(allocator);

    try inferParamTypes(&result, .{}, allocator);

    try testing.expectEqualSlices(InferredParamType, &.{.fixnum}, wordParams(&result, names.items[0]));
    try testing.expectEqualSlices(InferredParamType, &.{.fixnum}, wordParams(&result, names.items[depth - 1]));
}

test "inferParamTypes throughput ceiling on a synthetic call chain" {
    // Ceiling, not a baseline diff. The pass re-walks every body once per fixpoint round, so its
    // cost needs its own guard rather than riding on the freeze ceilings.
    const allocator = testing.allocator;
    const word_count: usize = 200;
    const ceiling_ns: u64 = 500 * std.time.ns_per_ms;

    var names = std.ArrayListUnmanaged([]u8){};
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var bodies = std.ArrayListUnmanaged([]Instruction){};
    defer {
        for (bodies.items) |b| allocator.free(b);
        bodies.deinit(allocator);
    }
    var words = std.ArrayListUnmanaged(FixtureWord){};
    defer words.deinit(allocator);

    for (0..word_count) |i| {
        try names.append(allocator, try std.fmt.allocPrint(allocator, "w{d}", .{i}));
    }
    for (0..word_count) |i| {
        const body = try allocator.alloc(Instruction, 3);
        body[0] = at(.{ .call_word = "dup" });
        body[1] = at(.{ .push_literal = .{ .fixnum = 1 } });
        body[2] = at(.{ .call_word = names.items[(i + 1) % word_count] });
        try bodies.append(allocator, body);
        try words.append(allocator, .{
            .name = names.items[i],
            .body = body,
            .input_count = 1,
            .output_count = 1,
        });
    }

    var result = try fixture(allocator, words.items, &.{}, &.{});
    defer result.deinit(allocator);

    var timer = try std.time.Timer.start();
    try inferParamTypes(&result, .{ .arithmetic_result_types = true }, allocator);
    const elapsed_ns = timer.read();

    try testing.expect(elapsed_ns < ceiling_ns);
}
