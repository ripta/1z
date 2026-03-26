const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const LineEditor = @import("../line_editor.zig").LineEditor;

const Stepper = @import("stepper.zig").Stepper;
const DisplayRenderer = @import("display.zig").DisplayRenderer;
const CommandDispatcher = @import("commands.zig").CommandDispatcher;
const CommandResult = @import("commands.zig").CommandResult;

pub const DebuggerQuit = error{
    DebuggerQuit,
};

/// Top-level Debugger struct. Attached to Context when --debug is active.
pub const Debugger = struct {
    stepper: Stepper,
    display: DisplayRenderer,
    commands: CommandDispatcher,
    editor: LineEditor,
    allocator: Allocator,
    /// The last stepping command issued, for empty-line repeat.
    /// Defaults to .step_into so that pressing Enter before any command steps.
    last_step_mode: Stepper.Mode = .step_into,

    pub fn init(allocator: Allocator) !Debugger {
        return .{
            .stepper = .{},
            .display = .{},
            .commands = .{},
            .editor = try LineEditor.init(allocator),
            .allocator = allocator,
            .last_step_mode = .step_into,
        };
    }

    pub fn deinit(self: *Debugger) void {
        self.editor.deinit();
    }

    /// Check whether the debugger should pause before this instruction.
    pub fn shouldPause(self: *Debugger, instr: Instruction, ctx: *Context) !bool {
        _ = instr;
        return switch (self.stepper.mode) {
            .step_into => true,
            .continue_running => false,
            .step_over => blk: {
                if (ctx.call_stack.items.len <= self.stepper.target_depth) {
                    self.stepper.mode = .step_into;
                    break :blk true;
                }
                break :blk false;
            },
            .step_finish => blk: {
                if (ctx.call_stack.items.len < self.stepper.target_depth) {
                    self.stepper.mode = .step_into;
                    break :blk true;
                }
                break :blk false;
            },
        };
    }

    /// Enter the interactive debug prompt. Displays instruction context,
    /// then loops reading commands until a stepping command is issued.
    pub fn enterPrompt(self: *Debugger, instr: Instruction, ctx: *Context) !void {
        const stderr_file: std.fs.File = .stderr();
        var stderr_buf: [4096]u8 = undefined;
        var stderr = stderr_file.writer(&stderr_buf);
        const writer = &stderr.interface;

        // Display the current instruction context
        try self.display.render(instr, ctx, writer);
        try writer.flush();

        // Read-eval loop until a stepping command is issued
        while (true) {
            const maybe_line = self.editor.readLine("debug> ") catch {
                // On read error, default to step
                self.stepper.mode = .step_into;
                return;
            };

            const line = maybe_line orelse {
                // EOF (Ctrl-D) at debug prompt: quit
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
                return DebuggerQuit.DebuggerQuit;
            };

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) {
                self.editor.addHistory(trimmed);
            }

            // Empty line: repeat last stepping command; keep track of depth
            // for step_over/step_finish
            if (trimmed.len == 0) {
                self.stepper.mode = self.last_step_mode;
                if (self.last_step_mode == .step_over or self.last_step_mode == .step_finish) {
                    self.stepper.target_depth = ctx.call_stack.items.len;
                }

                return;
            }

            const result = try self.commands.dispatch(trimmed, &self.stepper, ctx, writer);
            try writer.flush();

            switch (result) {
                .resume_execution => {
                    self.last_step_mode = self.stepper.mode;
                    return;
                },
                .stay => continue,
                .quit => return DebuggerQuit.DebuggerQuit,
            }
        }
    }
};
