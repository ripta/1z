const std = @import("std");
const Stepper = @import("stepper.zig").Stepper;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;

/// Result of dispatching a command.
pub const CommandResult = enum {
    /// Resume execution (step or continue was issued).
    resume_execution,
    /// Stay in the prompt loop (inspection command like stack or help).
    stay,
    /// Abort execution entirely.
    quit,
};

/// CommandDispatcher handles parsing and executing debugger commands.
pub const CommandDispatcher = struct {
    /// Dispatch a command line. Returns the action to take.
    pub fn dispatch(self: *CommandDispatcher, line: []const u8, stepper: *Stepper, ctx: *Context, writer: anytype) !CommandResult {
        _ = self;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (std.mem.eql(u8, trimmed, "s") or std.mem.eql(u8, trimmed, "step")) {
            stepper.mode = .step_into;
            return .resume_execution;
        }

        if (std.mem.eql(u8, trimmed, "c") or std.mem.eql(u8, trimmed, "continue")) {
            stepper.mode = .continue_running;
            return .resume_execution;
        }

        if (std.mem.eql(u8, trimmed, "q") or std.mem.eql(u8, trimmed, "quit")) {
            return .quit;
        }

        if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "stack")) {
            try writer.writeAll("  ");
            try ctx.stack.dump(writer);
            try writer.writeAll("\n");
            return .stay;
        }

        if (std.mem.eql(u8, trimmed, "h") or std.mem.eql(u8, trimmed, "help")) {
            try printHelp(writer);
            return .stay;
        }

        try writer.print("Unknown command: '{s}'. Type 'h' for help.\n", .{trimmed});
        return .stay;
    }

    fn printHelp(writer: anytype) !void {
        try writer.writeAll(
            \\Commands:
            \\  s, step       Step one instruction (step into)
            \\  c, continue   Run until next breakpoint or end
            \\  q, quit       Abort execution
            \\  ., stack      Show data stack
            \\  h, help       Show this help
            \\
            \\Press Enter on an empty line to repeat the last stepping command.
            \\
        );
    }
};
