const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const is_freestanding = builtin.os.tag == .freestanding;

const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const LineEditor = @import("../line_editor.zig").LineEditor;

const Stepper = @import("stepper.zig").Stepper;
const DisplayRenderer = @import("display.zig").DisplayRenderer;
const CommandDispatcher = @import("commands.zig").CommandDispatcher;
const CommandResult = @import("commands.zig").CommandResult;
const BreakpointManager = @import("breakpoints.zig").BreakpointManager;
const EventEmitter = @import("events.zig").EventEmitter;
const DebugEvent = @import("events.zig").DebugEvent;

pub const DebuggerQuit = error{
    DebuggerQuit,
};

/// Top-level Debugger struct. Attached to Context when --debug is active.
pub const Debugger = struct {
    stepper: Stepper,
    display: DisplayRenderer,
    commands: CommandDispatcher,
    breakpoints: BreakpointManager,
    editor: ?LineEditor,
    events: EventEmitter = .{},
    allocator: Allocator,
    /// The last stepping command issued, for empty-line repeat.
    /// Defaults to .step_into so that pressing Enter before any command steps.
    last_step_mode: Stepper.Mode = .step_into,

    pub fn init(allocator: Allocator) Debugger {
        const editor = LineEditor.init(allocator) catch null;
        return .{
            .stepper = .{},
            .display = .{},
            .commands = .{},
            .breakpoints = BreakpointManager.init(allocator),
            .editor = editor,
            .allocator = allocator,
            .last_step_mode = .step_into,
        };
    }

    pub fn deinit(self: *Debugger) void {
        self.breakpoints.deinit();
        if (self.editor) |*ed| {
            ed.deinit();
        }
    }

    /// Check whether the debugger should pause before this instruction.
    pub fn shouldPause(self: *Debugger, instr: Instruction, ctx: *Context) !bool {
        return switch (self.stepper.mode) {
            .step_into => true,
            .continue_running => blk: {
                if (self.breakpoints.check(instr, ctx) != null) {
                    self.stepper.mode = .step_into;
                    self.events.emit(.breakpoint_hit, ctx);
                    break :blk true;
                }
                break :blk false;
            },
            .step_over => blk: {
                if (ctx.call_stack.items.len <= self.stepper.target_depth) {
                    self.stepper.mode = .step_into;
                    break :blk true;
                }
                if (self.breakpoints.check(instr, ctx) != null) {
                    self.stepper.mode = .step_into;
                    self.events.emit(.breakpoint_hit, ctx);
                    break :blk true;
                }
                break :blk false;
            },
            .step_finish => blk: {
                if (ctx.call_stack.items.len < self.stepper.target_depth) {
                    self.stepper.mode = .step_into;
                    break :blk true;
                }
                if (self.breakpoints.check(instr, ctx) != null) {
                    self.stepper.mode = .step_into;
                    self.events.emit(.breakpoint_hit, ctx);
                    break :blk true;
                }
                break :blk false;
            },
        };
    }

    /// Returns true if the debugger has a C embedding API callback registered.
    pub fn hasCCallback(self: *const Debugger) bool {
        return self.events.c_callback != null;
    }

    /// Non-interactive pause for the C embedding API. Fires the paused event
    /// (which invokes the C callback) and returns immediately. The host sets
    /// the stepping mode from within the callback; execution resumes when
    /// this function returns.
    pub fn handleCPause(self: *Debugger, ctx: *Context) void {
        self.events.emit(.paused, ctx);
        self.events.emit(.resumed, ctx);
        self.events.emit(.step_completed, ctx);
    }

    /// Read a line from the editor (TTY) or stdin (piped).
    /// Returns null on EOF. Caller must call `freeLine` when done.
    fn readLine(self: *Debugger) ?[]const u8 {
        if (comptime is_freestanding) return null;
        if (self.editor) |*ed| {
            const maybe_line = ed.readLine("debug> ") catch {
                return null;
            };
            return maybe_line;
        }

        const stdin_file: std.fs.File = .stdin();
        var buf: [4096]u8 = undefined;
        var stdin = stdin_file.reader(&buf);
        const reader = &stdin.interface;
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return null,
        };
        const trimmed = std.mem.trimRight(u8, line, "\n\r");

        // XXX: Need to allocate a copy so it outlives this stack frame
        return self.allocator.dupe(u8, trimmed) catch null;
    }

    /// Free a line returned by `readLine` if it was heap-allocated (piped mode).
    fn freeLine(self: *Debugger, line: []const u8) void {
        if (self.editor == null) {
            self.allocator.free(line);
        }
    }

    /// Enter the interactive debug prompt. Displays instruction context,
    /// then loops reading commands until a stepping command is issued.
    pub fn enterPrompt(self: *Debugger, instr: Instruction, ctx: *Context) !void {
        if (comptime is_freestanding) return;
        self.events.emit(.paused, ctx);

        const stderr_file: std.fs.File = .stderr();
        var stderr_buf: [4096]u8 = undefined;
        var stderr = stderr_file.writer(&stderr_buf);
        const writer = &stderr.interface;

        // Display the current instruction context
        try self.display.render(instr, ctx, writer);
        try writer.flush();

        // Read-eval loop until a stepping command is issued
        while (true) {
            const maybe_line = self.readLine();

            const line = maybe_line orelse {
                // EOF (Ctrl-D) at debug prompt: quit
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
                return DebuggerQuit.DebuggerQuit;
            };
            defer self.freeLine(line);

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len > 0) {
                if (self.editor) |*ed| {
                    ed.addHistory(trimmed);
                }
            }

            // Empty line: repeat last stepping command; keep track of depth
            // for step_over/step_finish
            if (trimmed.len == 0) {
                self.stepper.mode = self.last_step_mode;
                if (self.last_step_mode == .step_over or self.last_step_mode == .step_finish) {
                    self.stepper.target_depth = ctx.call_stack.items.len;
                }

                self.events.emit(.resumed, ctx);
                self.events.emit(.step_completed, ctx);
                return;
            }

            const result = try self.commands.dispatch(trimmed, &self.stepper, &self.breakpoints, ctx, writer);
            try writer.flush();

            switch (result) {
                .resume_execution => {
                    self.last_step_mode = self.stepper.mode;
                    self.events.emit(.resumed, ctx);
                    self.events.emit(.step_completed, ctx);
                    return;
                },
                .stay => continue,
                .quit => return DebuggerQuit.DebuggerQuit,
            }
        }
    }
};
