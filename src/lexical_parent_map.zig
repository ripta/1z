const std = @import("std");

const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;
const AtomicSlotMap = @import("atomic_slot_map.zig").AtomicSlotMap;

/// Process-shared record of which body syntactically encloses each parsed quotation literal, keyed
/// by instruction-slice address or, for an AOT program, by site tag.
///
/// A lexical frame is tagged with the body that opened it. Resolution and capture admit a frame
/// only when its owner is the body asking or one of that body's lexical ancestors, and this map is
/// where the ancestors come from. The nesting is fixed at parse time, so it is recorded once there
/// rather than tracked on every push.
///
/// A body is *known* when its chain of parents ends at a root, a top-level statement the parser
/// read from a file. Every other body is unknown, and the admission rule treats an unknown body on
/// either side as it was before the rule existed. That covers a body built at run time, parsed onto
/// a task arena, or parsed by `eval-string`, none of which has an entry.
///
/// An AOT program carries no instruction addresses from its build, so its entries are keyed by site
/// tags instead: the address of a row in the program's static site table. Its rows are registered
/// at startup, and a body it decodes is aliased to the row it stands for. A decoded body with no
/// row is unknown. See `aot_lexical_sites.zig`.
///
/// It also covers a literal inside a body that `parse-until` returned and a parse-time word then
/// consumed as data, such as the contents of `H{ }`. The literal outlives that body as a value
/// inside the enclosing statement, but its recorded parent is a body that never runs and is nobody's
/// child. Its real enclosing body had no final address yet when it was parsed.
///
/// A body rebuilt by inline expansion is a new address standing in for one the parser recorded. It
/// gets an alias to that source instead of entries of its own, and every comparison runs on the
/// canonical address. Untouched literals inside a rebuilt body keep naming the source as their
/// parent, and a frame the rebuilt body opens still has to match them.
///
/// Entries are permanent, so only process-lifetime keys may enter. The map is allocated by the root
/// context, aliased by pointer into every child, and freed only by the root. Reads take no lock.
/// Writers serialize on `write_mu`, and the first write for a key wins.
pub const LexicalParentMap = struct {
    parents: AtomicSlotMap(?*const anyopaque),
    aliases: AtomicSlotMap(?*const anyopaque),
    /// Statements read from a file. The value is the key itself; only presence is read.
    roots: AtomicSlotMap(?*const anyopaque),

    write_mu: std.Thread.Mutex = .{},

    /// Matches `NestedNameCache`: every parsed quotation literal takes a slot, and the prelude
    /// alone contributes about a thousand.
    const initial_capacity: usize = 4096;

    pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*LexicalParentMap {
        var parents = try AtomicSlotMap(?*const anyopaque).init(allocator, initial_capacity);
        errdefer parents.deinit();

        var aliases = try AtomicSlotMap(?*const anyopaque).init(allocator, 64);
        errdefer aliases.deinit();

        var roots = try AtomicSlotMap(?*const anyopaque).init(allocator, initial_capacity);
        errdefer roots.deinit();

        const self = try allocator.create(LexicalParentMap);
        self.* = .{ .parents = parents, .aliases = aliases, .roots = roots };
        return self;
    }

    pub fn destroy(self: *LexicalParentMap) void {
        const allocator = self.parents.allocator;
        self.parents.deinit();
        self.aliases.deinit();
        self.roots.deinit();
        allocator.destroy(self);
    }

    /// Record `statement` as a root: a top-level statement read from a file.
    pub fn recordRoot(self: *LexicalParentMap, statement: []const Instruction) error{OutOfMemory}!void {
        if (statement.len == 0) return;

        self.write_mu.lock();
        defer self.write_mu.unlock();

        _ = try self.roots.insert(@intFromPtr(statement.ptr), &statement[0]);
    }

    /// Record `enclosing` as the parent of every quotation literal it pushes directly.
    ///
    /// Only the direct children are walked. A deeper literal was recorded when its own enclosing
    /// body finished, since the parser finishes bodies innermost first.
    pub fn recordChildren(self: *LexicalParentMap, enclosing: []const Instruction) error{OutOfMemory}!void {
        if (enclosing.len == 0) return;

        self.write_mu.lock();
        defer self.write_mu.unlock();

        const parent = &enclosing[0];
        for (enclosing) |instr| {
            const child = switch (instr.op) {
                .push_literal => |val| if (val == .quotation) val.quotation.instructions else continue,
                else => continue,
            };
            if (child.len == 0) continue;
            _ = try self.parents.insert(@intFromPtr(child.ptr), parent);
        }
    }

    /// Record that `rebuilt` stands in for `source`.
    pub fn recordAlias(self: *LexicalParentMap, rebuilt: []const Instruction, source: []const Instruction) error{OutOfMemory}!void {
        if (rebuilt.len == 0 or source.len == 0) return;

        self.write_mu.lock();
        defer self.write_mu.unlock();

        const target = self.canonical(@intFromPtr(source.ptr));
        if (target == @intFromPtr(rebuilt.ptr)) return;
        _ = try self.aliases.insert(@intFromPtr(rebuilt.ptr), @ptrFromInt(target));
    }

    /// Record site `tag` as a root. The AOT counterpart of `recordRoot`.
    pub fn recordRootTag(self: *LexicalParentMap, tag: usize) error{OutOfMemory}!void {
        self.write_mu.lock();
        defer self.write_mu.unlock();

        _ = try self.roots.insert(tag, @ptrFromInt(tag));
    }

    /// Record site `parent` as the parent of site `child`. The AOT counterpart of `recordChildren`.
    pub fn recordParentTag(self: *LexicalParentMap, child: usize, parent: usize) error{OutOfMemory}!void {
        self.write_mu.lock();
        defer self.write_mu.unlock();

        _ = try self.parents.insert(child, @ptrFromInt(parent));
    }

    /// Place a body decoded at run time in the nesting: alias it to site `tag`, and record each
    /// quotation literal inside it, at any depth, under its enclosing body.
    ///
    /// A `tag` of `0` is a literal its build did not know. Nothing is recorded then, so the body and
    /// everything inside it stay unknown, as the build-time body was. `body` must live for the whole
    /// process, as every key here must.
    ///
    /// A direct child names the tag rather than `body` as its parent, since comparisons run on the
    /// canonical address and a parent recorded under its alias would never match.
    pub fn recordDecodedBody(self: *LexicalParentMap, body: []const Instruction, tag: usize) error{OutOfMemory}!void {
        if (tag == 0 or body.len == 0) return;

        self.write_mu.lock();
        defer self.write_mu.unlock();

        if (tag != @intFromPtr(body.ptr)) _ = try self.aliases.insert(@intFromPtr(body.ptr), @ptrFromInt(tag));
        try self.recordDecodedChildrenLocked(body, tag);
    }

    fn recordDecodedChildrenLocked(self: *LexicalParentMap, body: []const Instruction, parent: usize) error{OutOfMemory}!void {
        for (body) |instr| {
            const child = switch (instr.op) {
                .push_literal => |val| if (val == .quotation) val.quotation.instructions else continue,
                else => continue,
            };
            if (child.len == 0) continue;
            _ = try self.parents.insert(@intFromPtr(child.ptr), @ptrFromInt(parent));
            try self.recordDecodedChildrenLocked(child, @intFromPtr(child.ptr));
        }
    }

    /// The address `body` is compared under: its alias target when it was rebuilt, itself
    /// otherwise.
    ///
    /// An alias always names a canonical address, so one probe settles it.
    pub fn canonical(self: *const LexicalParentMap, body: usize) usize {
        const target = self.aliases.lookup(body) orelse return body;
        return @intFromPtr(target);
    }

    /// The canonical parent of `body`, or null when `body` is unknown.
    pub fn parentOf(self: *const LexicalParentMap, body: usize) ?usize {
        const parent = self.parents.lookup(self.canonical(body)) orelse return null;
        return @intFromPtr(parent);
    }

    /// Whether `body`'s chain of parents ends at a root. See the type's doc comment.
    pub fn isKnown(self: *const LexicalParentMap, body: usize) bool {
        return self.roots.lookup(self.outermost(self.canonical(body))) != null;
    }

    /// The last body on `body`'s chain of parents, which is `body` itself when it has none.
    fn outermost(self: *const LexicalParentMap, body: usize) usize {
        var cur = body;
        while (self.parentOf(cur)) |p| cur = p;
        return cur;
    }

    /// Whether a lexical frame opened by `owner` may answer for `body`.
    ///
    /// It may unless both are known and `owner` is neither `body` nor one of its lexical ancestors.
    /// An owner of `0` is a frame no body opened. An unknown body on either side answers yes, which
    /// is how every frame answered before owners were compared.
    ///
    /// Callers ask only after the frame has matched a name, so the chain walk stays off the path
    /// where no foreign frame binds anything.
    pub fn admits(self: *const LexicalParentMap, body: usize, owner: usize) bool {
        if (owner == 0 or body == 0) return true;

        const b = self.canonical(body);
        const o = self.canonical(owner);
        if (b == o) return true;

        var cur = b;
        while (self.parentOf(cur)) |p| {
            if (p == o) return true;
            cur = p;
        }

        // `cur` is `b`'s outermost ancestor. Unrooted means `b` is unknown.
        if (self.roots.lookup(cur) == null) return true;
        return !self.isKnown(o);
    }

    /// Occupied parent slots. Diagnostics and tests.
    pub fn count(self: *LexicalParentMap) usize {
        self.write_mu.lock();
        defer self.write_mu.unlock();
        return self.parents.count();
    }
};

const testing = std.testing;

fn quotationPush(body: []const Instruction) Instruction {
    return quotationPushAt(body, 1);
}

/// `line` keeps otherwise identical arrays distinct, since the compiler folds equal constants onto
/// one address and these tests compare addresses.
fn quotationPushAt(body: []const Instruction, line: usize) Instruction {
    return .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = body } } }, .line = line };
}

test "LexicalParentMap: records direct children and walks the chain" {
    var map = try LexicalParentMap.create(testing.allocator);
    defer map.destroy();

    const leaf = [_]Instruction{.{ .op = .{ .call_word = "x" }, .line = 1 }};
    const middle = [_]Instruction{quotationPush(&leaf)};
    const top = [_]Instruction{quotationPush(&middle)};
    const statement = [_]Instruction{quotationPush(&top)};

    try map.recordChildren(&middle);
    try map.recordChildren(&top);
    try map.recordChildren(&statement);

    try testing.expectEqual(@as(?usize, @intFromPtr(&middle)), map.parentOf(@intFromPtr(&leaf)));
    try testing.expectEqual(@as(?usize, @intFromPtr(&statement)), map.parentOf(@intFromPtr(&top)));
    try testing.expectEqual(@as(?usize, null), map.parentOf(@intFromPtr(&statement)));

    try testing.expect(map.admits(@intFromPtr(&leaf), @intFromPtr(&top)));
    try testing.expect(map.admits(@intFromPtr(&leaf), @intFromPtr(&leaf)));
}

test "LexicalParentMap: admits refuses only a known foreign owner" {
    var map = try LexicalParentMap.create(testing.allocator);
    defer map.destroy();

    const reader_body = [_]Instruction{.{ .op = .{ .call_word = "label" }, .line = 1 }};
    const caller_body = [_]Instruction{.{ .op = .{ .call_word = "reader" }, .line = 1 }};
    const statement = [_]Instruction{ quotationPush(&reader_body), quotationPush(&caller_body) };
    try map.recordChildren(&statement);
    try map.recordRoot(&statement);

    // Distinct contents, so the compiler cannot fold it onto `reader_body`'s address.
    const runtime_body = [_]Instruction{.{ .op = .{ .call_word = "label" }, .line = 2 }};

    try testing.expect(!map.admits(@intFromPtr(&reader_body), @intFromPtr(&caller_body)));
    try testing.expect(map.admits(@intFromPtr(&reader_body), 0));
    try testing.expect(map.admits(@intFromPtr(&reader_body), @intFromPtr(&runtime_body)));
    try testing.expect(map.admits(@intFromPtr(&runtime_body), @intFromPtr(&caller_body)));
}

test "LexicalParentMap: a chain that ends short of a root is unknown" {
    var map = try LexicalParentMap.create(testing.allocator);
    defer map.destroy();

    // `contents` stands for a body a parse-time word consumed as data, so nothing records it as a
    // child and no statement roots it.
    const buried = [_]Instruction{.{ .op = .{ .call_word = "value" }, .line = 3 }};
    const contents = [_]Instruction{quotationPushAt(&buried, 3)};
    try map.recordChildren(&contents);

    const block = [_]Instruction{.{ .op = .{ .call_word = "value" }, .line = 4 }};
    const statement = [_]Instruction{quotationPushAt(&block, 4)};
    try map.recordChildren(&statement);
    try map.recordRoot(&statement);

    try testing.expect(!map.isKnown(@intFromPtr(&buried)));
    try testing.expect(map.isKnown(@intFromPtr(&block)));
    try testing.expect(map.admits(@intFromPtr(&buried), @intFromPtr(&block)));
}

test "LexicalParentMap: a decoded body stands for its site, and its nested literals follow it" {
    var map = try LexicalParentMap.create(testing.allocator);
    defer map.destroy();

    // Two site rows: a caller's body and, beside it, a reader whose literal was decoded.
    const rows = [_]u64{ 0, 0, 1 };
    const root_tag = @intFromPtr(&rows[0]);
    const caller_tag = @intFromPtr(&rows[1]);
    const reader_tag = @intFromPtr(&rows[2]);
    try map.recordRootTag(root_tag);
    try map.recordParentTag(caller_tag, root_tag);
    try map.recordParentTag(reader_tag, root_tag);

    const inner = [_]Instruction{.{ .op = .{ .call_word = "label" }, .line = 5 }};
    const decoded = [_]Instruction{quotationPushAt(&inner, 5)};
    try map.recordDecodedBody(&decoded, reader_tag);

    try testing.expectEqual(reader_tag, map.canonical(@intFromPtr(&decoded)));
    try testing.expect(map.isKnown(@intFromPtr(&inner)));
    try testing.expect(map.admits(@intFromPtr(&inner), @intFromPtr(&decoded)));
    try testing.expect(map.admits(@intFromPtr(&inner), reader_tag));
    try testing.expect(!map.admits(@intFromPtr(&inner), caller_tag));

    // A literal its build did not know stays unknown, and so admits every frame.
    const unsited = [_]Instruction{.{ .op = .{ .call_word = "label" }, .line = 6 }};
    try map.recordDecodedBody(&unsited, 0);
    try testing.expect(!map.isKnown(@intFromPtr(&unsited)));
    try testing.expect(map.admits(@intFromPtr(&unsited), caller_tag));
}

test "LexicalParentMap: a rebuilt body compares as its source" {
    var map = try LexicalParentMap.create(testing.allocator);
    defer map.destroy();

    const inner = [_]Instruction{.{ .op = .{ .call_word = "x" }, .line = 1 }};
    const source = [_]Instruction{quotationPush(&inner)};
    const statement = [_]Instruction{quotationPush(&source)};
    try map.recordChildren(&source);
    try map.recordChildren(&statement);

    const rebuilt = [_]Instruction{quotationPushAt(&inner, 2)};
    try map.recordAlias(&rebuilt, &source);

    try testing.expectEqual(@intFromPtr(&source), map.canonical(@intFromPtr(&rebuilt)));
    try testing.expect(map.admits(@intFromPtr(&inner), @intFromPtr(&rebuilt)));
    try testing.expectEqual(@as(?usize, @intFromPtr(&statement)), map.parentOf(@intFromPtr(&rebuilt)));

    const rebuilt_again = [_]Instruction{quotationPushAt(&inner, 3)};
    try map.recordAlias(&rebuilt_again, &rebuilt);
    try testing.expectEqual(@intFromPtr(&source), map.canonical(@intFromPtr(&rebuilt_again)));
}
