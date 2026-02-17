const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../context.zig").Context;
const helpers = @import("../primitives/helpers.zig");
const error_mapping = @import("../primitives/error_mapping.zig");
const RegistryEntry = @import("../primitives/types.zig").RegistryEntry;
const Value = @import("../value.zig").Value;
const Resource = @import("../value.zig").Resource;
const signature = @import("signature.zig");
const FfiType = signature.FfiType;
const FfiSignature = signature.FfiSignature;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "lib-open", .func = nativeLibOpen },
    .{ .name = "lib-symbol", .func = nativeLibSymbol },
    .{ .name = "bind-sig", .func = nativeBindSig },
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
