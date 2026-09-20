//! Expansion of a marked word's body into its callers, run once per definition.
//!
//! The trigger and the engine are kept apart. `shouldInline` is the whole of the trigger: a word
//! carries the marker or it does not. Everything below it -- cycle detection, the relocation rule,
//! source-location handling -- is the engine, and applies the same way whatever selected the word.
//! An analysis-driven trigger added later feeds this engine rather than growing one of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;

const dict_mod = @import("dictionary.zig");
const WordDefinition = dict_mod.WordDefinition;

const container_backing = @import("container_backing.zig");
const markers_mod = @import("primitives/markers.zig");
const Context = @import("context.zig").Context;
const InlineRegion = @import("inline_region_table.zig").InlineRegion;

/// Whether this pass expands calls to `def`. The trigger is the marker and nothing else.
pub fn shouldInline(def: WordDefinition) bool {
    for (def.markers) |mk| {
        if (markers_mod.isInlineMarker(mk)) return true;
    }
    return false;
}

/// The body `body` becomes once every call this pass selects is replaced by the callee's own
/// instructions, or null when it selects none. Null is the overwhelmingly common answer, and
/// reaching it costs no allocation.
///
/// `defining` is the name the finished body is about to be installed under, and `caller_file` the
/// file it belongs to. The first is what `namesDefinition` recognizes, the second what `relocateOp`
/// guards: one decides whether a copy would create a self-call, the other whether it is moving.
///
/// The caller holds the write lock. Resolution reads the frame stack and the dictionary, and the
/// result is installed under the same acquisition.
pub fn expandBody(
    ctx: *Context,
    defining: []const u8,
    caller_file: []const u8,
    body: []const Instruction,
) Allocator.Error!?[]const Instruction {
    var ex: Expander = .{
        .ctx = ctx,
        .defining = defining,
        .caller_file = caller_file,
        .alloc = ctx.quotationAllocator(),
    };
    defer ex.open.deinit(ctx.allocator);
    defer ex.regions.deinit(ctx.allocator);

    if (!ex.anyExpandableCall(body)) return null;

    errdefer ex.out.deinit(ex.alloc);
    try ex.out.ensureTotalCapacity(ex.alloc, body.len);

    // Both decline rules apply only to a copied instruction, so nothing at this level can decline.
    const complete = try ex.appendBody(body, .{ .file = caller_file, .relocating = false });
    std.debug.assert(complete);

    const expanded = try ex.out.toOwnedSlice(ex.alloc);

    // Recorded here rather than by the caller, because the list is scratch that dies with the
    // expander. The table copies what it keeps.
    try ctx.recordInlineRegions(expanded, ex.regions.items);

    // Each container literal in the new body is a second owning reference, whichever body it was
    // copied from. The array it came from keeps its own registration and releases the first; the
    // registration this one picks up at installation releases the second.
    //
    // A push the pass inserted for a bound value is the same second reference against a different
    // first. The binding holds that one on a ledger of its own: the frame for a transient leaf
    // binding, the dictionary's retained-values list for a durable one.
    //
    // Retaining uniformly rather than only for a callee's literals is what keeps a body defined
    // repeatedly from the same parsed array balanced. Each definition produces a distinct expanded
    // array with a registration of its own, and a rule that moved the original's references
    // instead would have them released once per definition.
    //
    // It rests on the source array being registered somewhere. Every body the parser and the image
    // loader build is; a body a native assembles is not, and one carrying a refcounted literal
    // would leak that first reference here. No definer builds one today.
    container_backing.retainInstructionsContainerLiterals(expanded);

    return expanded;
}

/// What the pass puts in place of a call it selects.
const Replacement = union(enum) {
    body: Body,

    /// A bound value, pushed where the call stood. A binding and the one-instruction push body a
    /// module import would already have turned it into are one case here, so which side of an
    /// import a caller sits on does not decide whether it expands.
    ///
    /// A value calls nothing, so it opens no cycle, and it carries no name that could resolve
    /// differently in another module.
    value: Value,

    const Body = struct {
        instrs: []const Instruction,

        /// The callee's own name and file, which is what the region recorded over the copy
        /// reports. The file is not the expanded array's, once a word is inlined across a module
        /// boundary, and the copied instructions keep the lines they were written at.
        name: []const u8,
        file: []const u8,

        /// Set when the callee belongs to another file, so its instructions have to survive the
        /// move.
        relocating: bool,
    };
};

/// The body a walk is currently copying from.
const BodyContext = struct {
    /// The file that body's instructions were written in, which a region recorded inside it
    /// reports as the file of its own call site.
    file: []const u8,

    /// Set when the instructions are moving to a body in another file.
    relocating: bool,
};

const Expander = struct {
    ctx: *Context,
    defining: []const u8,
    caller_file: []const u8,
    alloc: Allocator,
    out: std.ArrayListUnmanaged(Instruction) = .{},

    /// The bodies currently being copied, innermost last, identified by their instruction-array
    /// address. A call reaching one of them would expand forever, so it stays a call.
    ///
    /// The address identifies the code rather than the word, which is what cycle detection is
    /// about. Two names sharing one body through a reexport are one entry here, correctly.
    open: std.ArrayListUnmanaged(usize) = .{},

    /// The runs of `out` copied out of an `inline` word, recorded so a raise inside one can name
    /// that word. Scratch: `expandBody` hands the finished list to the table, which copies it.
    ///
    /// Ordered so that, for any index, the runs covering it appear innermost first. `appendOne`
    /// records a callee's own run after recursing into it, and `appendBody` translates the runs
    /// already inside the body it is copying after its loop, so an outer run is always appended
    /// after everything nested in it.
    regions: std.ArrayListUnmanaged(InlineRegion) = .{},

    /// The definition a call instruction targets, or null when it resolves to nothing. A miss is
    /// not an error: the call stays a call and resolves at run time as it does today.
    fn target(self: *const Expander, op: Instruction.Op) ?WordDefinition {
        return switch (op) {
            .push_literal => null,
            .call_word => |name| self.ctx.inlineCallTargetLocked(name),
            .call_word_direct, .call_word_module => |slot| dict_mod.loadSlot(slot).*,
        };
    }

    /// What this pass would put in place of a call to `op`'s target, or null when it would put
    /// nothing. `current_file` is the file of the body the call sits in, which stands in for a
    /// callee that records none of its own.
    ///
    /// Cycle detection is deliberately not applied here, so the pre-scan sees a recursive word as
    /// expandable. It is, at its first level.
    fn expandable(self: *const Expander, op: Instruction.Op, current_file: []const u8) ?Replacement {
        if (!op.isCall()) return null;
        const callee = self.target(op) orelse return null;
        if (!shouldInline(callee)) return null;
        return switch (callee.action) {
            .compound => |instrs| .{ .body = .{
                .instrs = instrs,
                .name = callee.name,
                .file = callee.source_file orelse current_file,
                .relocating = !self.definedInCallerFile(callee),
            } },
            .literal => |val| .{ .value = val },
            // Neither a native nor a host callback has anything to put in place of the call.
            .native, .host_callback => null,
        };
    }

    fn anyExpandableCall(self: *const Expander, body: []const Instruction) bool {
        for (body) |instr| {
            if (self.expandable(instr.op, self.caller_file) != null) return true;
        }
        return false;
    }

    fn isOpen(self: *const Expander, body: []const Instruction) bool {
        for (self.open.items) |addr| {
            if (addr == @intFromPtr(body.ptr)) return true;
        }
        return false;
    }

    /// Append `body`'s instructions, expanding the calls this pass selects.
    ///
    /// Returns false when one of them would not, having left `out` and `regions` exactly as they
    /// were found so the caller can emit the original call instead. Discarding costs nothing to
    /// undo, because the walk takes no reference: every literal in the finished array is retained
    /// in one pass at the end.
    fn appendBody(self: *Expander, body: []const Instruction, ctxt: BodyContext) Allocator.Error!bool {
        const out_mark = self.out.items.len;
        const region_mark = self.regions.items.len;

        // `body` may already carry runs of its own, because expansion is eager: a chain arrives
        // flat, with each level's attribution recorded against the level below it. Carrying those
        // forward is what makes a transitive chain name every word in it.
        //
        // The copy is not one instruction to one, since a call this body declined can expand here,
        // so each source index is mapped to where it landed rather than shifted by a constant.
        const source_regions = self.ctx.inlineRegionsFor(body);
        var map: []u32 = &.{};
        defer if (map.len != 0) self.ctx.allocator.free(map);
        if (source_regions != null) map = try self.ctx.allocator.alloc(u32, body.len + 1);

        for (body, 0..) |instr, i| {
            if (map.len != 0) map[i] = @intCast(self.out.items.len);

            if (try self.appendOne(instr, ctxt)) continue;

            self.out.shrinkRetainingCapacity(out_mark);
            self.regions.shrinkRetainingCapacity(region_mark);
            return false;
        }

        if (source_regions) |set| {
            map[body.len] = @intCast(self.out.items.len);
            for (set.regions) |r| {
                var moved = r;
                moved.start = map[r.start];
                moved.end = map[r.end];

                // An empty run has no instruction to raise from. One arises when every instruction
                // it covered expanded to nothing, which an `inline` word with an empty body does.
                if (moved.start == moved.end) continue;

                try self.regions.append(self.ctx.allocator, moved);
            }
        }

        return true;
    }

    /// Whether `op` calls the word being defined, from inside a body being copied into it.
    ///
    /// The definition under construction is the outermost open body. It is absent from `open`
    /// only because it has no installed instruction array yet to key on, so it is recognized by
    /// name instead.
    ///
    /// Without this, a callee's forward reference to a name that did not exist when the callee was
    /// defined becomes a direct self-call once the caller claims that name. `;` checks a body for
    /// a non-tail self-call before handing it over, so one introduced here is never checked at
    /// all. It also breaks the marker's own promise: a body would then depend on whether some
    /// other word carries `inline`.
    fn namesDefinition(self: *const Expander, op: Instruction.Op) bool {
        if (self.open.items.len == 0) return false;

        const name = op.callTargetName() orelse return false;
        return std.mem.eql(u8, name, self.defining);
    }

    fn appendOne(self: *Expander, instr: Instruction, ctxt: BodyContext) Allocator.Error!bool {
        if (self.namesDefinition(instr.op)) return false;

        if (self.expandable(instr.op, ctxt.file)) |what| switch (what) {
            .body => |b| {
                if (!self.isOpen(b.instrs)) {
                    const start = self.out.items.len;

                    try self.open.append(self.ctx.allocator, @intFromPtr(b.instrs.ptr));
                    defer _ = self.open.pop();

                    if (try self.appendBody(b.instrs, .{ .file = b.file, .relocating = b.relocating })) {
                        try self.recordRegion(start, b, instr);
                        return true;
                    }
                }
            },
            // This arm never declines. `namesDefinition` has already run, and a value carries no
            // name for the relocation rule to bind.
            //
            // The push takes the call's own line and column. A bound value has none of its own,
            // and the array being built is stamped with this file rather than the binding's.
            .value => |val| {
                try self.out.append(self.alloc, .{
                    .op = .{ .push_literal = val },
                    .line = instr.line,
                    .column = instr.column,
                });
                return true;
            },
        };

        // An instruction the pass did not replace. It keeps its own line and column, so a location
        // inside an expanded region still points at the source that wrote it. The region recorded
        // over that copy is what says which file the line belongs to.
        if (!ctxt.relocating) {
            try self.out.append(self.alloc, instr);
            return true;
        }

        const op = relocateOp(self.ctx, instr.op) orelse return false;
        try self.out.append(self.alloc, .{ .op = op, .line = instr.line, .column = instr.column });
        return true;
    }

    /// Record the run `[start, out.items.len)` as `b`'s code, called at `instr`.
    ///
    /// Recorded after the recursion, so a run nested inside this one is already in the list and a
    /// reader walking in order meets the innermost first.
    fn recordRegion(self: *Expander, start: usize, b: Replacement.Body, instr: Instruction) Allocator.Error!void {
        // An `inline` word with an empty body leaves nothing to attribute.
        if (self.out.items.len == start) return;

        try self.regions.append(self.ctx.allocator, .{
            .start = @intCast(start),
            .end = @intCast(self.out.items.len),
            .word_name = b.name,
            .body_source = b.file,
            .call_line = @intCast(instr.line),
            .call_column = @intCast(instr.column),
        });
    }

    fn definedInCallerFile(self: *const Expander, callee: WordDefinition) bool {
        const file = callee.source_file orelse return false;
        return std.mem.eql(u8, file, self.caller_file);
    }
};

/// The form `op` has to take to mean the same thing in a body belonging to another module, or null
/// when it cannot take one.
///
/// A body's bare words resolve against the defining module of whatever body is executing. The
/// expanded array is stamped with the caller's module rather than the callee's. So a name copied
/// out of another module has to stop being a name. `preResolveCallTargetLocked` binds it to the
/// dictionary slot its own module would have reached, on the same provably-parse-time-equals-runtime
/// terms the parser pre-resolves on.
///
/// A name that cannot be bound declines, and the expansion around it falls back to a call.
/// Declining costs a dispatch. Getting this wrong calls a different word and says nothing.
fn relocateOp(ctx: *const Context, op: Instruction.Op) ?Instruction.Op {
    return switch (op) {
        .push_literal, .call_word_direct => op,
        .call_word => |name| if (ctx.preResolveCallTargetLocked(name)) |slot|
            Instruction.Op{ .call_word_direct = slot }
        else
            null,
        // The image's own build-time resolution, against a module scope this body is leaving.
        .call_word_module => null,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const Marker = value_mod.Marker;

const here = "inline_expand_test.1z";
const elsewhere = "other.1z";

var const_inline = [_]*Marker{
    @constCast(&markers_mod.const_marker),
    @constCast(&markers_mod.inline_marker),
};

/// Define `name` over `body` directly, bypassing `;` so a test names an exact instruction array.
fn define(ctx: *Context, file: []const u8, name: []const u8, body: []const Instruction, marked: bool) !void {
    try ctx.defineWord(name, .{
        .name = name,
        .source_file = file,
        .markers = if (marked) &const_inline else &.{},
        .action = .{ .compound = body },
    });
}

/// Bind `value` to `name` directly, the `.literal` shape `;` gives a bracket-less binding.
fn bind(ctx: *Context, file: []const u8, name: []const u8, value: Value, marked: bool) !void {
    try ctx.defineWord(name, .{
        .name = name,
        .source_file = file,
        .markers = if (marked) &const_inline else &.{},
        .action = .{ .literal = value },
    });
}

/// One entry per instruction in `name`'s stored body: a call's target name, or `#` for a literal.
fn ops(ctx: *Context, name: []const u8, buf: [][]const u8) [][]const u8 {
    const body = ctx.lookupWord(name).?.action.compound;
    for (body, 0..) |instr, i| {
        buf[i] = instr.op.callTargetName() orelse "#";
    }
    return buf[0..body.len];
}

/// The runs recorded over `name`'s stored body.
fn regionsOf(ctx: *Context, name: []const u8) ?[]const InlineRegion {
    const body = ctx.lookupWord(name).?.action.compound;
    const set = ctx.inlineRegionsFor(body) orelse return null;
    return set.regions;
}

fn expectOps(ctx: *Context, name: []const u8, want: []const []const u8) !void {
    var buf: [32][]const u8 = undefined;
    const got = ops(ctx, name, &buf);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a call to an inline word is replaced by that word's body" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "doubled", &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    }, true);

    try define(&ctx, here, "quadruple", &.{
        .{ .op = .{ .call_word = "doubled" }, .line = 2 },
        .{ .op = .{ .call_word = "doubled" }, .line = 2 },
    }, false);

    try expectOps(&ctx, "quadruple", &.{ "#", "*", "#", "*" });
}

test "an expanded instruction keeps the line and column it was written at" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "doubled", &.{
        .{ .op = .{ .call_word = "*" }, .line = 7, .column = 21 },
    }, true);

    try define(&ctx, here, "quadruple", &.{
        .{ .op = .{ .call_word = "doubled" }, .line = 40, .column = 3 },
    }, false);

    const body = ctx.lookupWord("quadruple").?.action.compound;
    try testing.expectEqual(@as(usize, 7), body[0].line);
    try testing.expectEqual(@as(usize, 21), body[0].column);
}

test "a chain of inline words expands through every level" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "one", &.{
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    }, true);

    try define(&ctx, here, "two", &.{
        .{ .op = .{ .call_word = "one" }, .line = 2 },
        .{ .op = .{ .call_word = "one" }, .line = 2 },
    }, true);

    // Expansion is eager, so `two` is already flat by the time `three` reaches it. The chain is
    // never re-walked from the outermost caller.
    try expectOps(&ctx, "two", &.{ "+", "+" });

    try define(&ctx, here, "three", &.{
        .{ .op = .{ .call_word = "two" }, .line = 3 },
    }, false);

    try expectOps(&ctx, "three", &.{ "+", "+" });
}

test "a call re-entering a word already being copied stays a call" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    // `down` calls itself. Its own definition expands nothing, because the name resolves to nothing
    // yet. A later caller does, and has to stop after one level.
    try define(&ctx, here, "down", &.{
        .{ .op = .{ .call_word = "-" }, .line = 1 },
        .{ .op = .{ .call_word = "down" }, .line = 1 },
    }, true);

    try expectOps(&ctx, "down", &.{ "-", "down" });

    try define(&ctx, here, "drive", &.{
        .{ .op = .{ .call_word = "down" }, .line = 2 },
    }, false);

    try expectOps(&ctx, "drive", &.{ "-", "down" });
}

test "mutual recursion between two inline words terminates" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "ping", &.{
        .{ .op = .{ .call_word = "pong" }, .line = 1 },
    }, true);

    try define(&ctx, here, "pong", &.{
        .{ .op = .{ .call_word = "+" }, .line = 2 },
        .{ .op = .{ .call_word = "ping" }, .line = 2 },
    }, true);

    // `pong`'s definition reaches `ping`, whose body names `pong` itself. A copy naming the word
    // being defined is declined, so `pong` keeps the call it was written with.
    try expectOps(&ctx, "pong", &.{ "+", "ping" });

    // Neither name is the one being defined now, so both expand. The chain stops at the call to
    // `pong`, whose body is open by then, rather than alternating forever.
    try define(&ctx, here, "drive", &.{
        .{ .op = .{ .call_word = "pong" }, .line = 3 },
    }, false);

    try expectOps(&ctx, "drive", &.{ "+", "pong" });
}

test "a call_word_direct target is expanded like any other" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "doubled", &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    }, true);

    // The parser emits this form only for a name it proved unshadowable, which a frame-held word
    // never is. Built by hand so the arm is covered whatever the parser chooses.
    const slot = ctx.dictionary.getSlot("doubled") orelse return error.TestExpectedSlot;

    try define(&ctx, here, "quadruple", &.{
        .{ .op = .{ .call_word_direct = slot }, .line = 2 },
    }, false);

    try expectOps(&ctx, "quadruple", &.{ "#", "*" });
}

test "an unmarked word is left alone" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "plain", &.{
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    }, false);

    try define(&ctx, here, "caller", &.{
        .{ .op = .{ .call_word = "plain" }, .line = 2 },
    }, false);

    try expectOps(&ctx, "caller", &.{"plain"});
}

test "a body from another file expands only when its calls can be bound to a slot" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    // A frame holds this one, so no dictionary slot names it. That is the shape a module-private
    // helper has, and the reason a body reaching one cannot leave its own module.
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();

    try define(&ctx, here, "(helper)", &.{
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    }, false);

    try define(&ctx, elsewhere, "reaches-a-frame-word", &.{
        .{ .op = .{ .call_word = "(helper)" }, .line = 1 },
    }, true);

    try define(&ctx, elsewhere, "reaches-a-native", &.{
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    }, true);

    try define(&ctx, here, "calls-both", &.{
        .{ .op = .{ .call_word = "reaches-a-frame-word" }, .line = 2 },
        .{ .op = .{ .call_word = "reaches-a-native" }, .line = 2 },
    }, false);

    try expectOps(&ctx, "calls-both", &.{ "reaches-a-frame-word", "+" });
}

test "a copy that would name the word being defined declines" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    // `bump` names a word that does not exist yet, so the name stays a name.
    try define(&ctx, here, "bump", &.{
        .{ .op = .{ .call_word = "grow" }, .line = 1 },
    }, true);

    // `grow` then claims that name. Copying `bump` here would put a call to `grow` inside `grow`,
    // which `;` already checked for a non-tail self-call and did not find one.
    try define(&ctx, here, "grow", &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 2 },
        .{ .op = .{ .call_word = "bump" }, .line = 2 },
        .{ .op = .{ .call_word = "+" }, .line = 2 },
    }, false);

    try expectOps(&ctx, "grow", &.{ "#", "bump", "+" });
}

test "a word naming itself in its own body is still expanded around" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "doubled", &.{
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    }, true);

    // The decline covers a copied instruction only. A self-call the author wrote is the body `;`
    // checked, so it is emitted as it stands and the inline call beside it still expands.
    try define(&ctx, here, "walks", &.{
        .{ .op = .{ .call_word = "doubled" }, .line = 2 },
        .{ .op = .{ .call_word = "walks" }, .line = 2 },
    }, false);

    try expectOps(&ctx, "walks", &.{ "*", "walks" });
}

test "a closure-bodied definition is left alone" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "doubled", &.{
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    }, true);

    const body = [_]Instruction{
        .{ .op = .{ .call_word = "doubled" }, .line = 2 },
    };

    // Nothing reads the header: the pass declines on `body_owner` alone, and no path here retains
    // or releases the closure.
    var closure = value_mod.Closure{ .instructions = &body, .segments = &.{}, .header = undefined };

    // Replacing the array would move it out from under `ownsBody`, which compares addresses to
    // decide whether the closure's captured scope applies to the execution.
    try ctx.defineWord("held", .{
        .name = "held",
        .source_file = here,
        .body_owner = &closure,
        .action = .{ .compound = &body },
    });

    try expectOps(&ctx, "held", &.{"doubled"});
    try testing.expectEqual(@intFromPtr(&body), @intFromPtr(ctx.lookupWord("held").?.action.compound.ptr));
}

test "a call to a marked binding becomes a push of the bound value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try bind(&ctx, here, "width", .{ .fixnum = 256 }, true);

    try define(&ctx, here, "area", &.{
        .{ .op = .{ .call_word = "width" }, .line = 9, .column = 8 },
        .{ .op = .{ .call_word = "width" }, .line = 9, .column = 14 },
        .{ .op = .{ .call_word = "*" }, .line = 9, .column = 20 },
    }, false);

    try expectOps(&ctx, "area", &.{ "#", "#", "*" });

    const body = ctx.lookupWord("area").?.action.compound;
    try testing.expectEqual(@as(i64, 256), body[0].op.push_literal.fixnum);
    try testing.expectEqual(@as(i64, 256), body[1].op.push_literal.fixnum);

    // A bound value has no instruction of its own to take a location from, so each push carries
    // the call's. That is the only pairing where the line and the body's file agree.
    try testing.expectEqual(@as(usize, 9), body[0].line);
    try testing.expectEqual(@as(usize, 8), body[0].column);
    try testing.expectEqual(@as(usize, 14), body[1].column);
}

test "a bound value copied out of another file needs no slot to bind to" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    // A frame holds the binding, so no dictionary slot names it. A body reaching a frame-held
    // word cannot leave its own file, which is what the test above this one covers.
    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();

    try bind(&ctx, elsewhere, "(width)", .{ .fixnum = 256 }, true);

    try define(&ctx, elsewhere, "sized", &.{
        .{ .op = .{ .call_word = "(width)" }, .line = 1 },
    }, true);

    // Expansion is eager, so `sized` carries the value rather than the name by the time anything
    // copies it. There is no name left for the move to bind.
    try expectOps(&ctx, "sized", &.{"#"});

    try define(&ctx, here, "reads-it", &.{
        .{ .op = .{ .call_word = "sized" }, .line = 2 },
    }, false);

    const body = ctx.lookupWord("reads-it").?.action.compound;
    try testing.expectEqual(@as(usize, 1), body.len);
    try testing.expectEqual(@as(i64, 256), body[0].op.push_literal.fixnum);
}

test "each copy of a bound container carries a reference of its own" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    const vec = try value_mod.Vector.create(ctx.allocator);

    // The binding adopts the creation reference rather than taking one, so this reads 1.
    try bind(&ctx, here, "shared", .{ .vector = vec }, true);
    const before = vec.header.refcountValue();

    try define(&ctx, here, "twice", &.{
        .{ .op = .{ .call_word = "shared" }, .line = 2 },
        .{ .op = .{ .call_word = "shared" }, .line = 2 },
    }, false);

    // An inserted push is a second owning reference the same way a copied one is, and lands on
    // the same teardown walk. The binding's own reference sits on the dictionary's retained
    // values, so the three are released once each and the allocator sees one destroy.
    try testing.expectEqual(before + 2, vec.header.refcountValue());
}

test "each copy of a container literal carries a reference of its own" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    const vec = try value_mod.Vector.create(ctx.allocator);

    try define(&ctx, here, "pushes-a-vector", &.{
        .{ .op = .{ .push_literal = .{ .vector = vec } }, .line = 1 },
    }, true);

    const before = vec.header.refcountValue();

    try define(&ctx, here, "twice", &.{
        .{ .op = .{ .call_word = "pushes-a-vector" }, .line = 2 },
        .{ .op = .{ .call_word = "pushes-a-vector" }, .line = 2 },
    }, false);

    // One per occurrence, balancing the one release per occurrence the teardown walk performs over
    // the expanded body. Teardown itself is the other half of this assertion: the allocator checks
    // that the backing was destroyed exactly once.
    try testing.expectEqual(before + 2, vec.header.refcountValue());
}

test "an expanded call records the run it produced, the word it came from, and its call site" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "doubled", &.{
        .{ .op = .{ .push_literal = .{ .fixnum = 2 } }, .line = 1 },
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    }, true);

    try define(&ctx, here, "quadruple", &.{
        .{ .op = .{ .call_word = "doubled" }, .line = 5, .column = 3 },
        .{ .op = .{ .call_word = "doubled" }, .line = 5, .column = 11 },
    }, false);

    const regions = regionsOf(&ctx, "quadruple") orelse return error.TestExpectedRegions;
    try testing.expectEqual(@as(usize, 2), regions.len);

    try testing.expectEqual(@as(u32, 0), regions[0].start);
    try testing.expectEqual(@as(u32, 2), regions[0].end);
    try testing.expectEqualStrings("doubled", regions[0].word_name);
    try testing.expectEqualStrings(here, regions[0].body_source);
    try testing.expectEqual(@as(u32, 5), regions[0].call_line);
    try testing.expectEqual(@as(u32, 3), regions[0].call_column);

    // The second copy of one word is its own run, at its own call site.
    try testing.expectEqual(@as(u32, 2), regions[1].start);
    try testing.expectEqual(@as(u32, 4), regions[1].end);
    try testing.expectEqual(@as(u32, 11), regions[1].call_column);
}

test "a chain records every level, innermost first" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "one", &.{
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    }, true);

    try define(&ctx, here, "two", &.{
        .{ .op = .{ .call_word = "one" }, .line = 2 },
    }, true);

    try define(&ctx, here, "three", &.{
        .{ .op = .{ .call_word = "two" }, .line = 3 },
    }, false);

    // `two` arrives flat, so its own attribution has to travel with the copy. Without that, the
    // chain would name only the word `three` was written against.
    const body = ctx.lookupWord("three").?.action.compound;
    const set = ctx.inlineRegionsFor(body) orelse return error.TestExpectedRegions;
    var frames = set.framesAt(0, here);

    const inner = frames.next() orelse return error.TestExpectedFrame;
    try testing.expectEqualStrings("one", inner.word_name);
    try testing.expectEqual(@as(u32, 2), inner.call_line);

    const outer = frames.next() orelse return error.TestExpectedFrame;
    try testing.expectEqualStrings("two", outer.word_name);
    try testing.expectEqual(@as(u32, 3), outer.call_line);

    try testing.expect(frames.next() == null);
}

test "a declined copy records no run, and the copy beside it keeps the callee's file" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try ctx.pushLocalFrame();
    defer ctx.popLocalFrame();

    try define(&ctx, here, "(helper)", &.{
        .{ .op = .{ .call_word = "+" }, .line = 1 },
    }, false);

    try define(&ctx, elsewhere, "reaches-a-frame-word", &.{
        .{ .op = .{ .call_word = "(helper)" }, .line = 1 },
    }, true);

    try define(&ctx, elsewhere, "reaches-a-native", &.{
        .{ .op = .{ .call_word = "+" }, .line = 4 },
    }, true);

    try define(&ctx, here, "calls-both", &.{
        .{ .op = .{ .call_word = "reaches-a-frame-word" }, .line = 9 },
        .{ .op = .{ .call_word = "reaches-a-native" }, .line = 10 },
    }, false);

    const regions = regionsOf(&ctx, "calls-both") orelse return error.TestExpectedRegions;
    try testing.expectEqual(@as(usize, 1), regions.len);

    // The declined copy left a call at index 0, so the one run starts at 1.
    try testing.expectEqual(@as(u32, 1), regions[0].start);
    try testing.expectEqual(@as(u32, 2), regions[0].end);
    try testing.expectEqualStrings("reaches-a-native", regions[0].word_name);

    // The copied instruction kept line 4, which is a line in the file that wrote it rather than
    // in the file it now sits in.
    try testing.expectEqualStrings(elsewhere, regions[0].body_source);
    try testing.expectEqual(@as(u32, 10), regions[0].call_line);
}

test "a bound value opens no run" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try bind(&ctx, here, "width", .{ .fixnum = 256 }, true);

    try define(&ctx, here, "area", &.{
        .{ .op = .{ .call_word = "width" }, .line = 9 },
        .{ .op = .{ .call_word = "width" }, .line = 9 },
        .{ .op = .{ .call_word = "*" }, .line = 9 },
    }, false);

    // A value has no code, so there is nothing for a raise inside it to be attributed to.
    try testing.expectEqual(@as(?[]const InlineRegion, null), regionsOf(&ctx, "area"));
}

test "a word whose call declined mid-body records the runs that survived" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    ctx.current_source = here;

    try define(&ctx, here, "doubled", &.{
        .{ .op = .{ .call_word = "*" }, .line = 1 },
    }, true);

    // `bump` names a word that does not exist yet; `grow` then claims that name, so copying
    // `bump` into `grow` is declined. The marked call beside it still expands.
    try define(&ctx, here, "bump", &.{
        .{ .op = .{ .call_word = "grow" }, .line = 2 },
    }, true);

    try define(&ctx, here, "grow", &.{
        .{ .op = .{ .call_word = "bump" }, .line = 3 },
        .{ .op = .{ .call_word = "doubled" }, .line = 4 },
    }, false);

    try expectOps(&ctx, "grow", &.{ "bump", "*" });

    const regions = regionsOf(&ctx, "grow") orelse return error.TestExpectedRegions;
    try testing.expectEqual(@as(usize, 1), regions.len);
    try testing.expectEqualStrings("doubled", regions[0].word_name);
    try testing.expectEqual(@as(u32, 1), regions[0].start);
    try testing.expectEqual(@as(u32, 2), regions[0].end);
}
