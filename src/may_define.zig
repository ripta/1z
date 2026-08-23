//! Whether executing a body can install a word definition.
//!
//! The interpreter brackets every quotation execution in a transient lexical frame, so a
//! definition made during the execution lands above the import target and pops with the frame.
//! Compiled quotation dispatch pushes no such frame. Restoring it unconditionally would pay a
//! push and pop on per-element combinator invocations and per-iteration loop bodies, so the
//! bracket is gated on this analysis: a body that provably cannot define keeps its bare-call cost.
//!
//! The property is conservative in one direction only. Answering true where the truth is false
//! costs a frame; answering false where the truth is true drops a binding into the durable frame
//! the interpreter keeps it out of. So every construct the walk cannot see through answers true.

const std = @import("std");

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;

const ir_codegen = @import("ir_codegen.zig");
const WordResolver = ir_codegen.WordResolver;

/// Longest chain of nested bodies the walk descends. Exceeding it answers true.
const max_depth = 32;

/// Most call instructions the walk resolves before giving up and answering true. Bounds the
/// exponential blow-up a diamond-shaped call graph would otherwise cost, since the walk memoizes
/// nothing.
const max_visits = 4096;

/// Supplies the method bodies registered against a dispatch id.
///
/// A generic's registered method bodies run on the caller's current frame in the interpreter, so a
/// definition inside one lands in the calling quotation's transient frame. A resolver reports only
/// the generic's own default body, which leaves the methods invisible; this is how the walk reaches
/// them. Absent, every resolved callee answers true.
pub const MethodSource = struct {
    /// True when any method registered for `dispatch_id` may define a word. The supplier walks
    /// each method body back through `Walk.bodyMayDefine`, so the enclosing walk's cycle, depth,
    /// and visit bookkeeping covers them. A supplier that cannot answer returns true.
    ///
    /// Asked for every resolved callee, including ids that own no methods. Zero cannot serve as a
    /// "no dispatch identity" sentinel here, because `Context.next_dispatch_id` starts at zero and
    /// the first primitive registered owns that id. The supplier is what knows which ids own
    /// methods, and it is the place to cache the answer.
    anyMethodMayDefine: *const fn (user_data: *anyopaque, dispatch_id: u32, walk: *Walk) bool,
    user_data: *anyopaque,
};

/// Identity of a body on the walk's path. Address and length both, so a body and a sub-slice view
/// of it are two nodes rather than one.
const BodyKey = struct { ptr: usize, len: usize };

fn bodyKey(body: []const Instruction) BodyKey {
    return .{ .ptr = @intFromPtr(body.ptr), .len = body.len };
}

/// One traversal's scratch. Public so a `MethodSource` can re-enter the walk it was called from.
pub const Walk = struct {
    resolver: ?WordResolver,
    methods: ?MethodSource,
    /// Bodies currently being walked, innermost last.
    on_path: [max_depth]BodyKey = undefined,
    depth: usize = 0,
    visits: usize = max_visits,

    /// Whether executing `body` can install a word definition.
    ///
    /// Only `body`'s own top-level instructions are read. A quotation literal pushed by one of them
    /// is a separate body that brackets itself, so descending into it would flag this body for a
    /// definition it never makes.
    pub fn bodyMayDefine(self: *Walk, body: []const Instruction) bool {
        if (body.len == 0) return false;

        // A back edge contributes nothing. A cycle that reaches no definer defines nothing, and
        // one that does is caught by the frame that found the definer.
        //
        // Checked on entry rather than at the recursion site, so a `MethodSource` re-entering the
        // walk is covered by the same guard.
        if (self.onPath(body)) return false;

        if (self.depth == max_depth) return true;

        self.on_path[self.depth] = bodyKey(body);
        self.depth += 1;
        defer self.depth -= 1;

        for (body) |instr| {
            if (!instr.op.isCall()) continue;

            if (self.visits == 0) return true;
            self.visits -= 1;

            const name = instr.op.callTargetName().?;
            const res = self.resolver orelse return true;
            const resolved = res.resolve(name, res.user_data) orelse return true;

            if (resolved.defines_word) return true;

            const src = self.methods orelse return true;
            if (src.anyMethodMayDefine(src.user_data, resolved.dispatch_id, self)) return true;

            // A native carries no body to walk, and its bit and its methods are both already read
            // above. So a quotation combinator such as `call`, `if`, or `dip` is inert here. The
            // quotation it runs is a body of its own and brackets itself.
            if (resolved.is_native) continue;

            const callee = resolved.body orelse return true;
            if (self.bodyMayDefine(callee)) return true;
        }

        return false;
    }

    /// Whether `body` is already being walked further out.
    fn onPath(self: *const Walk, body: []const Instruction) bool {
        const key = bodyKey(body);
        for (self.on_path[0..self.depth]) |seen| {
            if (seen.ptr == key.ptr and seen.len == key.len) return true;
        }
        return false;
    }
};

/// Whether executing `body` can install a word definition. See `Walk.bodyMayDefine`.
pub fn bodyMayDefine(body: []const Instruction, resolver: ?WordResolver, methods: ?MethodSource) bool {
    var walk = Walk{ .resolver = resolver, .methods = methods };
    return walk.bodyMayDefine(body);
}

// =============================================================================
// Tests
// =============================================================================

const ResolvedWord = ir_codegen.ResolvedWord;

/// One row of a `TestResolver`'s table: the `ResolvedWord` fields the walk reads.
const TestWord = struct {
    name: []const u8,
    is_native: bool = false,
    defines_word: bool = false,
    dispatch_id: u32 = 0,
    body: ?[]const Instruction = null,
};

/// A resolver over a fixed name-to-word table, standing in for the freeze's `word_map` and the
/// interpreter's dictionary alike.
const TestResolver = struct {
    words: []const TestWord,

    fn resolve(name: []const u8, user_data: *anyopaque) ?ResolvedWord {
        const self: *const TestResolver = @ptrCast(@alignCast(user_data));
        for (self.words) |w| {
            if (!std.mem.eql(u8, w.name, name)) continue;
            return ResolvedWord{
                .word_id = 0,
                .input_count = 0,
                .output_count = 0,
                .is_native = w.is_native,
                .defines_word = w.defines_word,
                .dispatch_id = w.dispatch_id,
                .body = w.body,
            };
        }
        return null;
    }

    fn resolver(self: *TestResolver) WordResolver {
        return .{
            .resolve = &TestResolver.resolve,
            .user_data = @ptrCast(self),
            .dispatch_table_ptr = undefined,
        };
    }
};

/// A method source over one dispatch id's bodies. Every other id reports no methods.
const TestMethods = struct {
    dispatch_id: u32,
    bodies: []const []const Instruction,

    fn anyMethodMayDefine(user_data: *anyopaque, dispatch_id: u32, walk: *Walk) bool {
        const self: *const TestMethods = @ptrCast(@alignCast(user_data));
        if (dispatch_id != self.dispatch_id) return false;
        for (self.bodies) |b| {
            if (walk.bodyMayDefine(b)) return true;
        }
        return false;
    }

    fn source(self: *TestMethods) MethodSource {
        return .{ .anyMethodMayDefine = &TestMethods.anyMethodMayDefine, .user_data = @ptrCast(self) };
    }
};

var empty_methods = TestMethods{ .dispatch_id = 0, .bodies = &.{} };

/// A method source reporting no registered method for any id, for the cases where dispatch is not
/// what is under test.
fn noMethods() MethodSource {
    return empty_methods.source();
}

fn call(name: []const u8) Instruction {
    return .{ .op = .{ .call_word = name }, .line = 1 };
}

fn pushQuot(body: []const Instruction) Instruction {
    return .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = body } } }, .line = 1 };
}

const semicolon = TestWord{ .name = ";", .is_native = true, .defines_word = true };
const dup = TestWord{ .name = "dup", .is_native = true };
const call_word = TestWord{ .name = "call", .is_native = true };

test "an empty body defines nothing" {
    var data = TestResolver{ .words = &.{} };
    try std.testing.expect(!bodyMayDefine(&.{}, data.resolver(), noMethods()));
}

test "a body calling a define-family native flags" {
    var data = TestResolver{ .words = &.{ semicolon, dup } };
    const body = [_]Instruction{ call("dup"), call(";") };
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "a body of inert natives does not flag" {
    var data = TestResolver{ .words = &.{dup} };
    const body = [_]Instruction{ call("dup"), call("dup") };
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "a callee whose body defines flags its caller" {
    const definer_body = [_]Instruction{call(";")};
    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "definer", .body = &definer_body },
    } };
    const body = [_]Instruction{call("definer")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "the transitive walk reaches a definer two levels down" {
    const inner_body = [_]Instruction{call(";")};
    const middle_body = [_]Instruction{call("inner")};
    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "inner", .body = &inner_body },
        .{ .name = "middle", .body = &middle_body },
    } };
    const body = [_]Instruction{call("middle")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "a definition-free chain does not flag" {
    const inner_body = [_]Instruction{call("dup")};
    const middle_body = [_]Instruction{call("inner")};
    var data = TestResolver{ .words = &.{
        dup,
        .{ .name = "inner", .body = &inner_body },
        .{ .name = "middle", .body = &middle_body },
    } };
    const body = [_]Instruction{call("middle")};
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "mutual recursion with no definer terminates and does not flag" {
    const a_body = [_]Instruction{call("b")};
    const b_body = [_]Instruction{call("a")};
    var data = TestResolver{ .words = &.{
        .{ .name = "a", .body = &a_body },
        .{ .name = "b", .body = &b_body },
    } };
    try std.testing.expect(!bodyMayDefine(&a_body, data.resolver(), noMethods()));
    try std.testing.expect(!bodyMayDefine(&b_body, data.resolver(), noMethods()));
}

test "mutual recursion reaching a definer flags from either entry" {
    const a_body = [_]Instruction{call("b")};
    const b_body = [_]Instruction{ call("a"), call(";") };
    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "a", .body = &a_body },
        .{ .name = "b", .body = &b_body },
    } };
    try std.testing.expect(bodyMayDefine(&a_body, data.resolver(), noMethods()));
    try std.testing.expect(bodyMayDefine(&b_body, data.resolver(), noMethods()));
}

test "self recursion terminates" {
    const body = [_]Instruction{call("loop")};
    var data = TestResolver{ .words = &.{.{ .name = "loop", .body = &body }} };
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "an unresolvable callee flags" {
    var data = TestResolver{ .words = &.{} };
    const body = [_]Instruction{call("who-knows")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "a compound callee with no body at hand flags" {
    var data = TestResolver{ .words = &.{.{ .name = "bodiless" }} };
    const body = [_]Instruction{call("bodiless")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "a null resolver flags any body that calls" {
    const body = [_]Instruction{call("dup")};
    try std.testing.expect(bodyMayDefine(&body, null, null));
}

test "a null resolver leaves a call-free body alone" {
    const body = [_]Instruction{.{ .op = .{ .push_literal = .{ .fixnum = 1 } }, .line = 1 }};
    try std.testing.expect(!bodyMayDefine(&body, null, null));
}

test "a quotation literal containing a definition does not flag its parent" {
    const inner = [_]Instruction{call(";")};
    var data = TestResolver{ .words = &.{ semicolon, call_word } };
    const body = [_]Instruction{ pushQuot(&inner), call("call") };
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "a runtime-selected quotation call does not flag its caller" {
    // The quotation arrives from somewhere the body does not name, so `call` is all the walk sees.
    // Whatever body it dispatches to brackets itself, so `call` stays inert.
    var data = TestResolver{ .words = &.{ call_word, .{ .name = "pick-quot", .body = &[_]Instruction{call("dup")} }, dup } };
    const body = [_]Instruction{ call("pick-quot"), call("call") };
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), noMethods()));
}

test "a generic whose method defines flags its caller" {
    const method_body = [_]Instruction{call(";")};
    var methods = TestMethods{ .dispatch_id = 7, .bodies = &.{&method_body} };
    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "gen", .is_native = true, .dispatch_id = 7 },
    } };
    const body = [_]Instruction{call("gen")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), methods.source()));
}

test "a generic whose methods define nothing does not flag" {
    const method_body = [_]Instruction{call("dup")};
    var methods = TestMethods{ .dispatch_id = 7, .bodies = &.{&method_body} };
    var data = TestResolver{ .words = &.{
        dup,
        .{ .name = "gen", .is_native = true, .dispatch_id = 7 },
    } };
    const body = [_]Instruction{call("gen")};
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), methods.source()));
}

test "a null method source flags any resolved callee" {
    // With no method visibility, even an inert native could dispatch somewhere the walk cannot see.
    var data = TestResolver{ .words = &.{dup} };
    const body = [_]Instruction{call("dup")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), null));
}

test "dispatch id zero is asked about like any other" {
    // `Context.next_dispatch_id` starts at zero, so the first primitive registered owns that id.
    // The walk must not read it as "no dispatch identity" and skip the query.
    const method_body = [_]Instruction{call(";")};
    var methods = TestMethods{ .dispatch_id = 0, .bodies = &.{&method_body} };
    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "gen", .is_native = true, .dispatch_id = 0 },
    } };
    const body = [_]Instruction{call("gen")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), methods.source()));
}

test "a method body recursing into its own generic terminates" {
    const method_body = [_]Instruction{call("gen")};
    var methods = TestMethods{ .dispatch_id = 7, .bodies = &.{&method_body} };
    var data = TestResolver{ .words = &.{.{ .name = "gen", .is_native = true, .dispatch_id = 7 }} };
    const body = [_]Instruction{call("gen")};
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), methods.source()));
}

test "a chain deeper than the depth cap flags" {
    // Each level calls the next through a body of its own, so no back edge shortens the descent
    // and the walk runs out of depth before it runs out of chain.
    const depth = max_depth + 2;
    var names: [depth][3]u8 = undefined;
    var bodies: [depth][1]Instruction = undefined;
    var words: [depth]TestWord = undefined;
    for (0..depth) |i| {
        names[i] = .{ 'w', @intCast('a' + i / 10), @intCast('0' + i % 10) };
    }
    for (0..depth) |i| {
        const next = names[(i + 1) % depth][0..];
        bodies[i] = .{call(next)};
        words[i] = .{ .name = names[i][0..], .body = bodies[i][0..] };
    }
    var data = TestResolver{ .words = words[0..] };
    try std.testing.expect(bodyMayDefine(bodies[0][0..], data.resolver(), noMethods()));
}

test "exhausting the visit budget flags" {
    // A body of `max_visits + 1` inert calls resolves past the budget and answers conservatively.
    var body: [max_visits + 1]Instruction = undefined;
    for (&body) |*instr| instr.* = call("dup");
    var data = TestResolver{ .words = &.{dup} };
    try std.testing.expect(bodyMayDefine(body[0..], data.resolver(), noMethods()));
}
