const std = @import("std");

const LexicalParentMap = @import("lexical_parent_map.zig").LexicalParentMap;

/// The lexical sites an AOT program names, one per build-time body its emitted code tags.
///
/// A compiled frame and a decoded body have no build-time address at run time. So each known body
/// the emitter tags takes an index into a static table the program carries, `onez_lexical_sites`.
/// A site's runtime tag is the address of its row. That address lives for the whole process and is
/// never an instruction address, so it cannot collide with a body the runtime parses or decodes.
///
/// Emitted code passes a site number, the index plus one with `0` for none, and a C wrapper takes the
/// row's address. See `lexicalOwnerRef` in `ir_codegen.zig`.
///
/// Each row names its parent's index, and the program registers the table at startup. The runtime
/// map then holds the enclosing relation the build-time map held, keyed by tags instead of
/// build-time addresses. A site is added with its whole chain of ancestors, so every chain in the
/// table ends at a root, which is what makes each site known at run time.
pub const AotLexicalSiteTable = struct {
    allocator: std.mem.Allocator,
    /// Build-time canonical body address to site index.
    index: std.AutoHashMapUnmanaged(usize, u32) = .{},
    /// Per site, its parent's index plus one, or `0` for a root.
    parents: std.ArrayListUnmanaged(u32) = .{},

    pub fn init(allocator: std.mem.Allocator) AotLexicalSiteTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AotLexicalSiteTable) void {
        self.index.deinit(self.allocator);
        self.parents.deinit(self.allocator);
    }

    pub fn count(self: *const AotLexicalSiteTable) usize {
        return self.parents.items.len;
    }

    /// The site of build-time `body`, adding it and its ancestors on first ask. Null for a body the
    /// build-time map does not know, which is tagged `0` and so admits every body, as an unknown
    /// body's frame does in the interpreter.
    pub fn siteFor(self: *AotLexicalSiteTable, map: *const LexicalParentMap, body: usize) error{OutOfMemory}!?u32 {
        if (body == 0 or !map.isKnown(body)) return null;
        return try self.siteForKnown(map, map.canonical(body));
    }

    fn siteForKnown(self: *AotLexicalSiteTable, map: *const LexicalParentMap, body: usize) error{OutOfMemory}!u32 {
        if (self.index.get(body)) |i| return i;

        const parent: u32 = if (map.parentOf(body)) |p| (try self.siteForKnown(map, map.canonical(p))) + 1 else 0;

        const i: u32 = @intCast(self.parents.items.len);
        try self.parents.append(self.allocator, parent);
        try self.index.put(self.allocator, body, i);
        return i;
    }

    /// Write the table's C definition.
    ///
    /// An empty table still gets one unregistered row, because the preamble's wrappers name the
    /// symbol whether or not any code passes them a site.
    pub fn emitC(self: *const AotLexicalSiteTable, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) error{OutOfMemory}!void {
        if (self.parents.items.len == 0) {
            try out.appendSlice(allocator, "const uint64_t onez_lexical_sites[1] = { 0 };\n\n");
            return;
        }

        var buf: [64]u8 = undefined;
        const head = std.fmt.bufPrint(&buf, "const uint64_t onez_lexical_sites[{d}] = {{", .{self.parents.items.len}) catch unreachable;
        try out.appendSlice(allocator, head);

        for (self.parents.items, 0..) |parent, i| {
            if (i % 16 == 0) try out.appendSlice(allocator, "\n   ");
            const cell = std.fmt.bufPrint(&buf, " {d},", .{parent}) catch unreachable;
            try out.appendSlice(allocator, cell);
        }
        try out.appendSlice(allocator, "\n};\n\n");
    }
};

/// Install an emitted site table into `map`: each row's tag is its own address, recorded as a root
/// or as the child of its parent's row.
pub fn registerSites(map: *LexicalParentMap, rows: []const u64) error{OutOfMemory}!void {
    for (rows, 0..) |parent, i| {
        const tag = @intFromPtr(&rows[i]);
        if (parent == 0) {
            try map.recordRootTag(tag);
        } else {
            try map.recordParentTag(tag, @intFromPtr(&rows[@intCast(parent - 1)]));
        }
    }
}

const testing = std.testing;
const value_mod = @import("value.zig");
const Instruction = value_mod.Instruction;

fn quotationPushAt(body: []const Instruction, line: usize) Instruction {
    return .{ .op = .{ .push_literal = .{ .quotation = .{ .instructions = body } } }, .line = line };
}

test "AotLexicalSiteTable: a site brings its ancestors, and the registered table keeps the relation" {
    var build = try LexicalParentMap.create(testing.allocator);
    defer build.destroy();

    const reader_quot = [_]Instruction{.{ .op = .{ .call_word = "label" }, .line = 1 }};
    const reader_body = [_]Instruction{quotationPushAt(&reader_quot, 1)};
    const caller_body = [_]Instruction{.{ .op = .{ .call_word = "reader" }, .line = 2 }};
    const statement = [_]Instruction{ quotationPushAt(&reader_body, 1), quotationPushAt(&caller_body, 2) };
    try build.recordChildren(&reader_body);
    try build.recordChildren(&statement);
    try build.recordRoot(&statement);

    const unknown = [_]Instruction{.{ .op = .{ .call_word = "x" }, .line = 3 }};

    var sites = AotLexicalSiteTable.init(testing.allocator);
    defer sites.deinit();

    const quot_site = (try sites.siteFor(build, @intFromPtr(&reader_quot))).?;
    const caller_site = (try sites.siteFor(build, @intFromPtr(&caller_body))).?;
    try testing.expectEqual(@as(?u32, null), try sites.siteFor(build, @intFromPtr(&unknown)));

    // The quotation, its reader, and the shared statement, then the caller beside them.
    try testing.expectEqual(@as(usize, 4), sites.count());
    try testing.expectEqual(quot_site, (try sites.siteFor(build, @intFromPtr(&reader_quot))).?);

    var rows: [4]u64 = undefined;
    for (sites.parents.items, 0..) |p, i| rows[i] = p;

    var runtime = try LexicalParentMap.create(testing.allocator);
    defer runtime.destroy();
    try registerSites(runtime, &rows);

    const quot_tag = @intFromPtr(&rows[quot_site]);
    const caller_tag = @intFromPtr(&rows[caller_site]);
    const reader_tag = @intFromPtr(&rows[sites.index.get(@intFromPtr(&reader_body)).?]);

    try testing.expect(runtime.isKnown(quot_tag));
    try testing.expect(!runtime.admits(quot_tag, caller_tag));
    try testing.expect(runtime.admits(quot_tag, reader_tag));
}
