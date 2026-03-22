const std = @import("std");
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const BenchmarkStats = @import("../benchmark.zig").BenchmarkStats;

/// Inspector provides read-only state accessors for debugger inspection commands.
pub const Inspector = struct {
    /// Show the call stack, innermost first.
    pub fn showCallStack(ctx: *Context, writer: anytype) !void {
        if (ctx.call_stack.items.len == 0) {
            try writer.writeAll("  (empty call stack)\n");
            return;
        }
        var i = ctx.call_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = ctx.call_stack.items[i];
            try writer.print("  {s}  ({s}:{d})\n", .{ frame.word_name, ctx.current_source, frame.line });
        }
    }

    /// Show the current source location.
    pub fn showWhere(ctx: *Context, writer: anytype) !void {
        try writer.print("  {s}\n", .{ctx.current_source});
    }

    /// Show the current word's instruction listing.
    pub fn showCurrentWord(ctx: *Context, writer: anytype) !void {
        if (ctx.call_stack.items.len == 0) {
            try writer.writeAll("  (no current word)\n");
            return;
        }
        const frame = ctx.call_stack.items[ctx.call_stack.items.len - 1];
        const name = frame.word_name;

        if (ctx.lookupWord(name)) |word| {
            try writer.print("  {s}", .{name});
            if (word.stack_effect) |effect| {
                try writer.writeAll(" ");
                try effect.write(writer);
            }
            try writer.writeAll("\n");

            if (word.markers.len > 0) {
                try writer.writeAll("  markers:");
                for (word.markers) |m| {
                    try writer.print(" {s}", .{m.name});
                }
                try writer.writeAll("\n");
            }

            switch (word.action) {
                .native => {
                    try writer.writeAll("  <native>\n");
                },
                .compound => |instrs| {
                    try writer.print("  {d} instruction(s):\n", .{instrs.len});
                    for (instrs, 0..) |instr, idx| {
                        try writer.print("    {d}: ", .{idx});
                        switch (instr.op) {
                            .push_literal => |val| {
                                try writer.writeAll("push  ");
                                try val.write(writer);
                            },
                            .call_word => |w| {
                                try writer.print("call  {s}", .{w});
                            },
                        }
                        try writer.writeAll("\n");
                    }
                },
            }
        } else {
            try writer.print("  {s}: not found in dictionary\n", .{name});
        }
    }

    /// Show current local frame bindings.
    pub fn showLocals(ctx: *Context, writer: anytype) !void {
        if (ctx.local_frames.items.len == 0) {
            try writer.writeAll("  (no local frames)\n");
            return;
        }
        // Show from top (innermost) to bottom (outermost)
        var i = ctx.local_frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = ctx.local_frames.items[i];
            if (frame.count() == 0) {
                try writer.print("  frame {d}: (empty)\n", .{i});
                continue;
            }
            try writer.print("  frame {d}:\n", .{i});
            var iter = frame.iterator();
            while (iter.next()) |entry| {
                try writer.print("    {s} = ", .{entry.key_ptr.*});
                switch (entry.value_ptr.*.action) {
                    .native => try writer.writeAll("<native>"),
                    .compound => |instrs| try writer.print("<compound: {d} instructions>", .{instrs.len}),
                }
                try writer.writeAll("\n");
            }
        }
    }

    /// Show active parameter bindings.
    pub fn showParams(ctx: *Context, writer: anytype) !void {
        if (ctx.parameter_env.items.len == 0) {
            try writer.writeAll("  (no parameter frames)\n");
            return;
        }
        // Show from top (innermost) to bottom (outermost)
        var i = ctx.parameter_env.items.len;
        while (i > 0) {
            i -= 1;
            const frame = ctx.parameter_env.items[i];
            if (frame.count() == 0) {
                try writer.print("  frame {d}: (empty)\n", .{i});
                continue;
            }
            try writer.print("  frame {d}:\n", .{i});
            var iter = frame.iterator();
            while (iter.next()) |entry| {
                try writer.print("    {s} = ", .{entry.key_ptr.*});
                try entry.value_ptr.*.write(writer);
                try writer.writeAll("\n");
            }
        }
    }

    /// Inspect a dictionary entry by name.
    pub fn showDictEntry(ctx: *Context, name: []const u8, writer: anytype) !void {
        if (ctx.lookupWord(name)) |word| {
            try writer.print("  {s}", .{name});
            if (word.stack_effect) |effect| {
                try writer.writeAll(" ");
                try effect.write(writer);
            }
            try writer.writeAll("\n");

            if (word.parse_time) {
                try writer.writeAll("  parse-time: yes\n");
            }
            if (word.imported) {
                try writer.writeAll("  imported: yes\n");
            }
            if (word.markers.len > 0) {
                try writer.writeAll("  markers:");
                for (word.markers) |m| {
                    try writer.print(" {s}", .{m.name});
                }
                try writer.writeAll("\n");
            }

            switch (word.action) {
                .native => {
                    try writer.writeAll("  type: native\n");
                },
                .compound => |instrs| {
                    try writer.print("  type: compound ({d} instructions)\n", .{instrs.len});
                },
            }
        } else {
            try writer.print("  '{s}' not found\n", .{name});
        }
    }

    /// List all loaded modules.
    pub fn listModules(ctx: *Context, writer: anytype) !void {
        if (ctx.module_cache_value.count() == 0) {
            try writer.writeAll("  No modules loaded.\n");
            return;
        }
        var iter = ctx.module_cache_value.iterator();
        while (iter.next()) |entry| {
            const val = entry.value_ptr.*;
            const module = switch (val) {
                .module => |m| m,
                else => continue,
            };
            try writer.print("  {s} ({d} exports)\n", .{ module.name, module.words.count() });
        }
    }

    /// List exports of a loaded module.
    pub fn showModule(ctx: *Context, name: []const u8, writer: anytype) !void {
        var iter = ctx.module_cache_value.iterator();
        while (iter.next()) |entry| {
            const val = entry.value_ptr.*;
            const module = switch (val) {
                .module => |m| m,
                else => continue,
            };
            if (std.mem.eql(u8, module.name, name)) {
                try writer.print("  module '{s}':\n", .{name});
                var word_iter = module.words.iterator();
                while (word_iter.next()) |word_entry| {
                    const word_name = word_entry.key_ptr.*;
                    const mod_word = word_entry.value_ptr.*;
                    try writer.print("    {s}", .{word_name});
                    if (mod_word.stack_effect) |effect| {
                        try writer.writeAll(" ");
                        try effect.write(writer);
                    }
                    try writer.writeAll("\n");
                }
                return;
            }
        }
        try writer.print("  module '{s}' not found\n", .{name});
    }

    /// Show interpreter statistics.
    pub fn showStats(ctx: *Context, writer: anytype) !void {
        // Stack
        try writer.writeAll("Stack:\n");
        try writer.print("  Depth:           {d}\n", .{ctx.stack.depth()});
        try writer.print("  Call stack:      {d}\n", .{ctx.call_stack.items.len});
        try writer.print("  Local frames:    {d}\n", .{ctx.local_frames.items.len});
        try writer.print("  Param frames:    {d}\n", .{ctx.parameter_env.items.len});

        // Dictionary
        const dict_count = ctx.dictionary.entries.count();
        var native_count: usize = 0;
        var compound_count: usize = 0;
        var parse_time_count: usize = 0;
        var imported_count: usize = 0;
        var iter = ctx.dictionary.entries.iterator();
        while (iter.next()) |entry| {
            const word = entry.value_ptr.*;
            switch (word.action) {
                .native => native_count += 1,
                .compound => compound_count += 1,
            }
            if (word.parse_time) parse_time_count += 1;
            if (word.imported) imported_count += 1;
        }
        try writer.writeAll("\nDictionary:\n");
        try writer.print("  Words:           {d}\n", .{dict_count});
        try writer.print("  Native:          {d}\n", .{native_count});
        try writer.print("  Compound:        {d}\n", .{compound_count});
        try writer.print("  Parse-time:      {d}\n", .{parse_time_count});
        try writer.print("  Imported:        {d}\n", .{imported_count});

        // Modules
        try writer.writeAll("\nModules:\n");
        try writer.print("  Loaded:          {d}\n", .{ctx.module_cache_value.count()});
        try writer.print("  Load paths:      {d}\n", .{ctx.load_paths.items.len});
        if (ctx.stdlib_path) |sp| {
            try writer.print("  Stdlib:          {s}\n", .{sp});
        }

        // Benchmark stats if enabled
        if (ctx.benchmark) |bench| {
            try writer.writeAll("\nInstructions:\n");
            try writer.writeAll("  push_literal:    ");
            try BenchmarkStats.formatNumber(writer, bench.push_literal_count);
            try writer.writeAll("\n");
            try writer.writeAll("  call_word:       ");
            try BenchmarkStats.formatNumber(writer, bench.call_word_count);
            try writer.writeAll("\n");
            try writer.writeAll("  Total:           ");
            try BenchmarkStats.formatNumber(writer, bench.totalInstructions());
            try writer.writeAll("\n");

            try writer.writeAll("\nMemory:\n");
            try writer.writeAll("  Allocations:     ");
            try BenchmarkStats.formatNumber(writer, bench.total_allocations);
            try writer.writeAll("\n");
            try writer.writeAll("  Total bytes:     ");
            try BenchmarkStats.formatBytes(writer, bench.total_bytes);
            try writer.writeAll("\n");
            try writer.writeAll("  Peak live:       ");
            try BenchmarkStats.formatBytes(writer, bench.peak_live_bytes);
            try writer.writeAll("\n");
            try writer.writeAll("  Current live:    ");
            try BenchmarkStats.formatBytes(writer, bench.current_live_bytes);
            try writer.writeAll("\n");

            try writer.writeAll("\nStack (benchmark):\n");
            try writer.print("  Peak depth:      {d}\n", .{bench.peak_stack_depth});
        }
    }
};
