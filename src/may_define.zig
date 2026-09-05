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
//!
//! A word body is bracketed the same way, on every tier, when it calls a defining native at its
//! own top level; `bodyCallsDefiningNative` is that gate. It reads no callee: a compound callee
//! that defines brackets itself, and a pushed quotation literal is a separate body.

const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;

const dispatch_mod = @import("dispatch.zig");
const DispatchTable = dispatch_mod.DispatchTable;

const primitives = @import("primitives.zig");

const ir_codegen = @import("ir_codegen.zig");
const WordResolver = ir_codegen.WordResolver;

/// Longest chain of nested bodies the walk descends. Exceeding it answers true.
const max_depth = 32;

/// Most call instructions the walk resolves before giving up and answering true. Bounds the
/// blow-up a diamond-shaped call graph costs on the paths a `Memo` cannot shorten.
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

/// `Walk.cycle_floor` when no back edge has been seen. Above every reachable depth.
const no_cycle = std.math.maxInt(usize);

/// Identity of a body on the walk's path. Address and length both, so a body and a sub-slice view
/// of it are two nodes rather than one.
const BodyKey = struct { ptr: usize, len: usize };

fn bodyKey(body: []const Instruction) BodyKey {
    return .{ .ptr = @intFromPtr(body.ptr), .len = body.len };
}

/// Answers carried between walks, so the callee closure below a body is descended once rather
/// than once per splice site.
///
/// Only an answer the walk reached without a path-dependent shortcut is stored. A back edge and an
/// exhausted budget each answer from where the walk happens to be rather than from the body alone.
/// A budget is the walk's, so exhausting one stops caching outright; a cycle is local, so it stops
/// caching only for the bodies between the back edge and the one it points at.
///
/// A memo is valid only while every name resolves the same way, which means one resolver binding.
/// The AOT driver rebinds its callee scope per compiled body, so a memo lives exactly as long as
/// the `CompileState` that owns it.
pub const Memo = struct {
    entries: std.AutoHashMapUnmanaged(BodyKey, bool) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator) Memo {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Memo) void {
        self.entries.deinit(self.allocator);
    }
};

/// One traversal's scratch. Public so a `MethodSource` can re-enter the walk it was called from.
pub const Walk = struct {
    resolver: ?WordResolver,
    methods: ?MethodSource,
    memo: ?*Memo = null,
    /// Bodies currently being walked, innermost last.
    on_path: [max_depth]BodyKey = undefined,
    depth: usize = 0,
    visits: usize = max_visits,
    /// Shallowest depth a back edge in the current subtree pointed at, or `no_cycle`.
    ///
    /// A back edge answers from where the walk is rather than from the body alone, so every body
    /// between the edge and the one it targets is uncacheable. The body it targets is not: the
    /// walk entered the cycle there and explored all of it, so that answer is complete. Tracking
    /// the shallowest target is what tells those two apart, and it is what keeps one recursive
    /// prelude word from poisoning every body above it.
    cycle_floor: usize = no_cycle,
    /// Whether the walk ran out of depth or visits. Both budgets are the walk's, not the body's,
    /// so nothing reached after one is exhausted can be cached.
    exhausted: bool = false,

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
        if (self.onPath(body)) |target| {
            self.cycle_floor = @min(self.cycle_floor, target);
            return false;
        }

        if (self.depth == max_depth) {
            self.exhausted = true;
            return true;
        }

        const key = bodyKey(body);
        if (self.memo) |m| {
            if (m.entries.get(key)) |cached| return cached;
        }

        const own_depth = self.depth;
        self.on_path[own_depth] = key;
        self.depth += 1;

        const enclosing_floor = self.cycle_floor;
        self.cycle_floor = no_cycle;

        const answer = self.walkCalls(body);

        const subtree_floor = self.cycle_floor;
        self.depth -= 1;

        // A cycle reaching this body or deeper is closed here, so it constrains nothing above.
        // One reaching past it leaves this body's answer resting on where the walk came from.
        const closed_here = subtree_floor >= own_depth;
        self.cycle_floor = if (closed_here) enclosing_floor else @min(enclosing_floor, subtree_floor);

        if (closed_here and !self.exhausted) {
            if (self.memo) |m| m.entries.put(m.allocator, key, answer) catch {};
        }
        return answer;
    }

    /// The body's own top-level calls. Split out so `bodyMayDefine` owns the path, taint, and memo
    /// bookkeeping at one exit rather than at each of these returns.
    fn walkCalls(self: *Walk, body: []const Instruction) bool {
        for (body) |instr| {
            if (!instr.op.isCall()) continue;

            if (self.visits == 0) {
                self.exhausted = true;
                return true;
            }
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

    /// The depth at which `body` is already being walked further out, or null.
    fn onPath(self: *const Walk, body: []const Instruction) ?usize {
        const key = bodyKey(body);
        for (self.on_path[0..self.depth], 0..) |seen, i| {
            if (seen.ptr == key.ptr and seen.len == key.len) return i;
        }
        return null;
    }
};

/// Whether executing `body` can install a word definition, descending fresh. See
/// `Walk.bodyMayDefine`.
pub fn bodyMayDefine(body: []const Instruction, resolver: ?WordResolver, methods: ?MethodSource) bool {
    return bodyMayDefineCached(body, resolver, methods, null);
}

/// Whether executing `body` can install a word definition, reusing and extending `memo`.
pub fn bodyMayDefineCached(
    body: []const Instruction,
    resolver: ?WordResolver,
    methods: ?MethodSource,
    memo: ?*Memo,
) bool {
    var walk = Walk{ .resolver = resolver, .methods = methods, .memo = memo };
    return walk.bodyMayDefine(body);
}

/// Whether `body`'s own top-level instructions call a native that defines a word.
///
/// The interpreter's per-word gate, computed when the word is defined and carried on its
/// definition, so a call reads one bit. Name-based rather than resolved: a callee need not exist
/// yet at definition time, and a user word that shadows a defining native's name only costs a
/// frame. A qualified name matches on its bare segment, so `native.<x>` reaches the same registry
/// row as `<x>`.
pub fn bodyCallsDefiningNative(body: []const Instruction) bool {
    for (body) |instr| {
        const name = instr.op.callTargetName() orelse continue;
        const bare = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else name;
        if (primitives.nativeNameDefinesWord(bare)) return true;
    }
    return false;
}

/// A `MethodSource` over a live dispatch table.
///
/// The walk queries a method source once per resolved callee, thousands of times over one word's
/// compilation, so the query has to be a hash lookup. One scan groups the registered bodies by
/// dispatch id up front; a callee whose id owns none then answers without reading the table at all.
///
/// The grouping is structural, so building it cannot interact with the walk's cycle bookkeeping. A
/// per-id result memo would: the walk answers false for a back edge, and caching that answer would
/// hand it to a later query that is not on the cycle.
pub const DispatchMethodIndex = struct {
    groups: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(dispatch_mod.DispatchBody)) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator, table: *const DispatchTable) !DispatchMethodIndex {
        var self = DispatchMethodIndex{ .allocator = allocator };
        errdefer self.deinit();

        var it = table.entries.iterator();
        while (it.next()) |entry| {
            const gop = try self.groups.getOrPut(allocator, entry.key_ptr.dispatch_id);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(allocator, entry.value_ptr.body);
        }
        return self;
    }

    pub fn deinit(self: *DispatchMethodIndex) void {
        var it = self.groups.valueIterator();
        while (it.next()) |bodies| bodies.deinit(self.allocator);
        self.groups.deinit(self.allocator);
    }

    pub fn source(self: *DispatchMethodIndex) MethodSource {
        return .{ .anyMethodMayDefine = &DispatchMethodIndex.anyMethodMayDefine, .user_data = @ptrCast(self) };
    }

    fn anyMethodMayDefine(user_data: *anyopaque, dispatch_id: u32, walk: *Walk) bool {
        const self: *const DispatchMethodIndex = @ptrCast(@alignCast(user_data));
        const bodies = self.groups.getPtr(dispatch_id) orelse return false;

        for (bodies.items) |body| {
            switch (body) {
                .quotation => |q| if (walk.bodyMayDefine(q.instructions)) return true,
                .native_fn => |func| if (primitives.nativeDefinesWord(func)) return true,
                // Host code is outside the primitive tables, so nothing declares what it installs.
                .host_callback => return true,
            }
        }
        return false;
    }
};

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

// --- bodyCallsDefiningNative ---

test "a body calling `;` at its top level calls a defining native" {
    const body = [_]Instruction{ call("swap"), call(";") };
    try std.testing.expect(bodyCallsDefiningNative(&body));
}

test "a body of inert calls does not call a defining native" {
    const body = [_]Instruction{ call("dup"), call("+") };
    try std.testing.expect(!bodyCallsDefiningNative(&body));
}

test "a qualified registry native matches on its bare name" {
    const body = [_]Instruction{call("native.borrow-deps")};
    try std.testing.expect(bodyCallsDefiningNative(&body));
}

test "a definition inside a pushed quotation literal does not flag the pushing body" {
    const inner = [_]Instruction{call(";")};
    const body = [_]Instruction{ pushQuot(&inner), call("call") };
    try std.testing.expect(!bodyCallsDefiningNative(&body));
}

// --- Memo ---

/// Answer `body` cold, then twice more against one memo, and require all three to agree.
///
/// The second call is the one that can read what the first stored, so a wrong cache entry shows up
/// as a disagreement rather than as a shape the caller has to know to look for.
fn agreesAcrossMemo(body: []const Instruction, resolver: ?WordResolver, methods: ?MethodSource) !bool {
    const cold = bodyMayDefine(body, resolver, methods);

    var memo = Memo.init(std.testing.allocator);
    defer memo.deinit();

    try std.testing.expectEqual(cold, bodyMayDefineCached(body, resolver, methods, &memo));
    try std.testing.expectEqual(cold, bodyMayDefineCached(body, resolver, methods, &memo));
    return cold;
}

test "a memo answers a definition-free chain the same way twice" {
    const inner_body = [_]Instruction{call("dup")};
    const middle_body = [_]Instruction{call("inner")};
    var data = TestResolver{ .words = &.{
        dup,
        .{ .name = "inner", .body = &inner_body },
        .{ .name = "middle", .body = &middle_body },
    } };
    const body = [_]Instruction{call("middle")};
    try std.testing.expect(!try agreesAcrossMemo(&body, data.resolver(), noMethods()));
}

test "a memo answers a transitive definer the same way twice" {
    const inner_body = [_]Instruction{call(";")};
    const middle_body = [_]Instruction{call("inner")};
    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "inner", .body = &inner_body },
        .{ .name = "middle", .body = &middle_body },
    } };
    const body = [_]Instruction{call("middle")};
    try std.testing.expect(try agreesAcrossMemo(&body, data.resolver(), noMethods()));
}

test "a memo does not carry a back edge's answer out of its cycle" {
    // `b` answers true only because it calls `;` itself; the `false` the walk gives at the `a`
    // back edge is the shape a memo must not store for `a`.
    const a_body = [_]Instruction{call("b")};
    const b_body = [_]Instruction{ call("a"), call(";") };
    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "a", .body = &a_body },
        .{ .name = "b", .body = &b_body },
    } };
    try std.testing.expect(try agreesAcrossMemo(&a_body, data.resolver(), noMethods()));
    try std.testing.expect(try agreesAcrossMemo(&b_body, data.resolver(), noMethods()));

    // Both entries through one memo, so the second reads whatever the first left.
    var memo = Memo.init(std.testing.allocator);
    defer memo.deinit();
    try std.testing.expect(bodyMayDefineCached(&a_body, data.resolver(), noMethods(), &memo));
    try std.testing.expect(bodyMayDefineCached(&b_body, data.resolver(), noMethods(), &memo));
}

test "a memo stores the body a cycle closes at, and not the ones inside it" {
    // `outer` sits above the `a`/`b` cycle. The cycle's own bodies rest on where the walk entered,
    // so only `outer` and the body the back edge points at are unconditional.
    const a_body = [_]Instruction{call("b")};
    const b_body = [_]Instruction{call("a")};
    const outer_body = [_]Instruction{call("a")};
    var data = TestResolver{ .words = &.{
        .{ .name = "a", .body = &a_body },
        .{ .name = "b", .body = &b_body },
    } };

    var memo = Memo.init(std.testing.allocator);
    defer memo.deinit();
    try std.testing.expect(!bodyMayDefineCached(&outer_body, data.resolver(), noMethods(), &memo));

    try std.testing.expect(memo.entries.contains(bodyKey(&outer_body)));
    try std.testing.expect(memo.entries.contains(bodyKey(&a_body)));
    try std.testing.expect(!memo.entries.contains(bodyKey(&b_body)));
}

test "an exhausted visit budget is not cached" {
    var body: [max_visits + 1]Instruction = undefined;
    for (&body) |*instr| instr.* = call("dup");
    var data = TestResolver{ .words = &.{dup} };

    var memo = Memo.init(std.testing.allocator);
    defer memo.deinit();
    try std.testing.expect(bodyMayDefineCached(body[0..], data.resolver(), noMethods(), &memo));
    try std.testing.expectEqual(@as(u32, 0), memo.entries.count());
}

// --- DispatchMethodIndex ---

const primitives_mod = @import("primitives/mod.zig");
const Context = @import("context.zig").Context;

/// A descriptor whose only role is pointer identity in a dispatch key.
fn testDescriptor() !*value_mod.TypeDescriptor {
    return try value_mod.createBuiltinTypeDescriptor(std.testing.allocator, .{});
}

fn inertNativeFn(_: *Context) anyerror!void {}

/// A table holding one method for `dispatch_id`, plus the descriptor its key borrows.
const IndexFixture = struct {
    table: DispatchTable,
    desc: *value_mod.TypeDescriptor,

    fn init(dispatch_id: u32, body: dispatch_mod.DispatchBody) !IndexFixture {
        var self = IndexFixture{
            .table = DispatchTable.init(std.testing.allocator),
            .desc = try testDescriptor(),
        };
        try self.table.register(
            .{ .dispatch_id = dispatch_id, .type_a = self.desc, .type_b = self.desc },
            .{ .body = body },
            false,
        );
        return self;
    }

    fn deinit(self: *IndexFixture) void {
        self.table.deinit();
        value_mod.destroyTypeDescriptor(std.testing.allocator, self.desc);
    }
};

test "a dispatch id owning a defining quotation method flags its caller" {
    const method_body = [_]Instruction{call(";")};
    var fixture = try IndexFixture.init(7, .{ .quotation = .{ .instructions = &method_body } });
    defer fixture.deinit();

    var index = try DispatchMethodIndex.init(std.testing.allocator, &fixture.table);
    defer index.deinit();

    var data = TestResolver{ .words = &.{
        semicolon,
        .{ .name = "gen", .is_native = true, .dispatch_id = 7 },
    } };
    const body = [_]Instruction{call("gen")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), index.source()));
}

test "a dispatch id owning only an inert quotation method does not flag" {
    const method_body = [_]Instruction{call("dup")};
    var fixture = try IndexFixture.init(7, .{ .quotation = .{ .instructions = &method_body } });
    defer fixture.deinit();

    var index = try DispatchMethodIndex.init(std.testing.allocator, &fixture.table);
    defer index.deinit();

    var data = TestResolver{ .words = &.{
        dup,
        .{ .name = "gen", .is_native = true, .dispatch_id = 7 },
    } };
    const body = [_]Instruction{call("gen")};
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), index.source()));
}

test "a dispatch id owning a defining native method flags its caller" {
    var fixture = try IndexFixture.init(7, .{ .native_fn = primitives_mod.control.nativeSemicolon });
    defer fixture.deinit();

    var index = try DispatchMethodIndex.init(std.testing.allocator, &fixture.table);
    defer index.deinit();

    var data = TestResolver{ .words = &.{.{ .name = "gen", .is_native = true, .dispatch_id = 7 }} };
    const body = [_]Instruction{call("gen")};
    try std.testing.expect(bodyMayDefine(&body, data.resolver(), index.source()));
}

test "a dispatch id absent from the index answers no" {
    var fixture = try IndexFixture.init(7, .{ .native_fn = inertNativeFn });
    defer fixture.deinit();

    var index = try DispatchMethodIndex.init(std.testing.allocator, &fixture.table);
    defer index.deinit();

    try std.testing.expect(index.groups.contains(7));
    try std.testing.expect(!index.groups.contains(8));

    var data = TestResolver{ .words = &.{.{ .name = "plain", .is_native = true, .dispatch_id = 8 }} };
    const body = [_]Instruction{call("plain")};
    try std.testing.expect(!bodyMayDefine(&body, data.resolver(), index.source()));
}
