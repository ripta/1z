const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Quotation = value_mod.Quotation;
const Value = value_mod.Value;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const StatementProcessor = @import("../statement.zig").StatementProcessor;

pub const BreakpointKind = union(enum) {
    word_name: []const u8,
    source_location: struct { source: []const u8, line: usize },
    conditional: struct { word_name: []const u8, condition: []const u8 },
};

pub const Breakpoint = struct {
    id: u32,
    kind: BreakpointKind,
    enabled: bool = true,
    hit_count: u32 = 0,
};

pub const BreakpointManager = struct {
    breakpoints: std.ArrayListUnmanaged(Breakpoint),
    next_id: u32 = 1,
    allocator: Allocator,

    pub fn init(allocator: Allocator) BreakpointManager {
        return .{
            .breakpoints = .{},
            .next_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BreakpointManager) void {
        for (self.breakpoints.items) |bp| {
            self.freeBreakpointMemory(bp);
        }
        self.breakpoints.deinit(self.allocator);
    }

    fn freeBreakpointMemory(self: *BreakpointManager, bp: Breakpoint) void {
        switch (bp.kind) {
            .word_name => |name| self.allocator.free(name),
            .source_location => |loc| self.allocator.free(loc.source),
            .conditional => |cond| {
                self.allocator.free(cond.word_name);
                self.allocator.free(cond.condition);
            },
        }
    }

    /// Add a word-name breakpoint. Returns the breakpoint id.
    pub fn addWord(self: *BreakpointManager, name: []const u8) u32 {
        const duped = self.allocator.dupe(u8, name) catch return 0;
        const id = self.next_id;
        self.next_id += 1;
        self.breakpoints.append(self.allocator, .{
            .id = id,
            .kind = .{ .word_name = duped },
        }) catch {
            self.allocator.free(duped);
            return 0;
        };
        return id;
    }

    /// Add a source-location breakpoint. Returns the breakpoint id.
    pub fn addSourceLocation(self: *BreakpointManager, source: []const u8, line: usize) u32 {
        const duped = self.allocator.dupe(u8, source) catch return 0;
        const id = self.next_id;
        self.next_id += 1;
        self.breakpoints.append(self.allocator, .{
            .id = id,
            .kind = .{ .source_location = .{ .source = duped, .line = line } },
        }) catch {
            self.allocator.free(duped);
            return 0;
        };
        return id;
    }

    /// Add a conditional breakpoint. Returns the breakpoint id.
    pub fn addConditional(self: *BreakpointManager, word_name: []const u8, condition: []const u8) u32 {
        const duped_name = self.allocator.dupe(u8, word_name) catch return 0;
        const duped_cond = self.allocator.dupe(u8, condition) catch {
            self.allocator.free(duped_name);
            return 0;
        };
        const id = self.next_id;
        self.next_id += 1;
        self.breakpoints.append(self.allocator, .{
            .id = id,
            .kind = .{ .conditional = .{ .word_name = duped_name, .condition = duped_cond } },
        }) catch {
            self.allocator.free(duped_name);
            self.allocator.free(duped_cond);
            return 0;
        };
        return id;
    }

    /// Check if any enabled breakpoint matches the current instruction.
    /// Increments hit_count on match and returns a pointer to the breakpoint.
    pub fn check(self: *BreakpointManager, instr: Instruction, ctx: *Context) ?*Breakpoint {
        for (self.breakpoints.items) |*bp| {
            if (!bp.enabled) continue;
            const matches = switch (bp.kind) {
                .word_name => |name| switch (instr.op) {
                    .call_word => |word| std.mem.eql(u8, word, name),
                    .push_literal => false,
                },
                .source_location => |loc| instr.line == loc.line and std.mem.eql(u8, ctx.current_source, loc.source),
                .conditional => |cond| blk: {
                    const word_matches = switch (instr.op) {
                        .call_word => |word| std.mem.eql(u8, word, cond.word_name),
                        .push_literal => false,
                    };

                    if (!word_matches) break :blk false;

                    break :blk self.evaluateCondition(cond.condition, ctx);
                },
            };
            if (matches) {
                bp.hit_count += 1;
                return bp;
            }
        }
        return null;
    }

    /// Evaluate a conditional breakpoint's condition on a cloned stack.
    /// Returns true if the condition is truthy.
    fn evaluateCondition(self: *BreakpointManager, condition: []const u8, ctx: *Context) bool {
        _ = self;

        const original_items = ctx.stack.items.items;
        var cloned = std.ArrayListUnmanaged(Value){};
        cloned.appendSlice(ctx.stack.allocator, original_items) catch return false;
        defer cloned.deinit(ctx.stack.allocator);

        const saved_items = ctx.stack.items;
        ctx.stack.items = cloned;
        defer {
            // XXX: Restore original stack, since clone may have been modified
            cloned = ctx.stack.items;
            ctx.stack.items = saved_items;
        }

        // XXX: Null out debugger !!! recursive pauses
        const saved_debugger = ctx.debugger;
        ctx.debugger = null;
        defer ctx.debugger = saved_debugger;

        // Parse and execute the condition
        var processor: StatementProcessor = .{};
        const result = processor.feedLine(ctx.quotationAllocator(), condition, ctx);
        switch (result) {
            .complete => |instrs| {
                ctx.executeQuotation(.{ .instructions = instrs }) catch return false;
            },
            else => return false,
        }

        // Check if top of stack is truthy
        const top = ctx.stack.pop() catch return false;
        return switch (top) {
            .boolean => |b| b,
            .integer => |i| i != 0,
            else => true,
        };
    }

    /// Enable a breakpoint by id. Returns false if not found.
    pub fn enable(self: *BreakpointManager, id: u32) bool {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == id) {
                bp.enabled = true;
                return true;
            }
        }
        return false;
    }

    /// Disable a breakpoint by id. Returns false if not found.
    pub fn disable(self: *BreakpointManager, id: u32) bool {
        for (self.breakpoints.items) |*bp| {
            if (bp.id == id) {
                bp.enabled = false;
                return true;
            }
        }
        return false;
    }

    /// Delete a breakpoint by id. Returns false if not found.
    pub fn delete(self: *BreakpointManager, id: u32) bool {
        for (self.breakpoints.items, 0..) |bp, i| {
            if (bp.id == id) {
                self.freeBreakpointMemory(bp);
                _ = self.breakpoints.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// List all breakpoints to the writer.
    pub fn list(self: *const BreakpointManager, writer: anytype) !void {
        if (self.breakpoints.items.len == 0) {
            try writer.writeAll("  No breakpoints set.\n");
            return;
        }
        for (self.breakpoints.items) |bp| {
            try writer.print("  {d}: ", .{bp.id});
            switch (bp.kind) {
                .word_name => |name| try writer.print("word '{s}'", .{name}),
                .source_location => |loc| try writer.print("{s}:{d}", .{ loc.source, loc.line }),
                .conditional => |cond| try writer.print("word '{s}' when {s}", .{ cond.word_name, cond.condition }),
            }
            if (!bp.enabled) {
                try writer.writeAll(" [disabled]");
            }
            try writer.print(" (hits: {d})\n", .{bp.hit_count});
        }
    }
};
