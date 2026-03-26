const std = @import("std");
const Stepper = @import("stepper.zig").Stepper;
const Inspector = @import("inspector.zig").Inspector;
const BreakpointManager = @import("breakpoints.zig").BreakpointManager;
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
    pub fn dispatch(self: *CommandDispatcher, line: []const u8, stepper: *Stepper, breakpoints: *BreakpointManager, ctx: *Context, writer: anytype) !CommandResult {
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

        if (std.mem.eql(u8, cmd, "b") or std.mem.eql(u8, cmd, "break")) {
            if (arg) |bp_arg| {
                // If arg contains ':' and the part after parses as a number, treat as source:line
                if (parseSourceLocation(bp_arg)) |loc| {
                    const id = breakpoints.addSourceLocation(loc.source, loc.line);
                    if (id > 0) {
                        try writer.print("Breakpoint {d} set at {s}:{d}\n", .{ id, loc.source, loc.line });
                    } else {
                        try writer.writeAll("Failed to set breakpoint\n");
                    }
                } else {
                    const id = breakpoints.addWord(bp_arg);
                    if (id > 0) {
                        try writer.print("Breakpoint {d} set on word '{s}'\n", .{ id, bp_arg });
                    } else {
                        try writer.writeAll("Failed to set breakpoint\n");
                    }
                }
            } else {
                try writer.writeAll("Usage: break <word> or break <file>:<line>\n");
            }
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "bl") or std.mem.eql(u8, cmd, "breakpoints")) {
            try breakpoints.list(writer);
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "en") or std.mem.eql(u8, cmd, "enable")) {
            if (arg) |id_str| {
                if (std.fmt.parseInt(u32, id_str, 10)) |id| {
                    if (breakpoints.enable(id)) {
                        try writer.print("Breakpoint {d} enabled\n", .{id});
                    } else {
                        try writer.print("Breakpoint {d} not found\n", .{id});
                    }
                } else |_| {
                    try writer.writeAll("Usage: enable <id>\n");
                }
            } else {
                try writer.writeAll("Usage: enable <id>\n");
            }
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "dis") or std.mem.eql(u8, cmd, "disable")) {
            if (arg) |id_str| {
                if (std.fmt.parseInt(u32, id_str, 10)) |id| {
                    if (breakpoints.disable(id)) {
                        try writer.print("Breakpoint {d} disabled\n", .{id});
                    } else {
                        try writer.print("Breakpoint {d} not found\n", .{id});
                    }
                } else |_| {
                    try writer.writeAll("Usage: disable <id>\n");
                }
            } else {
                try writer.writeAll("Usage: disable <id>\n");
            }
            return .stay;
        }

        if (std.mem.eql(u8, cmd, "del") or std.mem.eql(u8, cmd, "delete")) {
            if (arg) |id_str| {
                if (std.fmt.parseInt(u32, id_str, 10)) |id| {
                    if (breakpoints.delete(id)) {
                        try writer.print("Breakpoint {d} deleted\n", .{id});
                    } else {
                        try writer.print("Breakpoint {d} not found\n", .{id});
                    }
                } else |_| {
                    try writer.writeAll("Usage: delete <id>\n");
                }
            } else {
                try writer.writeAll("Usage: delete <id>\n");
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

    /// Try to parse "source:line" from a string. Returns null if not a valid source location.
    fn parseSourceLocation(arg: []const u8) ?struct { source: []const u8, line: usize } {
        const colon_idx = std.mem.lastIndexOfScalar(u8, arg, ':') orelse return null;
        if (colon_idx == 0 or colon_idx == arg.len - 1) return null;
        const line_str = arg[colon_idx + 1 ..];
        const line = std.fmt.parseInt(usize, line_str, 10) catch return null;
        return .{ .source = arg[0..colon_idx], .line = line };
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
            \\  b, break <w>       Set breakpoint on word or file:line
            \\  bl, breakpoints    List all breakpoints
            \\  en, enable <id>    Enable a breakpoint
            \\  dis, disable <id>  Disable a breakpoint
            \\  del, delete <id>   Delete a breakpoint
            \\  h, help            Show this help
            \\
            \\Press Enter on an empty line to repeat the last stepping command.
            \\
        );
    }
};
