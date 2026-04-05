const std = @import("std");
const Context = @import("context.zig").Context;
const StatementProcessor = @import("statement.zig").StatementProcessor;
const Value = @import("value.zig").Value;
const pascalToKebabRuntime = @import("primitives/errors.zig").pascalToKebabRuntime;

const OnezHandle = struct {
    gpa: *std.heap.GeneralPurposeAllocator(.{}),
    ctx: *Context,
    last_error: ?[:0]const u8 = null,
};

const page = std.heap.page_allocator;

// Type constants for onez_stack_type return values.
pub const ONEZ_TYPE_UNKNOWN: c_int = 0;
pub const ONEZ_TYPE_FIXNUM: c_int = 1;
pub const ONEZ_TYPE_FLOAT: c_int = 2;
pub const ONEZ_TYPE_BOOLEAN: c_int = 3;
pub const ONEZ_TYPE_STRING: c_int = 4;
pub const ONEZ_TYPE_SYMBOL: c_int = 5;
pub const ONEZ_TYPE_ARRAY: c_int = 6;
pub const ONEZ_TYPE_QUOTATION: c_int = 7;
pub const ONEZ_TYPE_HASH: c_int = 8;
pub const ONEZ_TYPE_VECTOR: c_int = 9;
pub const ONEZ_TYPE_BYTE_ARRAY: c_int = 10;
pub const ONEZ_TYPE_SET: c_int = 11;
pub const ONEZ_TYPE_MUTABLE_MAP: c_int = 12;
pub const ONEZ_TYPE_STREAM: c_int = 13;
pub const ONEZ_TYPE_RESOURCE: c_int = 14;
pub const ONEZ_TYPE_TAGGED: c_int = 15;
pub const ONEZ_TYPE_ITERATOR: c_int = 16;
pub const ONEZ_TYPE_TYPE_VAL: c_int = 17;
pub const ONEZ_TYPE_UNIT: c_int = 18;
pub const ONEZ_TYPE_STRUCT: c_int = 19;

// Error code constants.
pub const ONEZ_OK: c_int = 0;
pub const ONEZ_ERR_NULL_HANDLE: c_int = -1;
pub const ONEZ_ERR_TYPE_MISMATCH: c_int = 1;
pub const ONEZ_ERR_STACK_UNDERFLOW: c_int = 2;
pub const ONEZ_ERR_ALLOC: c_int = 3;
pub const ONEZ_ERR_NULL_VALUE: c_int = -2;
pub const ONEZ_ERR_INDEX_OUT_OF_RANGE: c_int = 4;
pub const ONEZ_ERR_KEY_NOT_FOUND: c_int = 5;

/// Initialize the 1z runtime for AOT-compiled programs.
///
/// The runtime loads the prelude only. This is sufficient because the build
/// rejects dynamic features (eval-string, load, etc.) and requires all
/// reachable words to compile to C. Native primitives are available via the
/// prelude dictionary; user words dispatch through the compiled function
/// table registered by onez_runtime_register_compiled.
export fn onez_init() ?*anyopaque {
    const gpa = page.create(std.heap.GeneralPurposeAllocator(.{})) catch return null;
    gpa.* = .{};
    const allocator = gpa.allocator();

    const ctx = allocator.create(Context) catch return null;
    ctx.* = Context.init(allocator);

    // stdlib relative to the library binary for now
    var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExeDirPath(&self_exe_buf)) |exe_dir| {
        const lib_path = std.fs.path.join(ctx.quotationAllocator(), &.{ exe_dir, "../lib" }) catch null;
        if (lib_path) |lp| {
            var real_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.cwd().realpath(lp, &real_buf)) |real| {
                ctx.stdlib_path = ctx.quotationAllocator().dupe(u8, real) catch null;
            } else |_| {}
        }
    } else |_| {}

    ctx.loadPrelude(null) catch return null;

    const handle = page.create(OnezHandle) catch return null;
    handle.* = .{
        .gpa = gpa,
        .ctx = ctx,
    };
    return handle;
}

export fn onez_deinit(ptr: ?*anyopaque) void {
    const handle = castHandle(ptr) orelse return;
    const allocator = handle.gpa.allocator();

    clearLastError(handle);

    if (handle.ctx.program_args.len > 0) {
        allocator.free(handle.ctx.program_args);
        handle.ctx.program_args = &.{};
    }

    handle.ctx.deinit();
    allocator.destroy(handle.ctx);
    _ = handle.gpa.deinit();
    page.destroy(handle.gpa);
    page.destroy(handle);
}

export fn onez_eval(ptr: ?*anyopaque, code: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;
    const alloc = ctx.quotationAllocator();
    const source = code[0..len];

    ctx.clearExecutionDetails();
    clearLastError(handle);

    var processor: StatementProcessor = .{};
    defer processor.deinit();

    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        start = end + 1;

        switch (processor.feedLine(alloc, line, ctx)) {
            .needs_more_input => continue,
            .parse_error => |err| {
                captureError(handle, err);
                return 1;
            },
            .complete => |instrs| {
                if (instrs.len > 0) {
                    ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                        captureError(handle, err);
                        return 1;
                    };
                }
                processor.reset();
            },
        }
    }

    switch (processor.flush(alloc, ctx)) {
        .needs_more_input => {},
        .parse_error => |err| {
            captureError(handle, err);
            return 1;
        },
        .complete => |instrs| {
            if (instrs.len > 0) {
                ctx.executeQuotation(.{ .instructions = instrs }) catch |err| {
                    captureError(handle, err);
                    return 1;
                };
            }
        },
    }

    return ONEZ_OK;
}

export fn onez_push_int(ptr: ?*anyopaque, value: i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .fixnum = value }) catch {
        setLastError(handle, "allocation failure pushing int", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_double(ptr: ?*anyopaque, value: f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .float = value }) catch {
        setLastError(handle, "allocation failure pushing double", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_bool(ptr: ?*anyopaque, value: bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    handle.ctx.stack.push(.{ .boolean = value }) catch {
        setLastError(handle, "allocation failure pushing bool", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_string(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying string", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stack.push(.{ .string = copy }) catch {
        setLastError(handle, "allocation failure pushing string", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_pop_value(ptr: ?*anyopaque, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop value from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    const slot = handle.ctx.quotationAllocator().create(Value) catch {
        handle.ctx.stack.push(val) catch {};
        setLastError(handle, "allocation failure creating value handle", .{});
        return ONEZ_ERR_ALLOC;
    };
    slot.* = val;
    out.* = slot;
    return ONEZ_OK;
}

export fn onez_push_value(ptr: ?*anyopaque, val_ptr: ?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_push_value", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    handle.ctx.stack.push(value.*) catch {
        setLastError(handle, "allocation failure pushing value", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_value_type(val_ptr: ?*anyopaque) c_int {
    const vp = val_ptr orelse return ONEZ_TYPE_UNKNOWN;
    const value: *const Value = @ptrCast(@alignCast(vp));
    return valueTypeToInt(value.*);
}

export fn onez_array_length(val_ptr: ?*anyopaque) usize {
    const vp = val_ptr orelse return 0;
    const value: *const Value = @ptrCast(@alignCast(vp));
    return switch (value.*) {
        .array => |a| a.len,
        else => 0,
    };
}

export fn onez_array_get(ptr: ?*anyopaque, val_ptr: ?*anyopaque, index: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_array_get", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .array => |a| {
            if (index >= a.len) {
                setLastError(handle, "index {d} out of range for array of length {d}", .{ index, a.len });
                return ONEZ_ERR_INDEX_OUT_OF_RANGE;
            }
            const slot = handle.ctx.quotationAllocator().create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = a[index];
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected array, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_hash_get(ptr: ?*anyopaque, val_ptr: ?*anyopaque, key: [*]const u8, key_len: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_hash_get", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .hash => |h| {
            const found = h.get(key[0..key_len]) orelse {
                setLastError(handle, "key not found", .{});
                return ONEZ_ERR_KEY_NOT_FOUND;
            };
            const slot = handle.ctx.quotationAllocator().create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = found;
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected hash, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_hash_keys(ptr: ?*anyopaque, val_ptr: ?*anyopaque, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_hash_keys", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .hash => |h| {
            const alloc = handle.ctx.quotationAllocator();
            const count = h.count();
            const keys = alloc.alloc(Value, count) catch {
                setLastError(handle, "allocation failure creating keys array", .{});
                return ONEZ_ERR_ALLOC;
            };
            var i: usize = 0;
            var it = h.iterator();
            while (it.next()) |entry| {
                keys[i] = .{ .symbol = entry.key_ptr.* };
                i += 1;
            }
            const slot = alloc.create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = .{ .array = keys };
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected hash, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_struct_get(ptr: ?*anyopaque, val_ptr: ?*anyopaque, field: [*]const u8, field_len: usize, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_struct_get", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .struct_instance => |si| {
            const field_name = field[0..field_len];
            for (si.struct_type.fields, 0..) |f, i| {
                if (std.mem.eql(u8, f, field_name)) {
                    const slot = handle.ctx.quotationAllocator().create(Value) catch {
                        setLastError(handle, "allocation failure creating value handle", .{});
                        return ONEZ_ERR_ALLOC;
                    };
                    slot.* = si.fields[i];
                    out.* = slot;
                    return ONEZ_OK;
                }
            }
            setLastError(handle, "field not found: {s}", .{field_name});
            return ONEZ_ERR_KEY_NOT_FOUND;
        },
        else => {
            setLastError(handle, "type mismatch: expected struct, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_push_symbol(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying symbol", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stack.push(.{ .symbol = copy }) catch {
        setLastError(handle, "allocation failure pushing symbol", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_push_array(ptr: ?*anyopaque, handles: [*]const ?*anyopaque, count: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const alloc = handle.ctx.quotationAllocator();
    const values = alloc.alloc(Value, count) catch {
        setLastError(handle, "allocation failure creating array", .{});
        return ONEZ_ERR_ALLOC;
    };
    for (0..count) |i| {
        const elem_ptr = handles[i] orelse {
            setLastError(handle, "null element handle at index {d}", .{i});
            return ONEZ_ERR_NULL_VALUE;
        };
        const elem: *const Value = @ptrCast(@alignCast(elem_ptr));
        values[i] = elem.*;
    }
    handle.ctx.stack.push(.{ .array = values }) catch {
        setLastError(handle, "allocation failure pushing array", .{});
        return ONEZ_ERR_ALLOC;
    };
    return ONEZ_OK;
}

export fn onez_virtual_type_name(val_ptr: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) c_int {
    const vp = val_ptr orelse return ONEZ_ERR_NULL_VALUE;
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .tagged => |t| {
            out_ptr.* = t.tag.name.ptr;
            out_len.* = t.tag.name.len;
            return ONEZ_OK;
        },
        else => return ONEZ_ERR_TYPE_MISMATCH,
    }
}

export fn onez_virtual_unwrap(ptr: ?*anyopaque, val_ptr: ?*anyopaque, out: *?*anyopaque) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const vp = val_ptr orelse {
        setLastError(handle, "null value handle passed to onez_virtual_unwrap", .{});
        return ONEZ_ERR_NULL_VALUE;
    };
    const value: *const Value = @ptrCast(@alignCast(vp));
    switch (value.*) {
        .tagged => |t| {
            const slot = handle.ctx.quotationAllocator().create(Value) catch {
                setLastError(handle, "allocation failure creating value handle", .{});
                return ONEZ_ERR_ALLOC;
            };
            slot.* = t.inner.*;
            out.* = slot;
            return ONEZ_OK;
        },
        else => {
            setLastError(handle, "type mismatch: expected tagged, got {s}", .{@tagName(value.*)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_int(ptr: ?*anyopaque, out: *i64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop int from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .fixnum => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected fixnum, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_double(ptr: ?*anyopaque, out: *f64) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop double from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .float => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected float, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_bool(ptr: ?*anyopaque, out: *bool) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop bool from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .boolean => |v| {
            out.* = v;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected boolean, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_pop_string(ptr: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.pop() catch {
        setLastError(handle, "stack underflow: cannot pop string from empty stack", .{});
        return ONEZ_ERR_STACK_UNDERFLOW;
    };
    switch (val) {
        .string => |s| {
            out_ptr.* = s.ptr;
            out_len.* = s.len;
            return ONEZ_OK;
        },
        else => {
            handle.ctx.stack.push(val) catch {};
            setLastError(handle, "type mismatch: expected string, got {s}", .{@tagName(val)});
            return ONEZ_ERR_TYPE_MISMATCH;
        },
    }
}

export fn onez_stack_depth(ptr: ?*anyopaque) usize {
    const handle = castHandle(ptr) orelse return 0;
    return handle.ctx.stack.depth();
}

export fn onez_stack_type(ptr: ?*anyopaque, index: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const val = handle.ctx.stack.peekN(index) catch return ONEZ_ERR_NULL_HANDLE;
    return valueTypeToInt(val);
}

export fn onez_last_error(ptr: ?*anyopaque) ?[*:0]const u8 {
    const handle = castHandle(ptr) orelse return null;
    if (handle.last_error) |err| return err.ptr else return null;
}

export fn onez_set_stdlib_path(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying stdlib path", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.stdlib_path = copy;
    return ONEZ_OK;
}

export fn onez_set_source(ptr: ?*anyopaque, data: [*]const u8, len: usize) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const copy = handle.ctx.quotationAllocator().dupe(u8, data[0..len]) catch {
        setLastError(handle, "allocation failure copying source name", .{});
        return ONEZ_ERR_ALLOC;
    };
    handle.ctx.current_source = copy;
    return ONEZ_OK;
}

export fn onez_set_args(ptr: ?*anyopaque, argc: c_int, argv: [*]const [*:0]const u8) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const allocator = handle.gpa.allocator();

    if (argc > 0) {
        const count: usize = @intCast(argc);
        const args = allocator.alloc([]const u8, count) catch return ONEZ_ERR_ALLOC;
        for (0..count) |idx| {
            args[idx] = std.mem.span(argv[idx]);
        }
        handle.ctx.program_args = args;

        const argv0 = std.mem.span(argv[0]);
        handle.ctx.current_source = handle.ctx.quotationAllocator().dupe(u8, argv0) catch argv0;
    }

    return ONEZ_OK;
}

/// Register library names that are statically linked into the executable.
///
/// When `lib-open` encounters one of these names at runtime, it uses
/// `dlopen(NULL)`, relying on the main executable's symbol table, instead of
/// loading a shared library. This enables AOT executables built with
/// `--link-static=LIB` to resolve FFI symbols without a runtime .so/.dylib.
///
/// This is a single-shot, non-additive call: it replaces any previously
/// registered list rather than appending to it. Must be called before
/// running any 1z code.
///
/// Also usable from the C embedding API -- any host that statically links
/// a library can call this to get the same behavior.
export fn onez_set_static_libs(ptr: ?*anyopaque, names: [*]const [*:0]const u8, count: u32) c_int {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const allocator = handle.gpa.allocator();
    const n: usize = @intCast(count);

    const libs = allocator.alloc([]const u8, n) catch return ONEZ_ERR_ALLOC;
    for (0..n) |i| {
        const name = std.mem.span(names[i]);
        libs[i] = allocator.dupe(u8, name) catch {
            for (0..i) |j| allocator.free(libs[j]);
            allocator.free(libs);
            return ONEZ_ERR_ALLOC;
        };
    }

    for (handle.ctx.static_ffi_libs) |old| allocator.free(old);
    if (handle.ctx.static_ffi_libs.len > 0) allocator.free(handle.ctx.static_ffi_libs);

    handle.ctx.static_ffi_libs = libs;
    return ONEZ_OK;
}

// =========================================================================
// AOT Runtime API
// =========================================================================

const ir_codegen = @import("ir_codegen.zig");
const JitContext = ir_codegen.JitContext;

export fn onez_runtime_register_compiled(ptr: ?*anyopaque, table: [*]const ?*const anyopaque, names: [*]const ?[*:0]const u8, size: u32) i32 {
    const handle = castHandle(ptr) orelse return ONEZ_ERR_NULL_HANDLE;
    const ctx = handle.ctx;

    ctx.jit_dispatch.ensureCapacity(size) catch return ONEZ_ERR_ALLOC;
    for (0..size) |i| {
        if (names[i]) |name_ptr| {
            const entry = ctx.jit_dispatch.getMut(@intCast(i)) orelse continue;
            entry.word_name = std.mem.span(name_ptr);
        }
        if (table[i]) |code_ptr| {
            ctx.jit_dispatch.setCodePtr(@intCast(i), code_ptr);
        }
    }
    return ONEZ_OK;
}

export fn onez_runtime_run(ptr: ?*anyopaque, entry_word_id: u32) i32 {
    const handle = castHandle(ptr) orelse return 1;
    const ctx = handle.ctx;

    const entry = ctx.jit_dispatch.get(entry_word_id) orelse return 1;
    var code_ptr = entry.code_ptr orelse return 1;

    var jit_ctx = JitContext{
        .items_ptr = ctx.stack.items.items.ptr,
        .sp_ptr = &ctx.stack.items.items.len,
        .capacity = ctx.stack.items.capacity,
        .ctx = ctx,
    };
    var func: *const fn (*JitContext) callconv(.c) i32 = @ptrCast(@alignCast(code_ptr));
    var status = func(&jit_ctx);

    // Trampoline loop for tail calls (status 3).
    while (status == 3) {
        const target_id = jit_ctx.trampoline_target;
        const target_entry = ctx.jit_dispatch.get(target_id) orelse return 1;
        code_ptr = target_entry.code_ptr orelse return 1;
        jit_ctx.items_ptr = ctx.stack.items.items.ptr;
        jit_ctx.capacity = ctx.stack.items.capacity;
        func = @ptrCast(@alignCast(code_ptr));
        status = func(&jit_ctx);
    }

    return if (status == 0) 0 else 1;
}

export fn onez_print_error(ptr: ?*anyopaque) void {
    const handle = castHandle(ptr) orelse return;
    const ctx = handle.ctx;

    const stderr_file: std.fs.File = .stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writer(&stderr_buf);

    const details = ctx.error_details.items;
    if (details.len > 0) {
        const detail = details[0];
        stderr.interface.print("{s}:{d}: error '{s}'", .{ detail.source, detail.line, detail.error_type }) catch {};

        if (detail.word_name != null and !std.mem.eql(u8, detail.message, detail.word_name.?)) {
            stderr.interface.print(" {s}", .{detail.message}) catch {};
        }

        if (detail.word_name) |word_name| {
            stderr.interface.print(" at word '{s}'", .{word_name}) catch {};
        }
        stderr.interface.writeAll("\n") catch {};

        if (detail.stack_effect_str) |se| {
            stderr.interface.print("  stack effect: {s}\n", .{se}) catch {};
        }
        if (detail.hint) |hint| {
            stderr.interface.print("  hint: {s}\n", .{hint}) catch {};
        }

        if (details.len > 1) {
            for (details[1..]) |frame| {
                stderr.interface.print("  called from {s}:{d}: {s}\n", .{
                    frame.source,
                    frame.line,
                    frame.word_name orelse frame.message,
                }) catch {};
            }
        }
    } else if (ctx.jit_pending_error) |err| {
        var kebab_buf: [128]u8 = undefined;
        const kebab_name = pascalToKebabRuntime(@errorName(err), &kebab_buf);
        stderr.interface.print("error.{s}\n", .{kebab_name}) catch {};
    } else {
        stderr.interface.writeAll("error: unknown runtime error\n") catch {};
    }

    stderr.interface.flush() catch {};
    ctx.clearExecutionDetails();
}

fn castHandle(ptr: ?*anyopaque) ?*OnezHandle {
    const p = ptr orelse return null;
    return @ptrCast(@alignCast(p));
}

fn clearLastError(handle: *OnezHandle) void {
    if (handle.last_error) |msg| {
        handle.gpa.allocator().free(@as([]const u8, msg.ptr[0 .. msg.len + 1]));
        handle.last_error = null;
    }
}

fn setLastError(handle: *OnezHandle, comptime fmt: []const u8, args: anytype) void {
    clearLastError(handle);
    handle.last_error = allocPrintZ(handle.gpa.allocator(), fmt, args) catch null;
}

fn captureError(handle: *OnezHandle, err: anyerror) void {
    clearLastError(handle);

    const details = handle.ctx.error_details.items;
    if (details.len > 0) {
        const detail = details[0];
        handle.last_error = allocPrintZ(
            handle.gpa.allocator(),
            "{s}:{d}: error '{s}'",
            .{ detail.source, detail.line, detail.error_type },
        ) catch null;
    } else {
        handle.last_error = allocPrintZ(
            handle.gpa.allocator(),
            "{s}",
            .{@errorName(err)},
        ) catch null;
    }
}

fn allocPrintZ(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const str = try std.fmt.allocPrint(alloc, fmt, args);
    const buf = try alloc.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    alloc.free(str);
    return buf[0..str.len :0];
}

fn valueTypeToInt(val: Value) c_int {
    return switch (val) {
        .fixnum => ONEZ_TYPE_FIXNUM,
        .float => ONEZ_TYPE_FLOAT,
        .boolean => ONEZ_TYPE_BOOLEAN,
        .string => ONEZ_TYPE_STRING,
        .symbol => ONEZ_TYPE_SYMBOL,
        .array => ONEZ_TYPE_ARRAY,
        .quotation => ONEZ_TYPE_QUOTATION,
        .hash => ONEZ_TYPE_HASH,
        .vector => ONEZ_TYPE_VECTOR,
        .byte_array => ONEZ_TYPE_BYTE_ARRAY,
        .set => ONEZ_TYPE_SET,
        .mutable_map => ONEZ_TYPE_MUTABLE_MAP,
        .stream => ONEZ_TYPE_STREAM,
        .resource => ONEZ_TYPE_RESOURCE,
        .tagged => ONEZ_TYPE_TAGGED,
        .iterator => ONEZ_TYPE_ITERATOR,
        .type_val => ONEZ_TYPE_TYPE_VAL,
        .unit => ONEZ_TYPE_UNIT,
        .struct_instance => ONEZ_TYPE_STRUCT,
        else => ONEZ_TYPE_UNKNOWN,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "init/eval/deinit round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);

    const rc = onez_eval(handle_ptr, "1 2 +", 5);
    try std.testing.expectEqual(@as(c_int, 0), rc);

    onez_deinit(handle_ptr);
}

test "eval error returns 1" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const rc = onez_eval(handle_ptr, "1 0 /", 5);
    try std.testing.expectEqual(@as(c_int, 1), rc);

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "null handle returns error" {
    try std.testing.expectEqual(@as(c_int, ONEZ_ERR_NULL_HANDLE), onez_eval(null, "", 0));
    onez_deinit(null); // should not crash!
}

test "push/pop int round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "push/pop double round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_double(handle_ptr, 3.14));
    var out: f64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_double(handle_ptr, &out));
    try std.testing.expectEqual(@as(f64, 3.14), out);
}

test "push/pop bool round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_bool(handle_ptr, true));
    var out: bool = false;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_bool(handle_ptr, &out));
    try std.testing.expect(out);
}

test "push/pop string round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const input = "hello";
    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, input.ptr, input.len));
    var out_ptr: [*]const u8 = undefined;
    var out_len: usize = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_string(handle_ptr, &out_ptr, &out_len));
    try std.testing.expectEqual(@as(usize, 5), out_len);
    try std.testing.expectEqualStrings("hello", out_ptr[0..out_len]);
}

test "pop type mismatch preserves stack" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var out: f64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_pop_double(handle_ptr, &out));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "pop stack underflow" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_STACK_UNDERFLOW, onez_pop_int(handle_ptr, &out));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expect(handle.last_error != null);
}

test "stack depth" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 1));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 2));
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 3));
    try std.testing.expectEqual(@as(usize, 3), onez_stack_depth(handle_ptr));
}

test "stack type at index" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, "hi", 2));

    // index 0 = top = string, index 1 = int
    try std.testing.expectEqual(ONEZ_TYPE_STRING, onez_stack_type(handle_ptr, 0));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_stack_type(handle_ptr, 1));
}

test "last_error null initially, non-null after failure" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expect(onez_last_error(handle_ptr) == null);

    var out: i64 = 0;
    _ = onez_pop_int(handle_ptr, &out);
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "set_stdlib_path updates ctx" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const path = "/custom/stdlib";
    try std.testing.expectEqual(ONEZ_OK, onez_set_stdlib_path(handle_ptr, path.ptr, path.len));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expectEqualStrings("/custom/stdlib", handle.ctx.stdlib_path.?);
}

test "set_source updates current_source" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const handle = castHandle(handle_ptr).?;
    try std.testing.expectEqualStrings("<repl>", handle.ctx.current_source);

    const name = "my-program";
    try std.testing.expectEqual(ONEZ_OK, onez_set_source(handle_ptr, name.ptr, name.len));
    try std.testing.expectEqualStrings("my-program", handle.ctx.current_source);
}

test "null handle returns appropriate defaults" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_int(null, 42));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_double(null, 3.14));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_bool(null, true));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_string(null, "x", 1));

    var i: i64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_int(null, &i));
    var f: f64 = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_double(null, &f));
    var b: bool = false;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_bool(null, &b));
    var sp: [*]const u8 = undefined;
    var sl: usize = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_string(null, &sp, &sl));

    try std.testing.expectEqual(@as(usize, 0), onez_stack_depth(null));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_stack_type(null, 0));
    try std.testing.expect(onez_last_error(null) == null);
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_set_stdlib_path(null, "x", 1));
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_set_args(null, 0, undefined));

    var vh: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_pop_value(null, &vh));
}

test "set_args populates program_args and source" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const argv = [_][*:0]const u8{ "my-program", "--flag" };
    try std.testing.expectEqual(ONEZ_OK, onez_set_args(handle_ptr, 2, &argv));

    const handle = castHandle(handle_ptr).?;
    try std.testing.expectEqual(@as(usize, 2), handle.ctx.program_args.len);
    try std.testing.expectEqualStrings("my-program", handle.ctx.program_args[0]);
    try std.testing.expectEqualStrings("--flag", handle.ctx.program_args[1]);
    try std.testing.expectEqualStrings("my-program", handle.ctx.current_source);
}

test "pop_value/push_value round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expect(val_handle != null);
    try std.testing.expectEqual(@as(usize, 0), onez_stack_depth(handle_ptr));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 42), out);
}

test "pop_value stack underflow" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_STACK_UNDERFLOW, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "value_type returns correct type code" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var val_handle: ?*anyopaque = null;

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 7));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_double(handle_ptr, 1.5));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_FLOAT, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_bool(handle_ptr, true));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_BOOLEAN, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_string(handle_ptr, "hi", 2));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_STRING, onez_value_type(val_handle));
}

test "value_type null handle returns UNKNOWN" {
    try std.testing.expectEqual(ONEZ_TYPE_UNKNOWN, onez_value_type(null));
}

test "push_value null ctx returns ERR_NULL_HANDLE" {
    var dummy: Value = .{ .fixnum = 0 };
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_value(null, &dummy));
}

test "push_value null value returns ERR_NULL_VALUE" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_push_value(handle_ptr, null));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "pop_value with eval-produced array" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 1 2 3 }", 9));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    try std.testing.expectEqual(@as(usize, 1), onez_stack_depth(handle_ptr));
}

test "handle survives eval call" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 99));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "1 2 +", 5));
    var discard: i64 = 0;
    _ = onez_pop_int(handle_ptr, &discard);

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);
}

test "handle can be pushed multiple times" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 55));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, val_handle));
    try std.testing.expectEqual(@as(usize, 2), onez_stack_depth(handle_ptr));

    var out1: i64 = 0;
    var out2: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out1));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out2));
    try std.testing.expectEqual(@as(i64, 55), out1);
    try std.testing.expectEqual(@as(i64, 55), out2);
}

test "array_length basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 1 2 3 }", 9));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(@as(usize, 3), onez_array_length(val_handle));
}

test "array_length null handle" {
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(null));
}

test "array_length non-array" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(val_handle));
}

test "array_get basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 10 20 30 }", 12));
    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_array_get(handle_ptr, arr_handle, 1, &elem));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(elem));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, elem));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 20), out);
}

test "array_get out of range" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "{ 1 2 }", 7));
    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_INDEX_OUT_OF_RANGE, onez_array_get(handle_ptr, arr_handle, 5, &elem));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "array_get type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_array_get(handle_ptr, val_handle, 0, &elem));
}

test "array_get null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_array_get(null, null, 0, &elem));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_array_get(handle_ptr, null, 0, &elem));
}

test "hash_get basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ \"x\" 1 \"y\" 2 }", 17));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));
    try std.testing.expectEqual(ONEZ_TYPE_HASH, onez_value_type(hash_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_hash_get(handle_ptr, hash_handle, "x", 1, &elem));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(elem));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, elem));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 1), out);
}

test "hash_get key not found" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ \"a\" 1 }", 10));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_KEY_NOT_FOUND, onez_hash_get(handle_ptr, hash_handle, "z", 1, &elem));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "hash_get type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_hash_get(handle_ptr, val_handle, "x", 1, &elem));
}

test "hash_get null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_hash_get(null, null, "x", 1, &elem));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_hash_get(handle_ptr, null, "x", 1, &elem));
}

test "hash_keys basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ \"a\" 1 \"b\" 2 }", 16));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));

    var keys_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_hash_keys(handle_ptr, hash_handle, &keys_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(keys_handle));
    try std.testing.expectEqual(@as(usize, 2), onez_array_length(keys_handle));
}

test "hash_keys empty hash" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, "H{ }", 4));
    var hash_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &hash_handle));

    var keys_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_hash_keys(handle_ptr, hash_handle, &keys_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(keys_handle));
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(keys_handle));
}

test "hash_keys type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var keys_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_hash_keys(handle_ptr, val_handle, &keys_handle));
}

test "struct_get basic field access" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "point: struct{ x y } ;\n10 20 make-point";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var struct_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &struct_handle));
    try std.testing.expectEqual(ONEZ_TYPE_STRUCT, onez_value_type(struct_handle));

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_struct_get(handle_ptr, struct_handle, "x", 1, &field_val));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(field_val));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, field_val));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 10), out);

    var field_y: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_struct_get(handle_ptr, struct_handle, "y", 1, &field_y));
    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, field_y));
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 20), out);
}

test "struct_get field not found" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "point2: struct{ x y } ;\n1 2 make-point2";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var struct_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &struct_handle));

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_KEY_NOT_FOUND, onez_struct_get(handle_ptr, struct_handle, "z", 1, &field_val));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "struct_get type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_struct_get(handle_ptr, val_handle, "x", 1, &field_val));
}

test "struct_get null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var field_val: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_struct_get(null, null, "x", 1, &field_val));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_struct_get(handle_ptr, null, "x", 1, &field_val));
}

test "push_symbol round-trip" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_symbol(handle_ptr, "foo", 3));
    try std.testing.expectEqual(ONEZ_TYPE_SYMBOL, onez_stack_type(handle_ptr, 0));

    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_SYMBOL, onez_value_type(val_handle));
}

test "push_symbol null handle" {
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_symbol(null, "x", 1));
}

test "push_array from handles" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    // Create three value handles
    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 10));
    var h0: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h0));

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 20));
    var h1: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h1));

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 30));
    var h2: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h2));

    const handles = [_]?*anyopaque{ h0, h1, h2 };
    try std.testing.expectEqual(ONEZ_OK, onez_push_array(handle_ptr, &handles, 3));

    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(arr_handle));
    try std.testing.expectEqual(@as(usize, 3), onez_array_length(arr_handle));

    var elem: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_array_get(handle_ptr, arr_handle, 1, &elem));
    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, elem));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 20), out);
}

test "push_array empty" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const handles = [_]?*anyopaque{};
    try std.testing.expectEqual(ONEZ_OK, onez_push_array(handle_ptr, &handles, 0));

    var arr_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &arr_handle));
    try std.testing.expectEqual(ONEZ_TYPE_ARRAY, onez_value_type(arr_handle));
    try std.testing.expectEqual(@as(usize, 0), onez_array_length(arr_handle));
}

test "push_array null element" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 1));
    var h0: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &h0));

    const handles = [_]?*anyopaque{ h0, null };
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_push_array(handle_ptr, &handles, 2));
    try std.testing.expect(onez_last_error(handle_ptr) != null);
}

test "push_array null handle" {
    const handles = [_]?*anyopaque{};
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_push_array(null, &handles, 0));
}

test "virtual_type_name basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "duration: virtual{ fixnum } ;\n42 make-duration";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_TAGGED, onez_value_type(val_handle));

    var name_ptr: [*]const u8 = undefined;
    var name_len: usize = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_virtual_type_name(val_handle, &name_ptr, &name_len));
    try std.testing.expectEqualStrings("duration", name_ptr[0..name_len]);
}

test "virtual_type_name type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var name_ptr: [*]const u8 = undefined;
    var name_len: usize = 0;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_virtual_type_name(val_handle, &name_ptr, &name_len));
}

test "virtual_type_name null handle" {
    var name_ptr: [*]const u8 = undefined;
    var name_len: usize = 0;
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_virtual_type_name(null, &name_ptr, &name_len));
}

test "virtual_unwrap basic" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "wrapper: virtual{ fixnum } ;\n99 make-wrapper";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));
    try std.testing.expectEqual(ONEZ_TYPE_TAGGED, onez_value_type(val_handle));

    var inner: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_virtual_unwrap(handle_ptr, val_handle, &inner));
    try std.testing.expectEqual(ONEZ_TYPE_FIXNUM, onez_value_type(inner));

    try std.testing.expectEqual(ONEZ_OK, onez_push_value(handle_ptr, inner));
    var out: i64 = 0;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_int(handle_ptr, &out));
    try std.testing.expectEqual(@as(i64, 99), out);
}

test "virtual_unwrap type mismatch" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    try std.testing.expectEqual(ONEZ_OK, onez_push_int(handle_ptr, 42));
    var val_handle: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_OK, onez_pop_value(handle_ptr, &val_handle));

    var inner: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_TYPE_MISMATCH, onez_virtual_unwrap(handle_ptr, val_handle, &inner));
}

test "virtual_unwrap null handle and null value" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    var inner: ?*anyopaque = null;
    try std.testing.expectEqual(ONEZ_ERR_NULL_HANDLE, onez_virtual_unwrap(null, null, &inner));
    try std.testing.expectEqual(ONEZ_ERR_NULL_VALUE, onez_virtual_unwrap(handle_ptr, null, &inner));
}

test "struct_instance returns ONEZ_TYPE_STRUCT" {
    const handle_ptr = onez_init();
    try std.testing.expect(handle_ptr != null);
    defer onez_deinit(handle_ptr);

    const code = "pt: struct{ a b } ;\n1 2 make-pt";
    try std.testing.expectEqual(ONEZ_OK, onez_eval(handle_ptr, code.ptr, code.len));
    try std.testing.expectEqual(ONEZ_TYPE_STRUCT, onez_stack_type(handle_ptr, 0));
}
