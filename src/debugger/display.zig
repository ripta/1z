const std = @import("std");
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const Value = value_mod.Value;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;

/// DisplayRenderer formats the debugger prompt display.
///
/// Prompt format:
///   [source:line] word-name  instruction-detail
///     [ stack contents ]
///   debug>
pub const DisplayRenderer = struct {
    /// Render the instruction context display before the debug prompt.
    pub fn render(self: *DisplayRenderer, instr: Instruction, ctx: *Context, writer: anytype) !void {
        _ = self;

        // Line 1: [source:line] instruction detail
        try writer.print("[{s}:{d}] ", .{ ctx.current_source, instr.line });

        switch (instr.op) {
            .push_literal => |val| {
                try writer.writeAll("push  ");
                try val.write(writer);
            },
            .call_word => |name| {
                try writer.print("call  {s}", .{name});
            },
            .call_word_direct, .call_word_module => |slot| {
                try writer.print("call  {s}", .{slot.name});
            },
        }
        try writer.writeAll("\n");

        // Line 2: stack contents
        try writer.writeAll("  ");
        try ctx.stack.dump(writer);
        try writer.writeAll("\n");
    }
};
