const std = @import("std");
const Stepper = @import("stepper.zig").Stepper;
const Inspector = @import("inspector.zig").Inspector;
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

        // Split into command and argument on first space
        const cmd, const arg = splitCommand(trimmed);

        if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "step")) {
            stepper.mode = .step_into;
            return .resume_execution;
        }

        if (std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "continue")) {
            stepper.mode = .continue_running;
            return .resume_execution;
        }

        if (std.mem.eql(u8, cmd, "n") or std.mem.eql(u8, cmd, "next")) {
            stepper.mode = .step_over;
            stepper.target_depth = ctx.call_stack.items.len;
            return .resume_execution;
        }

        if (std.mem.eql(u8, cmd, "f") or std.mem.eql(u8, cmd, "finish")) {
            stepper.mode = .step_finish;
            stepper.target_depth = ctx.call_stack.items.len;
            return .resume_execution;
        }

        if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
            return .quit;
        }

        if (std.mem.eql(u8, cmd, ".") or std.mem.eql(u8, cmd, "stack")) {
            try writer.writeAll("  ");
            try ctx.stack.dump(writer);
            try writer.writeAll("\n");
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "call")) {
            try Inspector.showCallStack(ctx, writer);
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "where")) {
            try Inspector.showWhere(ctx, writer);
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "w") or std.mem.eql(u8, cmd, "word")) {
            try Inspector.showCurrentWord(ctx, writer);
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "locals")) {
            try Inspector.showLocals(ctx, writer);
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "params")) {
            try Inspector.showParams(ctx, writer);
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "dict")) {
            if (arg) |name| {
                try Inspector.showDictEntry(ctx, name, writer);
            } else {
                try writer.writeAll("Usage: dict <word-name>\n");
            }
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "module")) {
            if (arg) |name| {
                try Inspector.showModule(ctx, name, writer);
            } else {
                try writer.writeAll("Usage: module <module-name>\n");
            }
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "help")) {
            try printHelp(writer);
            return .stay;
        }

        try writer.print("Unknown command: '{s}'. Type 'h' for help.\n", .{trimmed});
        return .stay;
    }

    /// Split a command line into command and optional argument.
    fn splitCommand(line: []const u8) struct { []const u8, ?[]const u8 } {
        if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
            const rest = std.mem.trim(u8, line[space_idx + 1 ..], " \t");
            if (rest.len > 0) {
                return .{ line[0..space_idx], rest };
            }
            return .{ line[0..space_idx], null };
        }
        return .{ line, null };
    }

    fn printHelp(writer: anytype) !void {
        try writer.writeAll(
            \\Commands:
            \\  s, step       Step one instruction (step into)
            \\  n, next       Step over (run until same call depth)
            \\  f, finish     Run until current word returns
            \\  c, continue   Run until next breakpoint or end
            \\  q, quit       Abort execution
            \\  ., stack      Show data stack
            \\  call          Show call stack
            \\  where         Show current source location
            \\  w, word       Show current word's instruction listing
            \\  locals        Show local frame bindings
            \\  params        Show parameter bindings
            \\  dict <name>   Inspect a dictionary entry
            \\  module <name> List exports of a loaded module
            \\  h, help       Show this help
            \\
            \\Press Enter on an empty line to repeat the last stepping command.
            \\
        );
    }
};
