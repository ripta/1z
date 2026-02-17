const std = @import("std");
const builtin = @import("builtin");
const c_ffi = @cImport({
    @cInclude("ffi/ffi.h");
});
const Context = @import("../context.zig").Context;
const helpers = @import("../primitives/helpers.zig");
const error_mapping = @import("../primitives/error_mapping.zig");
const RegistryEntry = @import("../primitives/types.zig").RegistryEntry;
const FfiTypeTag = signature.FfiTypeTag;
const Value = @import("../value.zig").Value;
const Resource = @import("../value.zig").Resource;
const ByteArray = @import("../value.zig").ByteArray;
const signature = @import("signature.zig");
const FfiType = signature.FfiType;
const FfiSignature = signature.FfiSignature;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "lib-open", .func = nativeLibOpen },
    .{ .name = "lib-symbol", .func = nativeLibSymbol },
    .{ .name = "bind-sig", .func = nativeBindSig },
    .{ .name = "ffi-call", .func = nativeFfiCall },
    .{ .name = "bytes-raw-ptr", .func = nativeBytesRawPtr },
};

fn dylibCloseFn(ptr: *anyopaque) void {
    const dl: *std.DynLib = @ptrCast(@alignCast(ptr));
    dl.close();
}

fn isExplicitPath(name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return true;
    if (std.mem.endsWith(u8, name, ".dylib")) return true;
    if (std.mem.endsWith(u8, name, ".so")) return true;
    if (std.mem.endsWith(u8, name, ".dll")) return true;
    return false;
}

fn allocPrintZ(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const str = try std.fmt.allocPrint(alloc, fmt, args);
    const buf = try alloc.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

/// lib-open ( path-or-name -- dylib ) - Opens a dynamic library and returns a resource handle to it.
///
/// The argument can be either an explicit path (e.g., "./libfoo.so" or "C:\foo.dll")
/// or just a library namec (e.g., "foo"). If a library name is given, the implementation
/// will attempt to resolve it to an actual library file using platform-specific conventions
/// (e.g., "foo" -> "libfoo.so" on Linux).
///
/// The returned resource must be closed when no longer needed to free associated resources.
fn nativeLibOpen(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();
    const name = try helpers.popString(ctx);

    const open_name: [:0]const u8 = if (isExplicitPath(name))
        try alloc.dupeZ(u8, name)
    else switch (builtin.os.tag) {
        .macos => try allocPrintZ(alloc, "lib{s}.dylib", .{name}),
        .linux => try allocPrintZ(alloc, "lib{s}.so", .{name}),
        .windows => try allocPrintZ(alloc, "{s}.dll", .{name}),
        else => try alloc.dupeZ(u8, name),
    };

    const dynlib_ptr = try alloc.create(std.DynLib);
    dynlib_ptr.* = std.DynLib.open(open_name) catch {
        helpers.setErrorContext(ctx, "library not found: {s}", .{open_name});
        return error.FFILibraryNotFound;
    };

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "dylib",
        .ptr = @ptrCast(dynlib_ptr),
        .closed = false,
        .close_fn = dylibCloseFn,
    };
    try ctx.stack.push(.{ .resource = r });
}

/// lib-symbol ( dylib symbol-name -- ffi-fn ) - Retrieves a symbol from a dynamic library.
///
/// The first argument must be a resource handle to a dynamic library as returned
/// by lib-open, and the second argument is the name of the symbol to retrieve.
///
/// If the symbol is found, a new resource of type "ffi-fn" is returned, which encapsulates
/// a pointer to the symbol. This "ffi-fn" resource can then be used with bind-sig to
/// associate it with a signature for invocation.
fn nativeLibSymbol(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();
    const name = try helpers.popString(ctx);
    const lib_resource = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(lib_resource);

    if (!std.mem.eql(u8, lib_resource.type_name, "dylib")) {
        helpers.setTypeMismatchError(ctx, "dylib resource", .{ .resource = lib_resource });
        return error.TypeMismatch;
    }

    const dynlib_ptr: *std.DynLib = @ptrCast(@alignCast(lib_resource.ptr.?));
    const name_z = try alloc.dupeZ(u8, name);

    const sym = dynlib_ptr.lookup(*anyopaque, name_z) orelse {
        helpers.setErrorContext(ctx, "symbol not found: {s}", .{name});
        return error.FFISymbolNotFound;
    };

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "ffi-fn",
        .ptr = sym,
        .closed = false,
        .close_fn = null,
    };
    try ctx.stack.push(.{ .resource = r });
}

/// bind-sig ( ffi-fn ffi-sig -- ffi-fn ) - Associates a signature with an ffi-fn resource.
///
/// This function takes an "ffi-fn" resource and an "ffi-sig" struct instance, validates their types,
/// and extracts the parameter and return type information from the "ffi-sig". It then constructs
/// an internal FfiSignature representation and attaches it to the "ffi-fn" resource for
fn nativeBindSig(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();

    const sig_val = try ctx.stack.pop();
    const ffi_fn_val = try ctx.stack.pop();

    // Validate ffi-fn resource
    const ffi_fn = switch (ffi_fn_val) {
        .resource => |r| r,
        else => {
            helpers.setTypeMismatchError(ctx, "ffi-fn resource", ffi_fn_val);
            return error.TypeMismatch;
        },
    };
    try error_mapping.ensureResourceOpen(ffi_fn);
    if (!std.mem.eql(u8, ffi_fn.type_name, "ffi-fn")) {
        helpers.setTypeMismatchError(ctx, "ffi-fn resource", ffi_fn_val);
        return error.TypeMismatch;
    }

    // Validate ffi-sig struct instance
    const si = switch (sig_val) {
        .struct_instance => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "ffi-sig struct", sig_val);
            return error.TypeMismatch;
        },
    };
    if (!std.mem.eql(u8, si.struct_type.name, "ffi-sig")) {
        helpers.setTypeMismatchError(ctx, "ffi-sig struct", sig_val);
        return error.TypeMismatch;
    }

    // Extract params from field 0
    const params_val = si.fields[0];
    const params_array = switch (params_val) {
        .array => |a| a,
        else => {
            helpers.setTypeMismatchError(ctx, "array for params", params_val);
            return error.TypeMismatch;
        },
    };

    // Extract return type from field 1
    const return_type_val = si.fields[1];
    const return_type_str = switch (return_type_val) {
        .string => |s| s,
        else => {
            helpers.setTypeMismatchError(ctx, "string for return-type", return_type_val);
            return error.TypeMismatch;
        },
    };

    // Parse param type tokens
    var param_types = try alloc.alloc(FfiType, params_array.len);
    for (params_array, 0..) |param_val, i| {
        const token = switch (param_val) {
            .string => |s| s,
            else => {
                helpers.setTypeMismatchError(ctx, "string for param type", param_val);
                return error.TypeMismatch;
            },
        };
        param_types[i] = signature.parseTypeToken(token) catch {
            helpers.setErrorContext(ctx, "unknown FFI type: {s}", .{token});
            return error.FFITypeMismatch;
        };
        if (param_types[i].tag == .void_type) {
            helpers.setErrorContext(ctx, "void is not valid as a parameter type", .{});
            return error.FFITypeMismatch;
        }
    }

    // Parse return type token
    const return_type = signature.parseTypeToken(return_type_str) catch {
        helpers.setErrorContext(ctx, "unknown FFI type: {s}", .{return_type_str});
        return error.FFITypeMismatch;
    };

    // Store final signature
    const sig = try alloc.create(FfiSignature);
    sig.* = .{
        .param_types = param_types,
        .return_type = return_type,
    };

    ffi_fn.ffi_signature = sig;
    try ctx.stack.push(ffi_fn_val);
}

/// Map an FfiTypeTag to the corresponding libffi type descriptor.
fn ffiTypeToLibffi(tag: FfiTypeTag) [*c]c_ffi.ffi_type {
    return switch (tag) {
        .i32 => &c_ffi.ffi_type_sint32,
        .i64 => &c_ffi.ffi_type_sint64,
        .u32 => &c_ffi.ffi_type_uint32,
        .u64 => &c_ffi.ffi_type_uint64,
        .f64 => &c_ffi.ffi_type_double,
        .cstring, .cstring_retained, .cstring_owned => &c_ffi.ffi_type_pointer,
        .ptr => &c_ffi.ffi_type_pointer,
        .void_type => &c_ffi.ffi_type_void,
    };
}

/// Storage for a single marshaled FFI argument. Each variant holds a value
/// that can be referenced by pointer for the libffi avalue array.
const ArgSlot = extern union {
    i32_val: i32,
    i64_val: i64,
    u32_val: u32,
    u64_val: u64,
    f64_val: f64,
    ptr_val: ?*anyopaque,
};

/// ffi-call ( args... ffi-fn -- result ) - Calls a foreign function with the given arguments and returns the result.
///
/// This function expects the arguments to be on the stack, followed by an "ffi-fn"
/// resource that has been associated with a signature using bind-sig. It validates
///  the types of the arguments against the expected parameter types in the signature,
/// marshals the arguments into the appropriate C representations, and then uses libffi
/// to call the foreign function.
///
/// After the call, it marshals the return value back into a 1z Value and pushes it onto the stack.
fn nativeFfiCall(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();

    const ffi_fn_val = try ctx.stack.pop();
    const ffi_fn = switch (ffi_fn_val) {
        .resource => |r| r,
        else => {
            helpers.setTypeMismatchError(ctx, "ffi-fn resource", ffi_fn_val);
            return error.TypeMismatch;
        },
    };
    try error_mapping.ensureResourceOpen(ffi_fn);
    if (!std.mem.eql(u8, ffi_fn.type_name, "ffi-fn")) {
        helpers.setTypeMismatchError(ctx, "ffi-fn resource", ffi_fn_val);
        return error.TypeMismatch;
    }

    const sig = ffi_fn.ffi_signature orelse {
        helpers.setErrorContext(ctx, "ffi-fn has no bound signature (use bind-sig)", .{});
        return error.FFICallFailed;
    };

    const nargs = sig.param_types.len;
    if (ctx.stack.depth() < nargs) {
        helpers.setErrorContext(ctx, "ffi-call expected {d} arguments, got {d}", .{ nargs, ctx.stack.depth() });
        return error.FFICallFailed;
    }

    // NOTE: pop arguments from the stack, with the convention that rightmost
    //       (top-of-stack) is the last C param
    var arg_vals = try alloc.alloc(Value, nargs);
    var i: usize = nargs;
    while (i > 0) {
        i -= 1;
        arg_vals[i] = try ctx.stack.pop();
    }

    var arg_types = try alloc.alloc([*c]c_ffi.ffi_type, nargs);
    var arg_slots = try alloc.alloc(ArgSlot, nargs);
    var arg_ptrs = try alloc.alloc(?*anyopaque, nargs);

    for (sig.param_types, 0..) |param_type, pi| {
        arg_types[pi] = ffiTypeToLibffi(param_type.tag);
        arg_slots[pi] = try marshalArg(ctx, param_type, arg_vals[pi], pi);
        arg_ptrs[pi] = @ptrCast(&arg_slots[pi]);
    }

    var cif: c_ffi.ffi_cif = undefined;
    const prep_status = c_ffi.ffi_prep_cif(
        &cif,
        c_ffi.FFI_DEFAULT_ABI,
        @intCast(nargs),
        ffiTypeToLibffi(sig.return_type.tag),
        if (nargs > 0) arg_types.ptr else null,
    );
    if (prep_status != c_ffi.FFI_OK) {
        helpers.setErrorContext(ctx, "ffi_prep_cif failed (status {d})", .{prep_status});
        return error.FFICallFailed;
    }

    // Call the foreign function
    var ret_storage: ReturnStorage = .{ .as_u64 = 0 };
    const fn_ptr: ?*const fn () callconv(.c) void = @ptrCast(@alignCast(ffi_fn.ptr.?));
    c_ffi.ffi_call(
        &cif,
        fn_ptr,
        @ptrCast(&ret_storage),
        if (nargs > 0) arg_ptrs.ptr else null,
    );

    try marshalReturn(ctx, sig.return_type, &ret_storage);
}

const ReturnStorage = extern union {
    as_u64: u64,
    as_i64: i64,
    as_f64: f64,
    as_ptr: ?*anyopaque,
};

/// Validate a 1z stack value against an FFI param type and marshal it into an ArgSlot.
fn marshalArg(ctx: *Context, param_type: FfiType, val: Value, arg_index: usize) !ArgSlot {
    const alloc = ctx.arena.allocator();
    switch (param_type.tag) {
        .i32 => {
            const fixnum = switch (val) {
                .fixnum => |v| v,
                else => return argTypeMismatch(ctx, "fixnum for i32", val, arg_index),
            };
            return .{ .i32_val = @intCast(fixnum) };
        },
        .i64 => {
            const fixnum = switch (val) {
                .fixnum => |v| v,
                else => return argTypeMismatch(ctx, "fixnum for i64", val, arg_index),
            };
            return .{ .i64_val = fixnum };
        },
        .u32 => {
            const fixnum = switch (val) {
                .fixnum => |v| v,
                else => return argTypeMismatch(ctx, "fixnum for u32", val, arg_index),
            };
            return .{ .u32_val = @intCast(fixnum) };
        },
        .u64 => {
            const fixnum = switch (val) {
                .fixnum => |v| v,
                else => return argTypeMismatch(ctx, "fixnum for u64", val, arg_index),
            };
            return .{ .u64_val = @intCast(fixnum) };
        },
        .f64 => {
            const float = switch (val) {
                .float => |v| v,
                else => return argTypeMismatch(ctx, "float for f64", val, arg_index),
            };
            return .{ .f64_val = float };
        },
        .cstring, .cstring_retained => {
            const str = switch (val) {
                .string => |s| s,
                else => return argTypeMismatch(ctx, "string for cstring", val, arg_index),
            };
            const cstr = try alloc.dupeZ(u8, str);
            return .{ .ptr_val = @ptrCast(cstr.ptr) };
        },
        .ptr => {
            const resource = switch (val) {
                .resource => |r| r,
                else => return argTypeMismatch(ctx, "resource for ptr", val, arg_index),
            };
            try error_mapping.ensureResourceOpen(resource);
            if (param_type.ptr_name) |expected_name| {
                if (!std.mem.eql(u8, resource.type_name, expected_name)) {
                    helpers.setErrorContext(ctx, "argument {d}: expected resource type '{s}', got '{s}'", .{ arg_index + 1, expected_name, resource.type_name });
                    return error.FFITypeMismatch;
                }
            }
            return .{ .ptr_val = resource.ptr };
        },
        .cstring_owned => {
            helpers.setErrorContext(ctx, "argument {d}: cstring-owned is not valid as a parameter type", .{arg_index + 1});
            return error.FFITypeMismatch;
        },
        .void_type => {
            helpers.setErrorContext(ctx, "argument {d}: void is not valid as a parameter type", .{arg_index + 1});
            return error.FFITypeMismatch;
        },
    }
}

fn argTypeMismatch(ctx: *Context, expected: []const u8, val: Value, arg_index: usize) error{FFITypeMismatch} {
    const type_name = helpers.valueTypeName(val);
    helpers.setErrorContext(ctx, "argument {d}: expected {s}, got {s}", .{ arg_index + 1, expected, type_name });
    return error.FFITypeMismatch;
}

/// Marshal a C return value back to a 1z Value and push it onto the stack.
fn marshalReturn(ctx: *Context, return_type: FfiType, ret: *const ReturnStorage) !void {
    const alloc = ctx.arena.allocator();
    switch (return_type.tag) {
        .i32 => {
            const val: i32 = @truncate(@as(i64, @bitCast(ret.as_i64)));
            try ctx.stack.push(.{ .fixnum = @intCast(val) });
        },
        .i64 => {
            try ctx.stack.push(.{ .fixnum = ret.as_i64 });
        },
        .u32 => {
            const val: u32 = @truncate(ret.as_u64);
            try ctx.stack.push(.{ .fixnum = @intCast(val) });
        },
        .u64 => {
            try ctx.stack.push(.{ .fixnum = @intCast(ret.as_u64) });
        },
        .f64 => {
            try ctx.stack.push(.{ .float = ret.as_f64 });
        },
        .cstring => {
            const cptr: [*c]const u8 = @ptrCast(ret.as_ptr);
            if (cptr == null) {
                try ctx.stack.push(.{ .string = "" });
            } else {
                const span = std.mem.span(cptr);
                const str = try alloc.dupe(u8, span);
                try ctx.stack.push(.{ .string = str });
            }
        },
        .cstring_owned => {
            const cptr: [*c]u8 = @ptrCast(ret.as_ptr);
            if (cptr == null) {
                try ctx.stack.push(.{ .string = "" });
            } else {
                const span = std.mem.span(cptr);
                const str = try alloc.dupe(u8, span);
                std.c.free(cptr);
                try ctx.stack.push(.{ .string = str });
            }
        },
        .cstring_retained => {
            const cptr: [*c]const u8 = @ptrCast(ret.as_ptr);
            if (cptr == null) {
                try ctx.stack.push(.{ .string = "" });
            } else {
                const span = std.mem.span(cptr);
                const str = try alloc.dupe(u8, span);
                try ctx.stack.push(.{ .string = str });
            }
        },
        .ptr => {
            const type_name = return_type.ptr_name orelse "ffi-ptr";
            const r = try alloc.create(Resource);
            r.* = .{
                .type_name = type_name,
                .ptr = ret.as_ptr,
                .closed = false,
                .close_fn = null,
            };
            try ctx.stack.push(.{ .resource = r });
        },
        .void_type => {},
    }
}

/// bytes-raw-ptr ( byte-array -- resource fixnum )
/// Extracts the raw buffer pointer and length from a byte array.
/// The resource wraps the internal buffer pointer; it becomes dangling
/// if the byte array is resized or freed.
fn nativeBytesRawPtr(ctx: *Context) anyerror!void {
    const alloc = ctx.arena.allocator();

    const ba = try helpers.popByteArray(ctx);

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "ffi-bytes",
        .ptr = @ptrCast(ba.items.ptr),
        .closed = false,
        .close_fn = null,
    };

    try ctx.stack.push(.{ .resource = r });
    try ctx.stack.push(.{ .fixnum = @intCast(ba.items.len) });
}
