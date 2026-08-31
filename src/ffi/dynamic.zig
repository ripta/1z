const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

// Freestanding builds have no libffi headers and no dynamic linker. Every
// registered native gates on `is_freestanding` and throws BuildUnsupported
// before reaching any c_ffi reference; this stub keeps the surrounding
// function signatures well-typed so the module still compiles.
pub const c_ffi = if (is_freestanding) struct {
    pub const ffi_type = extern struct {};
    pub const ffi_cif = extern struct {};
    pub const ffi_closure = extern struct {};
    pub const ffi_status = c_uint;
    pub const FFI_OK: c_uint = 0;
    pub const FFI_DEFAULT_ABI: c_uint = 0;
    pub const FFI_TYPE_STRUCT: c_uint = 0;

    pub var ffi_type_void: ffi_type = .{};
    pub var ffi_type_pointer: ffi_type = .{};
    pub var ffi_type_float: ffi_type = .{};
    pub var ffi_type_double: ffi_type = .{};
    pub var ffi_type_sint8: ffi_type = .{};
    pub var ffi_type_sint16: ffi_type = .{};
    pub var ffi_type_sint32: ffi_type = .{};
    pub var ffi_type_sint64: ffi_type = .{};
    pub var ffi_type_uint8: ffi_type = .{};
    pub var ffi_type_uint16: ffi_type = .{};
    pub var ffi_type_uint32: ffi_type = .{};
    pub var ffi_type_uint64: ffi_type = .{};

    pub fn ffi_prep_cif(cif: ?*ffi_cif, abi: c_uint, nargs: c_uint, rtype: [*c]ffi_type, atypes: [*c][*c]ffi_type) callconv(.c) ffi_status {
        _ = cif;
        _ = abi;
        _ = nargs;
        _ = rtype;
        _ = atypes;
        return 0;
    }
    pub fn ffi_prep_cif_var(cif: ?*ffi_cif, abi: c_uint, nfixed: c_uint, ntotal: c_uint, rtype: [*c]ffi_type, atypes: [*c][*c]ffi_type) callconv(.c) ffi_status {
        _ = cif;
        _ = abi;
        _ = nfixed;
        _ = ntotal;
        _ = rtype;
        _ = atypes;
        return 0;
    }
    pub fn ffi_call(cif: ?*ffi_cif, fn_ptr: ?*const fn () callconv(.c) void, rvalue: ?*anyopaque, avalue: [*c]?*anyopaque) callconv(.c) void {
        _ = cif;
        _ = fn_ptr;
        _ = rvalue;
        _ = avalue;
    }
    pub fn ffi_closure_alloc(size: usize, code: [*c]?*anyopaque) callconv(.c) ?*anyopaque {
        _ = size;
        _ = code;
        return null;
    }
    pub fn ffi_closure_free(ptr: ?*anyopaque) callconv(.c) void {
        _ = ptr;
    }
    pub fn ffi_prep_closure_loc(closure: ?*ffi_closure, cif: ?*ffi_cif, fun: ?*const fn () callconv(.c) void, user_data: ?*anyopaque, code_loc: ?*anyopaque) callconv(.c) ffi_status {
        _ = closure;
        _ = cif;
        _ = fun;
        _ = user_data;
        _ = code_loc;
        return 0;
    }
    pub fn ffi_get_struct_offsets(abi: c_uint, struct_type: [*c]ffi_type, offsets: [*c]usize) callconv(.c) ffi_status {
        _ = abi;
        _ = struct_type;
        _ = offsets;
        return 0;
    }
} else @cImport({
    @cInclude("ffi.h");
});

const callable_mod = @import("../callable.zig");
const Callable = callable_mod.Callable;
const Context = @import("../context.zig").Context;
const helpers = @import("../primitives/helpers.zig");
const error_mapping = @import("../primitives/error_mapping.zig");
const errors_mod = @import("../primitives/errors.zig");

const types_mod = @import("../primitives/types.zig");
const RegistryEntry = types_mod.RegistryEntry;
const SandboxSpec = types_mod.SandboxSpec;
const Capability = types_mod.Capability;
const HashTable = value_mod.HashTable;

const container_backing = @import("../container_backing.zig");

const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const BigIntManaged = value_mod.BigIntManaged;
const Resource = value_mod.Resource;
const FfiCloseFn = value_mod.FfiCloseFn;
const ByteArray = value_mod.ByteArray;
const VirtualType = value_mod.VirtualType;
const Quotation = value_mod.Quotation;

const signature = @import("signature.zig");
const FfiType = signature.FfiType;
const FfiTypeTag = signature.FfiTypeTag;
const FfiSignature = signature.FfiSignature;
const VariadicSpec = signature.VariadicSpec;
const ErrnoSentinel = signature.ErrnoSentinel;

const struct_layout = @import("struct_layout.zig");
const FfiStructLayout = struct_layout.FfiStructLayout;

pub const registry_entries = [_]RegistryEntry{
    .{ .name = "lib-open", .func = nativeLibOpen, .capability = .ffi },
    .{ .name = "lib-symbol", .func = nativeLibSymbol, .capability = .ffi },
    .{ .name = "bind-sig", .func = nativeBindSig, .capability = .ffi },
    .{ .name = "bind-close", .func = nativeBindClose, .capability = .ffi },
    .{ .name = "ffi-call", .func = nativeFfiCall, .capability = .none },
    .{ .name = "ffi-callback", .func = nativeFfiCallback, .capability = .ffi },
    .{ .name = "take-callback-error", .func = nativeTakeCallbackError, .capability = .none, .stack_effect = "-- error/f" },
    .{ .name = "bytes-raw-ptr", .func = nativeBytesRawPtr, .capability = .ffi },
    .{ .name = "ffi-ptr+len>bytes", .func = nativeFfiPtrLenToBytes, .capability = .ffi, .stack_effect = "resource n -- byte-array" },
    .{ .name = "ffi-ptr+len>borrowed-bytes", .func = nativeFfiPtrLenToBorrowedBytes, .capability = .ffi, .stack_effect = "resource n -- byte-array" },
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

/// Function type of the platform errno fetcher: returns a pointer to the thread-local errno slot,
/// i.e., `__errno_location` on glibc/musl, `__error` on macOS.
const ErrnoLocationFn = *const fn () callconv(.c) *c_int;

/// The platform errno fetcher, resolved at link time via `std.c._errno`, a comptime-selected extern
/// mapping to the right per-platform symbol.
///
/// Null on freestanding builds, which have no libc.
const errno_location_fn: ?ErrnoLocationFn = if (is_freestanding) null else std.c._errno;

/// Read the current thread's `errno`.
///
/// Must be called immediately after the failing libc call, before any other libc call on the same
/// thread clobbers the slot.
///
/// Returns 0 on freestanding builds.
pub fn readErrno() c_int {
    const fetch = errno_location_fn orelse return 0;
    return fetch().*;
}

const StrerrorFn = *const fn (c_int) callconv(.c) [*:0]const u8;

/// The libc `strerror`, resolved at link time.
///
/// Null on freestanding builds, which have no libc.
/// Unreachable in freestanding builds.
const strerror_fn: ?StrerrorFn = if (is_freestanding) null else @extern(StrerrorFn, .{ .name = "strerror" });

/// Check the binding's declared capability against the active sandbox.
/// Bindings that declare nothing keep the `.ffi` default.
fn checkBindingCapability(ctx: *Context, sig: *const FfiSignature) !void {
    if (ctx.active_sandbox) |sandbox| {
        if (!sandbox.allows(sig.capability)) {
            helpers.setErrorContext(ctx, "FFI binding requires capability '{s}' which is not granted by the active sandbox", .{sig.capability.displayName()});
            return error.PermissionDenied;
        }
    }
}

/// Test a scalar/pointer return value against the binding's failure sentinel.
/// The integer interpretation mirrors marshalReturn: signed tags read `as_i64`,
/// unsigned tags read `as_u64`, pointer-like tags read the address. Float, void,
/// and struct returns never signal errno failure.
fn sentinelMatches(sentinel: ErrnoSentinel, return_type: FfiType, ret: *const ReturnStorage) bool {
    switch (return_type.tag) {
        .i8, .i16, .i32, .i64, .isize_type => {
            const v = ret.as_i64;
            return switch (sentinel) {
                .none => false,
                .neg1 => v == -1,
                .neg => v < 0,
                .null_ptr => v == 0,
            };
        },
        .u8, .u16, .u32, .u64, .usize_type => {
            const v = ret.as_u64;
            return switch (sentinel) {
                .none, .neg1, .neg => false,
                .null_ptr => v == 0,
            };
        },
        .bool_type => {
            const v: u8 = @truncate(ret.as_u64);
            return sentinel == .null_ptr and v == 0;
        },
        .ptr, .cstring, .cstring_retained, .cstring_owned => {
            const addr = @intFromPtr(ret.as_ptr);
            return switch (sentinel) {
                .none, .neg => false,
                .neg1 => addr == std.math.maxInt(usize),
                .null_ptr => addr == 0,
            };
        },
        .f32, .f64, .void_type, .struct_type => return false,
    }
}

/// Build the portable errno name symbol: `"e"` ++ lowercase of the `std.c.E`
/// tag name (e.g. `EACCES` -> `eacces`). Falls back to `e<decimal>` for an
/// errno with no named enum tag. The result is owned by `alloc`.
fn errnoName(alloc: std.mem.Allocator, e: c_int) ![]const u8 {
    const E = std.c.E;
    const Tag = @typeInfo(E).@"enum".tag_type;
    if (std.math.cast(Tag, e)) |tag_val| {
        if (std.enums.tagName(E, @enumFromInt(tag_val))) |name| {
            const buf = try alloc.alloc(u8, name.len + 1);
            buf[0] = 'e';
            for (name, 0..) |c, i| buf[i + 1] = std.ascii.toLower(c);
            return buf;
        }
    }
    return std.fmt.allocPrint(alloc, "e{d}", .{e});
}

/// Raise `EPosixError` (`posix-error:`) for a failing errno-convention call.
/// The error carries `data` `H{ errno: <int> name: <symbol> }` (raw platform
/// integer plus portable name) and a `strerror`-derived message. Stashes the
/// error and returns `error.UserThrown`, mirroring `throw`.
fn raisePosixError(ctx: *Context, e: c_int) anyerror!void {
    const alloc = ctx.quotationAllocator();

    const name = try errnoName(alloc, e);

    // The deliberate `error.UserThrown` return below is an error path, so an
    // errdefer would release the hash the stash just took ownership of. Build
    // the error inside a helper whose error returns all mean "the hash did not
    // reach the stash", and release only when that helper fails.
    const hash = try HashTable.create(ctx.allocator);
    stashPosixError(ctx, alloc, hash, e, name) catch |err| {
        container_backing.releaseValue(.{ .hash = hash });
        return err;
    };
    return error.UserThrown;
}

/// Populate the errno hash and stash the boxed `posix-error` on the context.
/// On success the stash owns the hash's construction reference.
fn stashPosixError(ctx: *Context, alloc: std.mem.Allocator, hash: *HashTable, e: c_int, name: []const u8) anyerror!void {
    const hash_alloc = hash.header.allocator;
    try hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "errno"), .{ .fixnum = @as(i64, e) });
    try hash.map.put(hash_alloc, try hash_alloc.dupe(u8, "name"), value_mod.symbolValue(name));

    const data_ptr = try alloc.create(Value);
    data_ptr.* = .{ .hash = hash };

    const message: []const u8 = if (strerror_fn) |strerror|
        try alloc.dupe(u8, std.mem.span(strerror(e)))
    else
        try alloc.dupe(u8, "posix error");

    ctx.thrown_error = try value_mod.boxErrorObject(alloc, .{
        .error_type = try alloc.dupe(u8, "posix-error"),
        .message = message,
        .data = data_ptr,
    });
}

/// lib-open ( path-or-name -- dylib ) - Opens a dynamic library and returns a resource handle to it.
///
/// The argument can be either an explicit path (e.g., "./libfoo.so" or "C:\foo.dll")
/// or just a library namec (e.g., "foo"). If a library name is given, the implementation
/// will attempt to resolve it to an actual library file using platform-specific conventions
/// (e.g., "foo" -> "libfoo.so" on Linux).
///
/// The returned resource must be closed when no longer needed to free associated resources.
///
/// If the library is registered as statically linked by the --link-static=<LIB> flag, it will
/// be opened with dlopen(NULL) instead, in order to access the main executable's symbol table.
/// In this case, the resource will have a type name of "dylib-static" and will not be closed
/// when the resource is closed, since it does not represent an actual dynamic library handle.
fn nativeLibOpen(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "lib-open");
    const alloc = ctx.arena.allocator();
    const name_str = try helpers.popString(ctx);
    defer container_backing.releaseValue(.{ .string = name_str });
    const name = name_str.bytes;

    const is_static = for (ctx.static_ffi_libs) |lib| {
        if (std.mem.eql(u8, lib, name)) break true;
    } else false;

    if (is_static) {
        const handle = std.c.dlopen(null, .{ .LAZY = true }) orelse {
            helpers.setErrorContext(ctx, "dlopen(NULL) failed for static lib: {s}", .{name});
            return error.FFILibraryNotFound;
        };
        const r = try alloc.create(Resource);
        r.* = .{
            .type_name = "dylib-static",
            .ptr = @ptrCast(handle),
            .closed = false,
            .close_fn = .none,
        };
        try ctx.stack.push(.{ .resource = r });
        return;
    }

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
        .close_fn = .{ .native = dylibCloseFn },
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
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "lib-symbol");
    const alloc = ctx.arena.allocator();
    const name_str = try helpers.popString(ctx);
    defer container_backing.releaseValue(.{ .string = name_str });
    const name = name_str.bytes;
    const lib_resource = try helpers.popResource(ctx);
    try error_mapping.ensureResourceOpen(lib_resource);

    const is_static = std.mem.eql(u8, lib_resource.type_name, "dylib-static");
    if (!is_static and !std.mem.eql(u8, lib_resource.type_name, "dylib")) {
        helpers.setTypeMismatchError(ctx, "dylib resource", .{ .resource = lib_resource });
        return error.TypeMismatch;
    }

    const name_z = try alloc.dupeZ(u8, name);

    const sym: *anyopaque = if (is_static) blk: {
        // Static handle: raw dlopen(NULL) pointer, use dlsym directly.
        const handle: *anyopaque = lib_resource.ptr.?;
        break :blk std.c.dlsym(handle, name_z) orelse {
            helpers.setErrorContext(ctx, "symbol not found: {s}", .{name});
            return error.FFISymbolNotFound;
        };
    } else blk: {
        // Dynamic handle: std.DynLib wrapper.
        const dynlib_ptr: *std.DynLib = @ptrCast(@alignCast(lib_resource.ptr.?));
        break :blk dynlib_ptr.lookup(*anyopaque, name_z) orelse {
            helpers.setErrorContext(ctx, "symbol not found: {s}", .{name});
            return error.FFISymbolNotFound;
        };
    };

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "ffi-fn",
        .ptr = sym,
        .closed = false,
        .close_fn = .none,
    };
    try ctx.stack.push(.{ .resource = r });
}

/// bind-sig ( ffi-fn ffi-sig -- ffi-fn ) - Associates a signature with an ffi-fn resource.
///
/// This function takes an "ffi-fn" resource and an "ffi-sig" struct instance, validates their types,
/// and extracts the parameter and return type information from the "ffi-sig". It then constructs
/// an internal FfiSignature representation and attaches it to the "ffi-fn" resource for
fn nativeBindSig(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "bind-sig");
    const alloc = ctx.arena.allocator();

    const sig_val = try ctx.stack.pop();
    // The signature struct carries the params array; everything read out of
    // it is parsed into the native FfiSignature before this release runs.
    defer container_backing.releaseValue(sig_val);
    const ffi_fn_val = try ctx.stack.pop();
    errdefer container_backing.releaseValue(ffi_fn_val);

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
        .array => |a| a.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array for params", params_val);
            return error.TypeMismatch;
        },
    };

    // Extract return type from field 1
    const return_type_val = si.fields[1];
    const return_type_str = switch (return_type_val) {
        .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "string for return-type", return_type_val);
            return error.TypeMismatch;
        },
    };

    // Parse param type tokens
    var param_list = std.ArrayListUnmanaged(FfiType){};
    var variadic_spec: ?VariadicSpec = null;

    for (params_array, 0..) |param_val, i| {
        const token = switch (param_val) {
            .string => |s| s.bytes,
            else => {
                helpers.setTypeMismatchError(ctx, "string for param type", param_val);
                return error.TypeMismatch;
            },
        };

        if (signature.parseVariadicToken(token)) |vspec| {
            if (variadic_spec != null) {
                helpers.setErrorContext(ctx, "duplicate variadic marker in FFI signature", .{});
                return error.FFITypeMismatch;
            }
            if (i != params_array.len - 1) {
                helpers.setErrorContext(ctx, "variadic marker must be the last parameter token", .{});
                return error.FFITypeMismatch;
            }
            if (param_list.items.len == 0) {
                helpers.setErrorContext(ctx, "variadic function must have at least one fixed parameter", .{});
                return error.FFITypeMismatch;
            }
            variadic_spec = vspec;
            continue;
        }

        const ffi_type = signature.parseTypeToken(token) catch {
            if (resolveStructType(ctx, token)) |struct_type| {
                try param_list.append(alloc, struct_type);
                continue;
            }
            helpers.setErrorContext(ctx, "unknown FFI type: {s}", .{token});
            return error.FFITypeMismatch;
        };
        if (ffi_type.tag == .void_type) {
            helpers.setErrorContext(ctx, "void is not valid as a parameter type", .{});
            return error.FFITypeMismatch;
        }
        if (ffi_type.tag == .struct_type and (ffi_type.is_out() or ffi_type.is_inout())) {
            helpers.setErrorContext(ctx, "out/inout parameters are not supported for struct types", .{});
            return error.FFITypeMismatch;
        }
        try param_list.append(alloc, ffi_type);
    }

    const param_types = try param_list.toOwnedSlice(alloc);

    // Parse return type token
    const return_type = signature.parseTypeToken(return_type_str) catch blk: {
        if (resolveStructType(ctx, return_type_str)) |struct_type| {
            break :blk struct_type;
        }
        helpers.setErrorContext(ctx, "unknown FFI type: {s}", .{return_type_str});
        return error.FFITypeMismatch;
    };
    if (return_type.is_out() or return_type.is_inout()) {
        helpers.setErrorContext(ctx, "out-parameter annotation is not valid for return type", .{});
        return error.FFITypeMismatch;
    }

    // Extract the opt-in errno sentinel (field 2) and the per-binding
    // capability (field 3) from the ffi-sig struct.
    const errno_sentinel = try parseErrnoSentinelField(ctx, si.fields[2]);
    const capability = try parseCapabilityField(ctx, si.fields[3]);

    // Store final signature
    const sig = try alloc.create(FfiSignature);
    sig.* = .{
        .param_types = param_types,
        .return_type = return_type,
        .n_fixed_params = if (variadic_spec != null) param_types.len else null,
        .variadic_type = if (variadic_spec) |vs| vs.typed else null,
        .errno_sentinel = errno_sentinel,
        .capability = capability,
    };

    ffi_fn.ffi_signature = sig;
    try ctx.stack.pushMoved(ffi_fn_val);
}

/// Parse the ffi-sig `errno` field into an ErrnoSentinel. `f` (boolean false)
/// means no errno convention. A symbol is matched against the closed set the
/// binding surface already validated at parse time; anything else is rejected.
fn parseErrnoSentinelField(ctx: *Context, val: Value) !ErrnoSentinel {
    switch (val) {
        .boolean => |b| {
            if (!b) return .none;
            helpers.setErrorContext(ctx, "ffi-sig errno field must be a sentinel symbol or f", .{});
            return error.FFITypeMismatch;
        },
        .symbol => |s| {
            if (std.mem.eql(u8, s.bytes, "neg1")) return .neg1;
            if (std.mem.eql(u8, s.bytes, "null")) return .null_ptr;
            if (std.mem.eql(u8, s.bytes, "neg")) return .neg;
            helpers.setErrorContext(ctx, "invalid FFI errno sentinel '{s}': expected neg1, null, or neg", .{s.bytes});
            return error.FFITypeMismatch;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or f for ffi-sig errno", val);
            return error.TypeMismatch;
        },
    }
}

/// Parse the ffi-sig `cap` field into a Capability. `f` (boolean false) means
/// the default `.ffi` gate. A symbol maps through the shared sandbox capability
/// vocabulary; an unknown capability name fails at bind time.
fn parseCapabilityField(ctx: *Context, val: Value) !Capability {
    switch (val) {
        .boolean => |b| {
            if (!b) return .ffi;
            helpers.setErrorContext(ctx, "ffi-sig cap field must be a capability symbol or f", .{});
            return error.FFITypeMismatch;
        },
        .symbol => |s| {
            if (std.mem.eql(u8, s.bytes, "none")) return .none;
            return SandboxSpec.fromString(s.bytes) orelse {
                helpers.setErrorContext(ctx, "unknown FFI capability '{s}'", .{s.bytes});
                return error.FFITypeMismatch;
            };
        },
        else => {
            helpers.setTypeMismatchError(ctx, "symbol or f for ffi-sig cap", val);
            return error.TypeMismatch;
        },
    }
}

/// Map an FfiTypeTag to the corresponding libffi type descriptor.
/// For struct types, use ffiTypeToLibffiExt instead.
pub fn ffiTypeToLibffi(tag: FfiTypeTag) [*c]c_ffi.ffi_type {
    return switch (tag) {
        .i8 => &c_ffi.ffi_type_sint8,
        .i16 => &c_ffi.ffi_type_sint16,
        .i32 => &c_ffi.ffi_type_sint32,
        .i64 => &c_ffi.ffi_type_sint64,
        .u8 => &c_ffi.ffi_type_uint8,
        .u16 => &c_ffi.ffi_type_uint16,
        .u32 => &c_ffi.ffi_type_uint32,
        .u64 => &c_ffi.ffi_type_uint64,
        .f32 => &c_ffi.ffi_type_float,
        .f64 => &c_ffi.ffi_type_double,
        .usize_type => if (@sizeOf(usize) == 8) &c_ffi.ffi_type_uint64 else &c_ffi.ffi_type_uint32,
        .isize_type => if (@sizeOf(isize) == 8) &c_ffi.ffi_type_sint64 else &c_ffi.ffi_type_sint32,
        .bool_type => &c_ffi.ffi_type_uint8,
        .cstring, .cstring_retained, .cstring_owned => &c_ffi.ffi_type_pointer,
        .ptr => &c_ffi.ffi_type_pointer,
        .void_type => &c_ffi.ffi_type_void,
        .struct_type => unreachable,
    };
}

/// Map an FfiType to the corresponding libffi type descriptor, supporting struct types.
fn ffiTypeToLibffiExt(ffi_type: FfiType) [*c]c_ffi.ffi_type {
    if (ffi_type.tag == .struct_type) {
        return ffi_type.struct_layout.?.ffi_type;
    }
    return ffiTypeToLibffi(ffi_type.tag);
}

/// Resolve a token as an FFI struct type by looking up its type descriptor.
fn resolveStructType(ctx: *const Context, token: []const u8) ?FfiType {
    const desc = ctx.lookupTypeDescriptor(token) orelse return null;
    const layout_raw: usize = switch (desc.kind) {
        .ffi_struct => |fs| fs.ffi_layout,
        else => return null,
    };
    if (layout_raw == 0) return null;
    const layout_ptr: *const FfiStructLayout = @ptrFromInt(layout_raw);
    return FfiType{
        .tag = .struct_type,
        .struct_layout = layout_ptr,
        // The signature outlives the sig struct's tokens, so the name references the type's
        // own long-lived VirtualType name rather than borrowing the token.
        .struct_name = if (layout_ptr.vtype) |vt| vt.name else null,
    };
}

/// Storage for a single marshaled FFI argument. Each variant holds a value
/// that can be referenced by pointer for the libffi avalue array.
const ArgSlot = extern union {
    i8_val: i8,
    i16_val: i16,
    i32_val: i32,
    i64_val: i64,
    u8_val: u8,
    u16_val: u16,
    u32_val: u32,
    u64_val: u64,
    f32_val: f32,
    f64_val: f64,
    usize_val: usize,
    isize_val: isize,
    bool_val: u8,
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
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "ffi-call");
    const alloc = ctx.arena.allocator();

    const ffi_fn_val = try ctx.stack.pop();
    defer container_backing.releaseValue(ffi_fn_val);
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

    // Per-binding sandbox gate: the binding's declared capability, not the
    // coarse `.ffi` native gate, decides whether this call is allowed.
    try checkBindingCapability(ctx, sig);

    if (sig.isVariadic()) {
        return nativeFfiCallVariadic(ctx, ffi_fn, sig);
    }

    const nargs = sig.param_types.len;

    // Count non-out params to know how many values to pop from the stack
    var n_stack_args: usize = 0;
    for (sig.param_types) |pt| {
        if (!pt.is_out()) n_stack_args += 1;
    }

    if (ctx.stack.depth() < n_stack_args) {
        helpers.setErrorContext(ctx, "ffi-call expected {d} arguments, got {d}", .{ n_stack_args, ctx.stack.depth() });
        return error.FFICallFailed;
    }

    // Pop only non-out arguments from the stack (rightmost = top-of-stack = last C param)
    var arg_vals = try alloc.alloc(Value, n_stack_args);
    var pop_i: usize = n_stack_args;
    while (pop_i > 0) {
        pop_i -= 1;
        arg_vals[pop_i] = try ctx.stack.pop();
    }
    // Marshaling dupes every escaping byte onto the arena, so the popped
    // argument references can drop once the call has completed.
    defer container_backing.releaseValues(arg_vals);

    var arg_types = try alloc.alloc([*c]c_ffi.ffi_type, nargs);
    var arg_slots = try alloc.alloc(ArgSlot, nargs);
    var arg_ptrs = try alloc.alloc(?*anyopaque, nargs);
    var out_ptr_slots = try alloc.alloc(?*anyopaque, nargs);

    var stack_arg_idx: usize = 0;
    for (sig.param_types, 0..) |param_type, pi| {
        if (param_type.is_out()) {
            arg_slots[pi] = std.mem.zeroes(ArgSlot);
            out_ptr_slots[pi] = @ptrCast(&arg_slots[pi]);
            arg_types[pi] = &c_ffi.ffi_type_pointer;
            arg_ptrs[pi] = @ptrCast(&out_ptr_slots[pi]);
        } else if (param_type.is_inout()) {
            arg_slots[pi] = try marshalArg(ctx, param_type, arg_vals[stack_arg_idx], stack_arg_idx);
            out_ptr_slots[pi] = @ptrCast(&arg_slots[pi]);
            arg_types[pi] = &c_ffi.ffi_type_pointer;
            arg_ptrs[pi] = @ptrCast(&out_ptr_slots[pi]);
            stack_arg_idx += 1;
        } else if (param_type.tag == .struct_type) {
            arg_types[pi] = ffiTypeToLibffiExt(param_type);
            const ba = try extractStructByteArray(ctx, param_type, arg_vals[stack_arg_idx], stack_arg_idx);
            arg_ptrs[pi] = @ptrCast(ba.slice().ptr);
            arg_slots[pi] = std.mem.zeroes(ArgSlot);
            out_ptr_slots[pi] = null;
            stack_arg_idx += 1;
        } else {
            arg_types[pi] = ffiTypeToLibffi(param_type.tag);
            arg_slots[pi] = try marshalArg(ctx, param_type, arg_vals[stack_arg_idx], stack_arg_idx);
            arg_ptrs[pi] = @ptrCast(&arg_slots[pi]);
            out_ptr_slots[pi] = null;
            stack_arg_idx += 1;
        }
    }

    var cif: c_ffi.ffi_cif = undefined;
    const prep_status = c_ffi.ffi_prep_cif(
        &cif,
        c_ffi.FFI_DEFAULT_ABI,
        @intCast(nargs),
        ffiTypeToLibffiExt(sig.return_type),
        if (nargs > 0) arg_types.ptr else null,
    );
    if (prep_status != c_ffi.FFI_OK) {
        helpers.setErrorContext(ctx, "ffi_prep_cif failed (status {d})", .{prep_status});
        return error.FFICallFailed;
    }

    // Call the foreign function
    var ret_storage: ReturnStorage = .{ .as_u64 = 0 };
    var ret_ba: ?*ByteArray = null;
    var ret_buf: *anyopaque = undefined;

    if (sig.return_type.tag == .struct_type) {
        const layout = sig.return_type.struct_layout.?;
        const ba = try ByteArray.create(alloc);
        try ba.ensureTotalCapacity(alloc, layout.total_size);
        ba.items.len = layout.total_size;
        @memset(ba.items[0..layout.total_size], 0);
        ret_ba = ba;
        ret_buf = @ptrCast(ba.slice().ptr);
    } else {
        ret_buf = @ptrCast(&ret_storage);
    }

    const fn_ptr: ?*const fn () callconv(.c) void = @ptrCast(@alignCast(ffi_fn.ptr.?));
    c_ffi.ffi_call(
        &cif,
        fn_ptr,
        ret_buf,
        if (nargs > 0) arg_ptrs.ptr else null,
    );

    // errno must be read before any other libc call can clobber the
    // thread-local. The sentinel test only reads ret_storage (pure integer
    // compares), so it runs before the fetch without touching errno.
    const posix_errno: ?c_int =
        if (sig.errno_sentinel != .none and sentinelMatches(sig.errno_sentinel, sig.return_type, &ret_storage))
            readErrno()
        else
            null;

    if (drainCallbackError(ctx)) |err| return err;

    if (posix_errno) |e| return raisePosixError(ctx, e);

    // Push out-param and inout-param values in parameter order (first deepest)
    for (sig.param_types, 0..) |param_type, pi| {
        if (param_type.is_out() or param_type.is_inout()) {
            try marshalOutParam(ctx, param_type, &arg_slots[pi]);
        }
    }

    // Return value goes on top
    try marshalReturn(ctx, sig.return_type, &ret_storage, ret_ba);
}

/// Infer an FFI type from a 1z value for untyped variadic arguments.
fn inferFfiType(val: Value) ?FfiType {
    return switch (val) {
        .fixnum => .{ .tag = .i64 },
        .float => .{ .tag = .f64 },
        .string => .{ .tag = .cstring },
        .boolean => .{ .tag = .i32 },
        .resource => .{ .tag = .ptr },
        else => null,
    };
}

/// Apply C default argument promotions for variadic arguments.
/// C requires that float promotes to double and integer types narrower than
/// int promote to int when passed through `...`.
fn promoteVariadicType(ffi_type: FfiType) FfiType {
    return switch (ffi_type.tag) {
        .i8, .i16 => .{ .tag = .i32 },
        .u8, .u16 => .{ .tag = .u32 },
        .f32 => .{ .tag = .f64 },
        .bool_type => .{ .tag = .i32 },
        else => ffi_type,
    };
}

/// Marshal a single variadic argument into an ArgSlot, applying type promotion.
fn marshalVariadicArg(ctx: *Context, promoted_type: FfiType, val: Value, vararg_index: usize) !ArgSlot {
    const alloc = ctx.arena.allocator();
    switch (promoted_type.tag) {
        inline .i32, .i64, .u32, .u64, .usize_type, .isize_type => |tag| {
            const T = ffiTagToZigType(tag);
            const fixnum = switch (val) {
                .fixnum => |v| v,
                .boolean => |b| @as(i64, if (b) 1 else 0),
                else => {
                    helpers.setErrorContext(ctx, "variadic argument {d}: expected fixnum, got {s}", .{ vararg_index + 1, helpers.valueTypeName(val) });
                    return error.FFITypeMismatch;
                },
            };
            const info = @typeInfo(T).int;
            if (info.signedness == .unsigned and info.bits >= 64) {
                try checkNonNegative(ctx, fixnum, ffiTypeDisplayName(tag), vararg_index);
            } else if (info.bits < 64) {
                try checkIntRange(ctx, fixnum, T, ffiTypeDisplayName(tag), vararg_index);
            }
            return marshalFixnumToSlot(tag, fixnum);
        },
        .f64 => {
            const float = switch (val) {
                .float => |v| v,
                else => {
                    helpers.setErrorContext(ctx, "variadic argument {d}: expected float, got {s}", .{ vararg_index + 1, helpers.valueTypeName(val) });
                    return error.FFITypeMismatch;
                },
            };
            return .{ .f64_val = float };
        },
        .cstring => {
            const str = switch (val) {
                .string => |s| s.bytes,
                else => {
                    helpers.setErrorContext(ctx, "variadic argument {d}: expected string, got {s}", .{ vararg_index + 1, helpers.valueTypeName(val) });
                    return error.FFITypeMismatch;
                },
            };
            const cstr = try alloc.dupeZ(u8, str);
            return .{ .ptr_val = @ptrCast(cstr.ptr) };
        },
        .ptr => {
            const resource = switch (val) {
                .resource => |r| r,
                else => {
                    helpers.setErrorContext(ctx, "variadic argument {d}: expected resource, got {s}", .{ vararg_index + 1, helpers.valueTypeName(val) });
                    return error.FFITypeMismatch;
                },
            };
            try error_mapping.ensureResourceOpen(resource);
            return .{ .ptr_val = resource.ptr };
        },
        else => {
            helpers.setErrorContext(ctx, "variadic argument {d}: unsupported type for variadic parameter", .{vararg_index + 1});
            return error.FFITypeMismatch;
        },
    }
}

/// Variadic FFI call path. Pops a sequence of variadic args from the stack,
/// marshals fixed and variadic args, and calls ffi_prep_cif_var + ffi_call.
fn nativeFfiCallVariadic(ctx: *Context, ffi_fn: *Resource, sig: *const FfiSignature) anyerror!void {
    const alloc = ctx.arena.allocator();
    const n_fixed = sig.n_fixed_params.?;

    // Pop the variadic args array from top of stack
    const varargs_val = try ctx.stack.pop();
    defer container_backing.releaseValue(varargs_val);
    const varargs = switch (varargs_val) {
        .array => |a| a.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array for variadic arguments", varargs_val);
            return error.TypeMismatch;
        },
    };

    const n_varargs = varargs.len;
    const n_total = n_fixed + n_varargs;

    if (n_total > 32) {
        helpers.setErrorContext(ctx, "ffi-call: too many arguments ({d} total, max 32)", .{n_total});
        return error.FFICallFailed;
    }

    // Count non-out fixed params to know how many values to pop
    var n_fixed_stack_args: usize = 0;
    for (sig.param_types[0..n_fixed]) |pt| {
        if (!pt.is_out()) n_fixed_stack_args += 1;
    }

    if (ctx.stack.depth() < n_fixed_stack_args) {
        helpers.setErrorContext(ctx, "ffi-call expected {d} fixed arguments, got {d}", .{ n_fixed_stack_args, ctx.stack.depth() });
        return error.FFICallFailed;
    }

    // Pop fixed args from stack (rightmost = top-of-stack = last C param)
    var fixed_vals = try alloc.alloc(Value, n_fixed_stack_args);
    var pop_i: usize = n_fixed_stack_args;
    while (pop_i > 0) {
        pop_i -= 1;
        fixed_vals[pop_i] = try ctx.stack.pop();
    }
    // Marshaling dupes every escaping byte onto the arena, so the popped
    // argument references can drop once the call has completed.
    defer container_backing.releaseValues(fixed_vals);

    // Allocate combined arrays for all args (fixed + variadic)
    var arg_types = try alloc.alloc([*c]c_ffi.ffi_type, n_total);
    var arg_slots = try alloc.alloc(ArgSlot, n_total);
    var arg_ptrs = try alloc.alloc(?*anyopaque, n_total);
    var out_ptr_slots = try alloc.alloc(?*anyopaque, n_total);

    // Marshal fixed params
    var stack_arg_idx: usize = 0;
    for (sig.param_types[0..n_fixed], 0..) |param_type, pi| {
        if (param_type.is_out()) {
            arg_slots[pi] = std.mem.zeroes(ArgSlot);
            out_ptr_slots[pi] = @ptrCast(&arg_slots[pi]);
            arg_types[pi] = &c_ffi.ffi_type_pointer;
            arg_ptrs[pi] = @ptrCast(&out_ptr_slots[pi]);
        } else if (param_type.is_inout()) {
            arg_slots[pi] = try marshalArg(ctx, param_type, fixed_vals[stack_arg_idx], stack_arg_idx);
            out_ptr_slots[pi] = @ptrCast(&arg_slots[pi]);
            arg_types[pi] = &c_ffi.ffi_type_pointer;
            arg_ptrs[pi] = @ptrCast(&out_ptr_slots[pi]);
            stack_arg_idx += 1;
        } else if (param_type.tag == .struct_type) {
            arg_types[pi] = ffiTypeToLibffiExt(param_type);
            const ba = try extractStructByteArray(ctx, param_type, fixed_vals[stack_arg_idx], stack_arg_idx);
            arg_ptrs[pi] = @ptrCast(ba.slice().ptr);
            arg_slots[pi] = std.mem.zeroes(ArgSlot);
            out_ptr_slots[pi] = null;
            stack_arg_idx += 1;
        } else {
            arg_types[pi] = ffiTypeToLibffi(param_type.tag);
            arg_slots[pi] = try marshalArg(ctx, param_type, fixed_vals[stack_arg_idx], stack_arg_idx);
            arg_ptrs[pi] = @ptrCast(&arg_slots[pi]);
            out_ptr_slots[pi] = null;
            stack_arg_idx += 1;
        }
    }

    // Marshal variadic args
    for (varargs, 0..) |vararg_val, vi| {
        const total_idx = n_fixed + vi;
        const vararg_type = if (sig.variadic_type) |vt|
            vt
        else
            inferFfiType(vararg_val) orelse {
                helpers.setErrorContext(ctx, "variadic argument {d}: cannot infer FFI type from {s}", .{ vi + 1, helpers.valueTypeName(vararg_val) });
                return error.FFITypeMismatch;
            };

        const promoted_type = promoteVariadicType(vararg_type);

        arg_types[total_idx] = ffiTypeToLibffi(promoted_type.tag);
        arg_slots[total_idx] = try marshalVariadicArg(ctx, promoted_type, vararg_val, vi);
        arg_ptrs[total_idx] = @ptrCast(&arg_slots[total_idx]);
        out_ptr_slots[total_idx] = null;
    }

    // Use ffi_prep_cif_var for variadic calls
    var cif: c_ffi.ffi_cif = undefined;
    const prep_status = c_ffi.ffi_prep_cif_var(
        &cif,
        c_ffi.FFI_DEFAULT_ABI,
        @intCast(n_fixed),
        @intCast(n_total),
        ffiTypeToLibffiExt(sig.return_type),
        if (n_total > 0) arg_types.ptr else null,
    );
    if (prep_status != c_ffi.FFI_OK) {
        helpers.setErrorContext(ctx, "ffi_prep_cif_var failed (status {d})", .{prep_status});
        return error.FFICallFailed;
    }

    // Call the foreign function
    var ret_storage: ReturnStorage = .{ .as_u64 = 0 };
    var ret_ba: ?*ByteArray = null;
    var ret_buf: *anyopaque = undefined;

    if (sig.return_type.tag == .struct_type) {
        const layout = sig.return_type.struct_layout.?;
        const ba = try ByteArray.create(alloc);
        try ba.ensureTotalCapacity(alloc, layout.total_size);
        ba.items.len = layout.total_size;
        @memset(ba.items[0..layout.total_size], 0);
        ret_ba = ba;
        ret_buf = @ptrCast(ba.slice().ptr);
    } else {
        ret_buf = @ptrCast(&ret_storage);
    }

    const fn_ptr: ?*const fn () callconv(.c) void = @ptrCast(@alignCast(ffi_fn.ptr.?));
    c_ffi.ffi_call(
        &cif,
        fn_ptr,
        ret_buf,
        if (n_total > 0) arg_ptrs.ptr else null,
    );

    // errno must be read before any other libc call can clobber the
    // thread-local (see nativeFfiCall).
    const posix_errno: ?c_int =
        if (sig.errno_sentinel != .none and sentinelMatches(sig.errno_sentinel, sig.return_type, &ret_storage))
            readErrno()
        else
            null;

    if (drainCallbackError(ctx)) |err| return err;

    if (posix_errno) |e| return raisePosixError(ctx, e);

    // Push out-param values for fixed params
    for (sig.param_types[0..n_fixed], 0..) |param_type, pi| {
        if (param_type.is_out() or param_type.is_inout()) {
            try marshalOutParam(ctx, param_type, &arg_slots[pi]);
        }
    }

    try marshalReturn(ctx, sig.return_type, &ret_storage, ret_ba);
}

const ReturnStorage = extern union {
    as_u64: u64,
    as_i64: i64,
    as_f32: f32,
    as_f64: f64,
    as_ptr: ?*anyopaque,
};

/// Validate a 1z stack value against an FFI param type and marshal it into an ArgSlot.
fn marshalArg(ctx: *Context, param_type: FfiType, val: Value, arg_index: usize) !ArgSlot {
    const alloc = ctx.arena.allocator();
    switch (param_type.tag) {
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize_type, .isize_type => |tag| {
            const T = ffiTagToZigType(tag);
            const fixnum = switch (val) {
                .fixnum => |v| v,
                else => return argTypeMismatch(ctx, "fixnum for " ++ comptime ffiTypeDisplayName(tag), val, arg_index),
            };
            const info = @typeInfo(T).int;
            if (info.signedness == .unsigned and info.bits >= 64) {
                try checkNonNegative(ctx, fixnum, ffiTypeDisplayName(tag), arg_index);
            } else if (info.bits < 64) {
                try checkIntRange(ctx, fixnum, T, ffiTypeDisplayName(tag), arg_index);
            }
            return marshalFixnumToSlot(tag, fixnum);
        },
        .f32 => {
            const float = switch (val) {
                .float => |v| v,
                else => return argTypeMismatch(ctx, "float for f32", val, arg_index),
            };
            return .{ .f32_val = @floatCast(float) };
        },
        .f64 => {
            const float = switch (val) {
                .float => |v| v,
                else => return argTypeMismatch(ctx, "float for f64", val, arg_index),
            };
            return .{ .f64_val = float };
        },
        .bool_type => {
            const b = switch (val) {
                .boolean => |v| v,
                else => return argTypeMismatch(ctx, "boolean for bool", val, arg_index),
            };
            return .{ .bool_val = if (b) 1 else 0 };
        },
        .cstring, .cstring_retained => {
            const str = switch (val) {
                .string => |s| s.bytes,
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
            if (std.mem.eql(u8, resource.type_name, "ffi-callback")) {
                const ud: *CallbackUserData = @ptrCast(@alignCast(resource.ptr.?));
                return .{ .ptr_val = ud.code_ptr };
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
        .struct_type => unreachable,
    }
}

/// Extract the byte array data from an FFI struct tagged value for passing to libffi.
fn extractStructByteArray(ctx: *Context, param_type: FfiType, val: Value, arg_index: usize) !*ByteArray {
    const inner = switch (val) {
        .tagged => |t| t.inner.*,
        else => {
            const sname = param_type.struct_name orelse "struct";
            helpers.setErrorContext(ctx, "argument {d}: expected FFI struct '{s}', got {s}", .{ arg_index + 1, sname, helpers.valueTypeName(val) });
            return error.FFITypeMismatch;
        },
    };
    return switch (inner) {
        .byte_array => |ba| ba,
        else => {
            const sname = param_type.struct_name orelse "struct";
            helpers.setErrorContext(ctx, "argument {d}: expected FFI struct '{s}', got {s}", .{ arg_index + 1, sname, helpers.valueTypeName(val) });
            return error.FFITypeMismatch;
        },
    };
}

fn argTypeMismatch(ctx: *Context, expected: []const u8, val: Value, arg_index: usize) error{FFITypeMismatch} {
    const type_name = helpers.valueTypeName(val);
    helpers.setErrorContext(ctx, "argument {d}: expected {s}, got {s}", .{ arg_index + 1, expected, type_name });
    return error.FFITypeMismatch;
}

fn checkIntRange(ctx: *Context, fixnum: i64, comptime T: type, type_name: []const u8, arg_index: usize) !void {
    if (fixnum < std.math.minInt(T) or fixnum > std.math.maxInt(T)) {
        helpers.setErrorContext(ctx, "argument {d}: value {d} out of range for {s} ({d}..{d})", .{
            arg_index + 1,                fixnum,                       type_name,
            @as(i64, std.math.minInt(T)), @as(i64, std.math.maxInt(T)),
        });
        return error.FFIRangeError;
    }
}

fn checkNonNegative(ctx: *Context, fixnum: i64, type_name: []const u8, arg_index: usize) !void {
    if (fixnum < 0) {
        helpers.setErrorContext(ctx, "argument {d}: value {d} out of range for {s} (must be non-negative)", .{
            arg_index + 1, fixnum, type_name,
        });
        return error.FFIRangeError;
    }
}

fn ffiTagToZigType(comptime tag: FfiTypeTag) type {
    return switch (tag) {
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .usize_type => usize,
        .isize_type => isize,
        else => @compileError("not an integer type"),
    };
}

fn argSlotFieldName(comptime tag: FfiTypeTag) []const u8 {
    return switch (tag) {
        .usize_type => "usize_val",
        .isize_type => "isize_val",
        else => @tagName(tag) ++ "_val",
    };
}

fn ffiTypeDisplayName(comptime tag: FfiTypeTag) []const u8 {
    return switch (tag) {
        .usize_type => "usize",
        .isize_type => "isize",
        else => @tagName(tag),
    };
}

fn pushCInt(ctx: *Context, comptime tag: FfiTypeTag, val: ffiTagToZigType(tag)) !void {
    const T = ffiTagToZigType(tag);
    const info = @typeInfo(T).int;
    if (comptime info.signedness == .unsigned and info.bits >= 64) {
        if (val > std.math.maxInt(i64)) {
            const big = try BigIntManaged.initSet(ctx.allocator, val);
            try helpers.pushDemotedBignum(ctx, big);
        } else {
            try ctx.stack.push(.{ .fixnum = @intCast(val) });
        }
    } else {
        try ctx.stack.push(.{ .fixnum = @intCast(val) });
    }
}

fn marshalFixnumToSlot(comptime tag: FfiTypeTag, fixnum: i64) ArgSlot {
    return switch (tag) {
        .i8 => .{ .i8_val = @intCast(fixnum) },
        .i16 => .{ .i16_val = @intCast(fixnum) },
        .i32 => .{ .i32_val = @intCast(fixnum) },
        .i64 => .{ .i64_val = fixnum },
        .u8 => .{ .u8_val = @intCast(fixnum) },
        .u16 => .{ .u16_val = @intCast(fixnum) },
        .u32 => .{ .u32_val = @intCast(fixnum) },
        .u64 => .{ .u64_val = @intCast(fixnum) },
        .usize_type => .{ .usize_val = @intCast(fixnum) },
        .isize_type => .{ .isize_val = @intCast(fixnum) },
        else => @compileError("not an integer type"),
    };
}

/// Marshal a C return value back to a 1z Value and push it onto the stack.
fn marshalReturn(ctx: *Context, return_type: FfiType, ret: *const ReturnStorage, ret_ba: ?*ByteArray) !void {
    const alloc = ctx.arena.allocator();
    switch (return_type.tag) {
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize_type, .isize_type => |tag| {
            const T = ffiTagToZigType(tag);
            const val: T = if (@typeInfo(T).int.signedness == .signed)
                @truncate(@as(i64, @bitCast(ret.as_i64)))
            else
                @truncate(ret.as_u64);
            try pushCInt(ctx, tag, val);
        },
        .f32 => {
            try ctx.stack.push(.{ .float = @floatCast(ret.as_f32) });
        },
        .f64 => {
            try ctx.stack.push(.{ .float = ret.as_f64 });
        },
        .bool_type => {
            const val: u8 = @truncate(ret.as_u64);
            try ctx.stack.push(.{ .boolean = val != 0 });
        },
        .cstring => {
            const cptr: [*c]const u8 = @ptrCast(ret.as_ptr);
            if (cptr == null) {
                try ctx.stack.push(value_mod.stringValue(""));
            } else {
                const span = std.mem.span(cptr);
                const str = try ctx.allocator.dupe(u8, span);
                try helpers.pushOwnedString(ctx, str);
            }
        },
        .cstring_owned => {
            const cptr: [*c]u8 = @ptrCast(ret.as_ptr);
            if (cptr == null) {
                try ctx.stack.push(value_mod.stringValue(""));
            } else {
                const span = std.mem.span(cptr);
                const str = try ctx.allocator.dupe(u8, span);
                std.c.free(cptr);
                try helpers.pushOwnedString(ctx, str);
            }
        },
        .cstring_retained => {
            const cptr: [*c]const u8 = @ptrCast(ret.as_ptr);
            if (cptr == null) {
                try ctx.stack.push(value_mod.stringValue(""));
            } else {
                const span = std.mem.span(cptr);
                const str = try ctx.allocator.dupe(u8, span);
                try helpers.pushOwnedString(ctx, str);
            }
        },
        .ptr => {
            const type_name = return_type.ptr_name orelse "ffi-ptr";
            const r = try alloc.create(Resource);
            r.* = .{
                .type_name = type_name,
                .ptr = ret.as_ptr,
                .closed = false,
                .close_fn = .none,
            };
            try ctx.stack.push(.{ .resource = r });
        },
        .void_type => {},
        .struct_type => {
            const layout = return_type.struct_layout orelse {
                helpers.setErrorContext(ctx, "struct return type has no layout", .{});
                return error.FFICallFailed;
            };
            const vtype = layout.vtype orelse {
                helpers.setErrorContext(ctx, "struct return type has no virtual type", .{});
                return error.FFICallFailed;
            };
            const ba = ret_ba orelse {
                helpers.setErrorContext(ctx, "struct return missing byte array buffer", .{});
                return error.FFICallFailed;
            };
            try helpers.pushOwnedTagged(ctx, vtype, .{ .byte_array = ba });
        },
    }
}

/// Read a value from an out-parameter ArgSlot and push it onto the stack.
fn marshalOutParam(ctx: *Context, param_type: FfiType, slot: *const ArgSlot) !void {
    const alloc = ctx.arena.allocator();
    switch (param_type.tag) {
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize_type, .isize_type => |tag| {
            const T = ffiTagToZigType(tag);
            const val: T = @field(slot.*, argSlotFieldName(tag));
            try pushCInt(ctx, tag, val);
        },
        .f32 => try ctx.stack.push(.{ .float = @floatCast(slot.f32_val) }),
        .f64 => try ctx.stack.push(.{ .float = slot.f64_val }),
        .bool_type => try ctx.stack.push(.{ .boolean = slot.bool_val != 0 }),
        .ptr => {
            const type_name = param_type.ptr_name orelse "ffi-ptr";
            const r = try alloc.create(Resource);
            r.* = .{
                .type_name = type_name,
                .ptr = slot.ptr_val,
                .closed = false,
                .close_fn = .none,
            };
            try ctx.stack.push(.{ .resource = r });
        },
        .cstring, .cstring_retained => {
            const cptr: [*c]const u8 = @ptrCast(slot.ptr_val);
            if (cptr == null) {
                try ctx.stack.push(value_mod.stringValue(""));
            } else {
                const span = std.mem.span(cptr);
                const str = try ctx.allocator.dupe(u8, span);
                try helpers.pushOwnedString(ctx, str);
            }
        },
        .cstring_owned => {
            const cptr: [*c]u8 = @ptrCast(slot.ptr_val);
            if (cptr == null) {
                try ctx.stack.push(value_mod.stringValue(""));
            } else {
                const span = std.mem.span(cptr);
                const str = try ctx.allocator.dupe(u8, span);
                std.c.free(cptr);
                try helpers.pushOwnedString(ctx, str);
            }
        },
        .void_type, .struct_type => unreachable,
    }
}

/// bytes-raw-ptr ( byte-array -- resource fixnum )
///
/// Extracts the raw buffer pointer and length from a byte array.
/// The resource wraps the internal buffer pointer; it becomes dangling
/// if the byte array is resized or freed.
fn nativeBytesRawPtr(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "bytes-raw-ptr");
    const alloc = ctx.arena.allocator();

    const ba = try helpers.popByteArray(ctx);
    // The returned resource borrows a raw pointer into the buffer; the caller
    // is responsible for keeping the byte array alive across any FFI use. We
    // release our popped reference, since this native consumes the operand.
    defer container_backing.releaseValue(.{ .byte_array = ba });

    const slice = ba.slice();
    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "ffi-bytes",
        .ptr = @ptrCast(slice.ptr),
        .closed = false,
        .close_fn = .none,
    };

    try ctx.stack.push(.{ .resource = r });
    try ctx.stack.push(.{ .fixnum = @intCast(slice.len) });
}

/// ffi-ptr+len>bytes ( resource n -- byte-array )
///
/// Copies n bytes from a raw pointer resource into a new byte-array.
/// The resource is not consumed or closed.
fn nativeFfiPtrLenToBytes(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "ffi-ptr+len>bytes");
    const n_val = try helpers.popFixnum(ctx);
    const resource_val = try ctx.stack.pop();
    defer container_backing.releaseValue(resource_val);

    const resource = switch (resource_val) {
        .resource => |r| r,
        else => {
            helpers.setTypeMismatchError(ctx, "resource", resource_val);
            return error.TypeMismatch;
        },
    };
    try error_mapping.ensureResourceOpen(resource);

    if (n_val < 0) {
        helpers.setErrorContext(ctx, "ffi-ptr+len>bytes size must be non-negative, got {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);

    const alloc = ctx.quotationAllocator();
    const ba = ByteArray.create(alloc) catch return error.OutOfMemory;

    if (n > 0) {
        const raw_ptr = resource.ptr orelse {
            helpers.setErrorContext(ctx, "ffi-ptr+len>bytes: resource pointer is null", .{});
            return error.FFICallFailed;
        };
        ba.ensureTotalCapacity(alloc, n) catch return error.OutOfMemory;
        ba.items.len = n;
        const src: [*]const u8 = @ptrCast(raw_ptr);
        @memcpy(ba.items[0..n], src[0..n]);
    }

    try ctx.stack.push(.{ .byte_array = ba });
}

/// ffi-ptr+len>borrowed-bytes ( resource n -- byte-array )
///
/// Wraps n bytes from a raw pointer resource as a borrowed byte-array.
/// No copy is performed; the returned byte-array is only valid while the
/// source pointer remains alive. The resource is not consumed or closed.
fn nativeFfiPtrLenToBorrowedBytes(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "ffi-ptr+len>borrowed-bytes");
    const n_val = try helpers.popFixnum(ctx);
    const resource_val = try ctx.stack.pop();
    defer container_backing.releaseValue(resource_val);

    const resource = switch (resource_val) {
        .resource => |r| r,
        else => {
            helpers.setTypeMismatchError(ctx, "resource", resource_val);
            return error.TypeMismatch;
        },
    };
    try error_mapping.ensureResourceOpen(resource);

    if (n_val < 0) {
        helpers.setErrorContext(ctx, "ffi-ptr+len>borrowed-bytes size must be non-negative, got {d}", .{n_val});
        return error.IndexOutOfBounds;
    }
    const n: usize = @intCast(n_val);

    var bytes: []u8 = &.{};
    if (n > 0) {
        const raw_ptr = resource.ptr orelse {
            helpers.setErrorContext(ctx, "ffi-ptr+len>borrowed-bytes: resource pointer is null", .{});
            return error.FFICallFailed;
        };
        const src: [*]u8 = @ptrCast(raw_ptr);
        bytes = src[0..n];
    }

    const ba = try value_mod.makeBorrowedByteArray(ctx.quotationAllocator(), bytes);
    try ctx.stack.push(.{ .byte_array = ba });
}

test "ffi-ptr+len>borrowed-bytes wraps source memory without copying" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var items = [_]u8{ 1, 2, 3, 4 };
    var resource = Resource{
        .type_name = "ffi-bytes",
        .ptr = @ptrCast(items[0..].ptr),
        .closed = false,
        .close_fn = .none,
    };

    try ctx.stack.push(.{ .resource = &resource });
    try ctx.stack.push(.{ .fixnum = items.len });
    try nativeFfiPtrLenToBorrowedBytes(&ctx);

    const result = try ctx.stack.pop();
    try std.testing.expect(result == .byte_array);
    try std.testing.expect(result.byte_array.isBorrowed());
    try std.testing.expectEqualSlices(u8, items[0..], result.byte_array.slice());

    items[1] = 99;
    try std.testing.expectEqual(@as(u8, 99), result.byte_array.slice()[1]);

    result.byte_array.slice()[2] = 77;
    try std.testing.expectEqual(@as(u8, 77), items[2]);
}

test "readErrno reflects errno after a deliberate libc failure" {
    if (is_freestanding) return;
    // close(-1) fails and sets errno = EBADF; read it back immediately.
    _ = std.c.close(-1);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(std.c.E.BADF)), readErrno());
}

test "sentinelMatches interprets return by type and sentinel" {
    const i32_ret = FfiType{ .tag = .i32 };
    const ptr_ret = FfiType{ .tag = .ptr };
    const u32_ret = FfiType{ .tag = .u32 };
    const f64_ret = FfiType{ .tag = .f64 };

    // Signed integer: -1 matches neg1 and neg but not null.
    var neg_one = ReturnStorage{ .as_i64 = -1 };
    try std.testing.expect(sentinelMatches(.neg1, i32_ret, &neg_one));
    try std.testing.expect(sentinelMatches(.neg, i32_ret, &neg_one));
    try std.testing.expect(!sentinelMatches(.null_ptr, i32_ret, &neg_one));
    try std.testing.expect(!sentinelMatches(.none, i32_ret, &neg_one));

    // Signed integer: 0 matches null only.
    var zero = ReturnStorage{ .as_i64 = 0 };
    try std.testing.expect(sentinelMatches(.null_ptr, i32_ret, &zero));
    try std.testing.expect(!sentinelMatches(.neg1, i32_ret, &zero));

    // Signed integer: a successful positive return matches nothing.
    var pos = ReturnStorage{ .as_i64 = 5 };
    try std.testing.expect(!sentinelMatches(.neg1, i32_ret, &pos));
    try std.testing.expect(!sentinelMatches(.neg, i32_ret, &pos));

    // Pointer: NULL matches null; MAP_FAILED (all-ones) matches neg1.
    var null_ptr = ReturnStorage{ .as_ptr = null };
    try std.testing.expect(sentinelMatches(.null_ptr, ptr_ret, &null_ptr));
    try std.testing.expect(!sentinelMatches(.neg1, ptr_ret, &null_ptr));
    var map_failed = ReturnStorage{ .as_u64 = std.math.maxInt(usize) };
    try std.testing.expect(sentinelMatches(.neg1, ptr_ret, &map_failed));
    try std.testing.expect(!sentinelMatches(.null_ptr, ptr_ret, &map_failed));

    // Unsigned: neg1/neg never match; null matches 0.
    var u_zero = ReturnStorage{ .as_u64 = 0 };
    try std.testing.expect(sentinelMatches(.null_ptr, u32_ret, &u_zero));
    var u_max = ReturnStorage{ .as_u64 = std.math.maxInt(u32) };
    try std.testing.expect(!sentinelMatches(.neg1, u32_ret, &u_max));

    // Float returns never signal errno failure.
    var f = ReturnStorage{ .as_f64 = -1.0 };
    try std.testing.expect(!sentinelMatches(.neg1, f64_ret, &f));
    try std.testing.expect(!sentinelMatches(.neg, f64_ret, &f));
}

test "errnoName normalizes known and unknown errnos" {
    const alloc = std.testing.allocator;

    const eacces = try errnoName(alloc, @intFromEnum(std.c.E.ACCES));
    defer alloc.free(eacces);
    try std.testing.expectEqualStrings("eacces", eacces);

    const ebadf = try errnoName(alloc, @intFromEnum(std.c.E.BADF));
    defer alloc.free(ebadf);
    try std.testing.expectEqualStrings("ebadf", ebadf);

    // An errno with no named tag falls back to e<decimal>.
    const unknown = try errnoName(alloc, 31337);
    defer alloc.free(unknown);
    try std.testing.expectEqualStrings("e31337", unknown);
}

const TestHookState = struct {
    fired: bool = false,
    arg0: ?*anyopaque = null,
    userdata: ?*anyopaque = null,
    message: [64]u8 = [_]u8{0} ** 64,
    message_len: usize = 0,
    courier_set_before_hook: bool = false,
    hook_raised_during_hook: bool = false,
    ctx: ?*Context = null,
};
var test_hook_state: TestHookState = .{};

fn testErrorHook(arg0: ?*anyopaque, userdata: ?*anyopaque, message: [*:0]const u8) callconv(.c) void {
    test_hook_state.fired = true;
    test_hook_state.arg0 = arg0;
    test_hook_state.userdata = userdata;
    const span = std.mem.span(message);
    const n = @min(span.len, test_hook_state.message.len);
    @memcpy(test_hook_state.message[0..n], span[0..n]);
    test_hook_state.message_len = n;
    if (test_hook_state.ctx) |c| {
        test_hook_state.courier_set_before_hook = c.callback_error != null;
        test_hook_state.hook_raised_during_hook = c.callback_error_hook_raised;
    }
}

fn testCallbackUserData(
    ctx: *Context,
    sig: *const FfiSignature,
    hook: ?ErrorHookFn,
    userdata: ?*anyopaque,
) CallbackUserData {
    return .{
        .ctx = ctx,
        .quotation = undefined,
        .sig = sig,
        .cif = undefined,
        .arg_types = undefined,
        .closure = undefined,
        .code_ptr = undefined,
        .error_hook = hook,
        .error_hook_userdata = userdata,
    };
}

test "callbackFail invokes the error hook with the courier already set" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var marker: u8 = 0;
    test_hook_state = .{ .ctx = &ctx };

    const sig = FfiSignature{ .param_types = &.{}, .return_type = .{ .tag = .i32 } };
    var ud = testCallbackUserData(&ctx, &sig, testErrorHook, @ptrCast(&marker));

    var ret_buf = [_]u8{0xFF} ** 8;
    const saved = ctx.saveErrorState();
    ctx.pending_error_message = "callback exploded";
    var no_args = [_]?*anyopaque{};
    callbackFail(&ud, &no_args, @ptrCast(&ret_buf), error.UserThrown, true, saved);

    try std.testing.expect(test_hook_state.fired);
    try std.testing.expect(test_hook_state.courier_set_before_hook);
    try std.testing.expect(test_hook_state.arg0 == null);
    try std.testing.expect(test_hook_state.userdata == @as(?*anyopaque, @ptrCast(&marker)));
    try std.testing.expectEqualStrings("callback exploded", test_hook_state.message[0..test_hook_state.message_len]);
    try std.testing.expect(ctx.callback_error != null);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &ret_buf);

    // The hook read the message before the detach lifted it onto the courier.
    try std.testing.expect(ctx.pending_error_message == null);
    try std.testing.expectEqualStrings("callback exploded", ctx.callback_error_state.?.message.?);

    ctx.callback_error = null;
    ctx.callback_error_context = null;
}

test "callbackFail passes the first ptr argument as arg0" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    test_hook_state = .{ .ctx = &ctx };

    var target: u32 = 0;
    const params = [_]FfiType{.{ .tag = .ptr }};
    const sig = FfiSignature{ .param_types = &params, .return_type = .{ .tag = .void_type } };
    var ud = testCallbackUserData(&ctx, &sig, testErrorHook, null);

    var arg0_slot: ?*anyopaque = @ptrCast(&target);
    var args = [_]?*anyopaque{@ptrCast(&arg0_slot)};
    callbackFail(&ud, &args, null, error.FFITypeMismatch, false, ctx.saveErrorState());

    try std.testing.expect(test_hook_state.fired);
    try std.testing.expect(test_hook_state.arg0 == @as(?*anyopaque, @ptrCast(&target)));
    try std.testing.expectEqualStrings("FFITypeMismatch", test_hook_state.message[0..test_hook_state.message_len]);
    ctx.callback_error = null;
}

test "callbackFail without a hook keeps the stash-only path" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    test_hook_state = .{};

    const sig = FfiSignature{ .param_types = &.{}, .return_type = .{ .tag = .i32 } };
    var ud = testCallbackUserData(&ctx, &sig, null, null);

    var ret_buf = [_]u8{0xFF} ** 8;
    var no_args = [_]?*anyopaque{};
    callbackFail(&ud, &no_args, @ptrCast(&ret_buf), error.StackUnderflow, false, ctx.saveErrorState());

    try std.testing.expect(!test_hook_state.fired);
    try std.testing.expect(ctx.callback_error != null);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &ret_buf);
    ctx.callback_error = null;
}

test "callbackErrorMessage prefers the thrown error's message" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var thrown = value_mod.ErrorObject{ .error_type = "test-error", .message = "thrown boom" };
    ctx.thrown_error = &thrown;
    const msg = callbackErrorMessage(&ctx, error.UserThrown, true);
    try std.testing.expectEqualStrings("thrown boom", std.mem.span(msg));
    ctx.thrown_error = null;

    const name_msg = callbackErrorMessage(&ctx, error.FFITypeMismatch, false);
    try std.testing.expectEqualStrings("FFITypeMismatch", std.mem.span(name_msg));
}

test "callbackFail sets the hook-raised flag only while the hook runs" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    test_hook_state = .{ .ctx = &ctx };

    const sig = FfiSignature{ .param_types = &.{}, .return_type = .{ .tag = .i32 } };
    var ud = testCallbackUserData(&ctx, &sig, testErrorHook, null);

    var no_args = [_]?*anyopaque{};
    callbackFail(&ud, &no_args, null, error.UserThrown, true, ctx.saveErrorState());

    // The returning hook saw the flag set; after it returned, the courier is
    // back on the auto-drained stash semantics.
    try std.testing.expect(test_hook_state.hook_raised_during_hook);
    try std.testing.expect(!ctx.callback_error_hook_raised);
    try std.testing.expect(ctx.callback_error != null);
    ctx.callback_error = null;
    ctx.callback_error_context = null;
}

test "take-callback-error pushes f when no callback error is pending" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    try nativeTakeCallbackError(&ctx);
    const val = try ctx.stack.pop();
    try std.testing.expect(val == .boolean);
    try std.testing.expect(!val.boolean);
}

test "take-callback-error delivers the boxed thrown error and clears the courier" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    // The courier's state travels detached, exactly as callbackFail leaves it.
    const saved = ctx.saveErrorState();
    const thrown = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = "test-error",
        .message = "boom",
        .data = null,
        .stack_trace = null,
    });
    ctx.thrown_error = thrown;
    ctx.callback_error = error.UserThrown;
    ctx.callback_error_context = "boom context";
    ctx.callback_error_hook_raised = true;
    ctx.detachErrorStateForCallback(saved);

    try nativeTakeCallbackError(&ctx);

    const val = try ctx.stack.pop();
    try std.testing.expect(val == .error_value);
    try std.testing.expectEqualStrings("test-error", val.error_value.error_type);
    try std.testing.expect(ctx.callback_error == null);
    try std.testing.expect(ctx.callback_error_context == null);
    try std.testing.expect(!ctx.callback_error_hook_raised);
    try std.testing.expect(ctx.thrown_error == null);
}

test "take-callback-error boxes a generic error for a non-throw failure" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    ctx.callback_error = error.StackUnderflow;
    try nativeTakeCallbackError(&ctx);

    const val = try ctx.stack.pop();
    try std.testing.expect(val == .error_value);
    try std.testing.expectEqualStrings("stack-underflow", val.error_value.error_type);
    try std.testing.expect(ctx.callback_error == null);
}

/// Call a foreign close function via libffi with the signature (ptr -> void).
pub fn ffiCloseCall(ffi_close: *const FfiCloseFn, ptr: *anyopaque) void {
    var arg_slot = ArgSlot{ .ptr_val = ptr };
    var arg_ptr: ?*anyopaque = @ptrCast(&arg_slot);
    var arg_type: [*c]c_ffi.ffi_type = &c_ffi.ffi_type_pointer;
    var cif: c_ffi.ffi_cif = undefined;
    _ = c_ffi.ffi_prep_cif(&cif, c_ffi.FFI_DEFAULT_ABI, 1, &c_ffi.ffi_type_void, @ptrCast(&arg_type));
    const fn_ptr: ?*const fn () callconv(.c) void = @ptrCast(@alignCast(ffi_close.fn_ptr));
    c_ffi.ffi_call(&cif, fn_ptr, null, @ptrCast(&arg_ptr));
}

/// bind-close ( resource ffi-fn -- ) - Bind an FFI close function to a resource.
fn nativeBindClose(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "bind-close");
    const alloc = ctx.arena.allocator();

    const ffi_fn_val = try ctx.stack.pop();
    defer container_backing.releaseValue(ffi_fn_val);
    const resource_val = try ctx.stack.pop();
    defer container_backing.releaseValue(resource_val);

    const resource = switch (resource_val) {
        .resource => |r| r,
        else => {
            helpers.setTypeMismatchError(ctx, "resource", resource_val);
            return error.TypeMismatch;
        },
    };
    try error_mapping.ensureResourceOpen(resource);

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
        helpers.setErrorContext(ctx, "ffi-fn has no bound signature (use bind-sig first)", .{});
        return error.FFICallFailed;
    };

    if (sig.isVariadic()) {
        helpers.setErrorContext(ctx, "bind-close does not support variadic signatures", .{});
        return error.FFITypeMismatch;
    }

    if (sig.param_types.len != 1 or sig.param_types[0].tag != .ptr) {
        helpers.setErrorContext(ctx, "bind-close requires signature with exactly one ptr parameter", .{});
        return error.FFITypeMismatch;
    }

    const ffi_close = try alloc.create(FfiCloseFn);
    ffi_close.* = .{ .fn_ptr = ffi_fn.ptr.? };
    resource.close_fn = .{ .ffi = ffi_close };
}

/// Error-hook ABI: (arg0, userdata, message). arg0 is the callback's first C argument when its
/// declared type is ptr, else null; message is a NUL-terminated copy of the 1z error message.
///
/// The hook runs from the trampoline's boundary frame after the Zig stack has unwound, so it may
/// perform a non-local exit such as lua_error's longjmp.
pub const ErrorHookFn = *const fn (?*anyopaque, ?*anyopaque, [*:0]const u8) callconv(.c) void;

const CallbackUserData = struct {
    ctx: *Context,
    quotation: Quotation,

    /// The closure behind `quotation`, for a body it owns. Borrowed: registration parked the
    /// owning reference on the dictionary's teardown list and kept only the view, so the pointer
    /// is what carries the body's captured scope and defining module into the trampoline.
    quotation_owner: ?*const value_mod.Closure = null,

    sig: *const FfiSignature,
    cif: c_ffi.ffi_cif,
    arg_types: [][*c]c_ffi.ffi_type,
    closure: *c_ffi.ffi_closure,
    code_ptr: *anyopaque,
    error_hook: ?ErrorHookFn,
    error_hook_userdata: ?*anyopaque,
};

/// The message handed to an error hook: the thrown 1z error's message when the quotation threw
/// one, else the pending error context, else the Zig error name.
///
/// The static fallback covers allocation failure, since the trampoline cannot propagate an error
/// to its C caller.
fn callbackErrorMessage(ctx: *Context, err: anyerror, quotation_throw: bool) [*:0]const u8 {
    const alloc = ctx.arena.allocator();
    if (quotation_throw) {
        if (err == error.UserThrown) {
            if (ctx.thrown_error) |thrown| {
                return alloc.dupeZ(u8, thrown.message) catch "callback error";
            }
        }
        if (ctx.pending_error_message) |msg| {
            return alloc.dupeZ(u8, msg) catch "callback error";
        }
    }
    return alloc.dupeZ(u8, @errorName(err)) catch "callback error";
}

/// Shared failure path for every trampoline catch site: stash the courier so the driver can
/// re-raise the original error, lift the callback's error state off the live channels, zero the
/// C return slot, then invoke the error hook when one is bound.
///
/// The courier is set before the hook because the hook may never return. The detach runs before
/// it for the same reason. The hook's message reads the channels the detach lifts, so it is
/// built ahead of both.
///
/// `saved` is the trampoline's entry snapshot. Everything above its marks is the callback
/// quotation's own, and it travels with the courier until a drain re-installs it.
fn callbackFail(
    ud: *CallbackUserData,
    args: [*c]?*anyopaque,
    ret: ?*anyopaque,
    err: anyerror,
    quotation_throw: bool,
    saved: Context.ErrorStateSnapshot,
) void {
    const ctx = ud.ctx;
    ctx.callback_error = err;
    ctx.callback_error_hook_raised = false;
    if (quotation_throw) ctx.callback_error_context = ctx.pending_error_message;

    const hook_message: ?[*:0]const u8 =
        if (ud.error_hook != null) callbackErrorMessage(ctx, err, quotation_throw) else null;

    ctx.detachErrorStateForCallback(saved);

    if (ret) |r| @memset(@as([*]u8, @ptrCast(r))[0..8], 0);

    if (ud.error_hook) |hook| {
        const arg0: ?*anyopaque = blk: {
            if (ud.sig.param_types.len == 0) break :blk null;
            if (ud.sig.param_types[0].tag != .ptr) break :blk null;
            const val: *const ?*anyopaque = @ptrCast(@alignCast(args[0].?));
            break :blk val.*;
        };
        // Set before the hook call so a hook that longjmps leaves it set; a
        // hook that returns falls back to the auto-drained stash semantics.
        ctx.callback_error_hook_raised = true;
        hook(arg0, ud.error_hook_userdata, hook_message.?);
        ctx.callback_error_hook_raised = false;
    }
}

/// Take a pending callback courier, re-installing the error state the callback produced so the
/// re-raised error renders the chain that reaches its raise site.
///
/// A hook-raised courier is exempt: the longjmp delivered the error into the C library's own
/// error protocol, so the binding reconciles it against the library's status via
/// take-callback-error.
pub fn drainCallbackError(ctx: *Context) ?anyerror {
    if (ctx.callback_error_hook_raised) return null;
    const err = ctx.callback_error orelse return null;

    ctx.callback_error = null;
    ctx.reattachCallbackErrorState();
    if (ctx.callback_error_context) |ectx| {
        helpers.setErrorContext(ctx, "{s}", .{ectx});
        ctx.callback_error_context = null;
    }
    return err;
}

/// take-callback-error ( -- error/f )
///
/// Drain a pending callback error without raising it: push the boxed original error, or f when no
/// callback error is pending. A courier a longjmp hook delivered into the C library is exempt from
/// the automatic ffi-call drains, so this is the only way it is delivered; the binding calls it
/// after the C library's protected call returns and reconciles against the library's own status.
fn nativeTakeCallbackError(ctx: *Context) anyerror!void {
    const err = ctx.callback_error orelse {
        try ctx.stack.push(.{ .boolean = false });
        return;
    };
    ctx.callback_error = null;
    ctx.callback_error_hook_raised = false;
    ctx.callback_error_context = null;

    // Marked before the reattach, so the box consumes the callback's re-installed state alone.
    // Whatever was already in flight here belongs to its own unwind and is given back.
    const saved_error_state = ctx.saveErrorState();
    ctx.reattachCallbackErrorState();
    try errors_mod.pushCaughtError(ctx, err, saved_error_state);
}

fn callbackTrampoline(
    _: [*c]c_ffi.ffi_cif,
    ret: ?*anyopaque,
    args: [*c]?*anyopaque,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const ud: *CallbackUserData = @ptrCast(@alignCast(user_data.?));
    const ctx = ud.ctx;

    // The C caller may be running under a 1z error that is still unwinding, so the callback's
    // own contribution is bounded from here.
    const saved_error_state = ctx.saveErrorState();

    for (ud.sig.param_types, 0..) |pt, i| {
        const arg_ptr = args[i].?;
        unmarshalArg(ctx, pt, arg_ptr) catch |err| {
            return callbackFail(ud, args, ret, err, false, saved_error_state);
        };
    }

    ctx.executeQuotationWithFrame(ud.quotation, ud.quotation_owner) catch |err| {
        return callbackFail(ud, args, ret, err, true, saved_error_state);
    };

    if (ud.sig.return_type.tag != .void_type) {
        const result_val = ctx.stack.pop() catch {
            return callbackFail(ud, args, ret, error.StackUnderflow, false, saved_error_state);
        };
        defer container_backing.releaseValue(result_val);
        marshalCallbackReturn(ret, ud.sig.return_type, result_val) catch |err| {
            return callbackFail(ud, args, ret, err, false, saved_error_state);
        };
    }
}

fn unmarshalArg(ctx: *Context, param_type: FfiType, arg_ptr: *anyopaque) !void {
    const alloc = ctx.arena.allocator();
    switch (param_type.tag) {
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize_type, .isize_type => |tag| {
            const T = ffiTagToZigType(tag);
            const val: *const T = @ptrCast(@alignCast(arg_ptr));
            try pushCInt(ctx, tag, val.*);
        },
        .f32 => {
            const val: *const f32 = @ptrCast(@alignCast(arg_ptr));
            try ctx.stack.push(.{ .float = @floatCast(val.*) });
        },
        .f64 => {
            const val: *const f64 = @ptrCast(@alignCast(arg_ptr));
            try ctx.stack.push(.{ .float = val.* });
        },
        .bool_type => {
            const val: *const u8 = @ptrCast(@alignCast(arg_ptr));
            try ctx.stack.push(.{ .boolean = val.* != 0 });
        },
        .cstring, .cstring_retained => {
            const val: *const [*c]const u8 = @ptrCast(@alignCast(arg_ptr));
            if (val.* == null) {
                try ctx.stack.push(value_mod.stringValue(""));
            } else {
                const span = std.mem.span(val.*);
                const str = try ctx.allocator.dupe(u8, span);
                try helpers.pushOwnedString(ctx, str);
            }
        },
        .ptr => {
            const val: *const ?*anyopaque = @ptrCast(@alignCast(arg_ptr));
            const type_name = param_type.ptr_name orelse "ffi-ptr";
            const r = try alloc.create(Resource);
            r.* = .{
                .type_name = type_name,
                .ptr = val.*,
                .closed = false,
                .close_fn = .none,
            };
            try ctx.stack.push(.{ .resource = r });
        },
        .cstring_owned, .void_type, .struct_type => unreachable,
    }
}

fn marshalCallbackReturn(ret: ?*anyopaque, return_type: FfiType, val: Value) !void {
    const r = ret orelse return;
    switch (return_type.tag) {
        inline .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .usize_type, .isize_type => |tag| {
            const fixnum = switch (val) {
                .fixnum => |v| v,
                else => return error.FFITypeMismatch,
            };
            const T = ffiTagToZigType(tag);
            const ptr: *T = @ptrCast(@alignCast(r));
            ptr.* = @intCast(fixnum);
        },
        .f32 => {
            const float = switch (val) {
                .float => |v| v,
                else => return error.FFITypeMismatch,
            };
            const ptr: *f32 = @ptrCast(@alignCast(r));
            ptr.* = @floatCast(float);
        },
        .f64 => {
            const float = switch (val) {
                .float => |v| v,
                else => return error.FFITypeMismatch,
            };
            const ptr: *f64 = @ptrCast(@alignCast(r));
            ptr.* = float;
        },
        .bool_type => {
            const b = switch (val) {
                .boolean => |v| v,
                else => return error.FFITypeMismatch,
            };
            const ptr: *u8 = @ptrCast(@alignCast(r));
            ptr.* = if (b) 1 else 0;
        },
        .cstring, .cstring_retained => {
            const str = switch (val) {
                .string => |s| s,
                else => return error.FFITypeMismatch,
            };
            _ = str;
            return error.FFITypeMismatch;
        },
        .ptr => {
            const resource = switch (val) {
                .resource => |res| res,
                else => return error.FFITypeMismatch,
            };
            const ptr: *?*anyopaque = @ptrCast(@alignCast(r));
            ptr.* = resource.ptr;
        },
        .cstring_owned, .void_type, .struct_type => {},
    }
}

fn callbackCloseFn(ptr: *anyopaque) void {
    const ud: *CallbackUserData = @ptrCast(@alignCast(ptr));
    c_ffi.ffi_closure_free(@ptrCast(ud.closure));
}

fn nativeFfiCallback(ctx: *Context) anyerror!void {
    if (is_freestanding) return helpers.throwBuildUnsupported(ctx, "ffi-callback");
    const alloc = ctx.arena.allocator();

    const userdata_val = try ctx.stack.pop();
    defer container_backing.releaseValue(userdata_val);
    const hook_val = try ctx.stack.pop();
    defer container_backing.releaseValue(hook_val);
    const sig_val = try ctx.stack.pop();
    // The signature struct carries the params array; everything read out of
    // it is parsed into the native FfiSignature before this release runs.
    defer container_backing.releaseValue(sig_val);
    const quot_val = try ctx.stack.pop();
    errdefer container_backing.releaseValue(quot_val);

    const quotation = (try helpers.asQuotationStamped(ctx, quot_val)) orelse {
        helpers.setTypeMismatchError(ctx, "quotation", quot_val);
        return error.TypeMismatch;
    };

    var error_hook: ?ErrorHookFn = null;
    switch (hook_val) {
        .boolean => |b| if (b) {
            helpers.setTypeMismatchError(ctx, "ffi-fn or f for error hook", hook_val);
            return error.TypeMismatch;
        },
        .resource => |res| {
            if (!std.mem.eql(u8, res.type_name, "ffi-fn") or res.closed or res.ptr == null) {
                helpers.setErrorContext(ctx, "error hook must be an open ffi-fn symbol", .{});
                return error.FFITypeMismatch;
            }
            error_hook = @ptrCast(@alignCast(res.ptr.?));
        },
        else => {
            helpers.setTypeMismatchError(ctx, "ffi-fn or f for error hook", hook_val);
            return error.TypeMismatch;
        },
    }

    var error_hook_userdata: ?*anyopaque = null;
    switch (userdata_val) {
        .boolean => |b| if (b) {
            helpers.setTypeMismatchError(ctx, "resource or f for error hook userdata", userdata_val);
            return error.TypeMismatch;
        },
        .resource => |res| {
            if (error_hook == null) {
                helpers.setErrorContext(ctx, "error hook userdata requires an error hook", .{});
                return error.FFITypeMismatch;
            }
            error_hook_userdata = res.ptr;
        },
        else => {
            helpers.setTypeMismatchError(ctx, "resource or f for error hook userdata", userdata_val);
            return error.TypeMismatch;
        },
    }

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

    const params_val = si.fields[0];
    const params_array = switch (params_val) {
        .array => |a| a.items,
        else => {
            helpers.setTypeMismatchError(ctx, "array for params", params_val);
            return error.TypeMismatch;
        },
    };

    const return_type_val = si.fields[1];
    const return_type_str = switch (return_type_val) {
        .string => |s| s.bytes,
        else => {
            helpers.setTypeMismatchError(ctx, "string for return-type", return_type_val);
            return error.TypeMismatch;
        },
    };

    // Check for variadic tokens before parsing
    for (params_array) |pv| {
        const tok = switch (pv) {
            .string => |s| s.bytes,
            else => continue,
        };
        if (signature.parseVariadicToken(tok) != null) {
            helpers.setErrorContext(ctx, "variadic signatures are not supported for callbacks", .{});
            return error.FFITypeMismatch;
        }
    }

    var param_types = try alloc.alloc(FfiType, params_array.len);
    for (params_array, 0..) |param_val, i| {
        const token = switch (param_val) {
            .string => |s| s.bytes,
            else => {
                helpers.setTypeMismatchError(ctx, "string for param type", param_val);
                return error.TypeMismatch;
            },
        };
        param_types[i] = signature.parseTypeToken(token) catch {
            if (resolveStructType(ctx, token)) |struct_type| {
                param_types[i] = struct_type;
            } else {
                helpers.setErrorContext(ctx, "unknown FFI type: {s}", .{token});
                return error.FFITypeMismatch;
            }
            helpers.setErrorContext(ctx, "struct types are not supported in callback signatures", .{});
            return error.FFITypeMismatch;
        };
        if (param_types[i].tag == .void_type) {
            helpers.setErrorContext(ctx, "void is not valid as a parameter type", .{});
            return error.FFITypeMismatch;
        }
        if (param_types[i].is_out() or param_types[i].is_inout()) {
            helpers.setErrorContext(ctx, "out-parameters are not valid in callback signatures", .{});
            return error.FFITypeMismatch;
        }
    }

    const return_type = signature.parseTypeToken(return_type_str) catch {
        if (resolveStructType(ctx, return_type_str)) |_| {
            helpers.setErrorContext(ctx, "struct types are not supported in callback return types", .{});
        } else {
            helpers.setErrorContext(ctx, "unknown FFI type: {s}", .{return_type_str});
        }
        return error.FFITypeMismatch;
    };

    const sig = try alloc.create(FfiSignature);
    sig.* = .{
        .param_types = param_types,
        .return_type = return_type,
    };

    var arg_types = try alloc.alloc([*c]c_ffi.ffi_type, param_types.len);
    for (param_types, 0..) |pt, i| {
        arg_types[i] = ffiTypeToLibffiExt(pt);
    }

    const ud = try alloc.create(CallbackUserData);
    ud.* = .{
        .ctx = ctx,
        .quotation = quotation,
        .quotation_owner = callable_mod.ownerClosureOf(quot_val),
        .sig = sig,
        .cif = undefined,
        .arg_types = arg_types,
        .closure = undefined,
        .code_ptr = undefined,
        .error_hook = error_hook,
        .error_hook_userdata = error_hook_userdata,
    };

    const prep_status = c_ffi.ffi_prep_cif(
        &ud.cif,
        c_ffi.FFI_DEFAULT_ABI,
        @intCast(param_types.len),
        ffiTypeToLibffiExt(return_type),
        if (param_types.len > 0) arg_types.ptr else null,
    );
    if (prep_status != c_ffi.FFI_OK) {
        helpers.setErrorContext(ctx, "ffi_prep_cif failed for callback (status {d})", .{prep_status});
        return error.FFICallFailed;
    }

    var code_ptr: *anyopaque = undefined;
    const closure_raw = c_ffi.ffi_closure_alloc(@sizeOf(c_ffi.ffi_closure), @ptrCast(&code_ptr));
    if (closure_raw == null) {
        helpers.setErrorContext(ctx, "ffi_closure_alloc failed", .{});
        return error.OutOfMemory;
    }
    const closure: *c_ffi.ffi_closure = @ptrCast(@alignCast(closure_raw.?));

    ud.closure = closure;
    ud.code_ptr = code_ptr;

    const closure_status = c_ffi.ffi_prep_closure_loc(
        closure,
        &ud.cif,
        callbackTrampoline,
        @ptrCast(ud),
        code_ptr,
    );
    if (closure_status != c_ffi.FFI_OK) {
        c_ffi.ffi_closure_free(@ptrCast(closure));
        helpers.setErrorContext(ctx, "ffi_prep_closure_loc failed (status {d})", .{closure_status});
        return error.FFICallFailed;
    }

    const r = try alloc.create(Resource);
    r.* = .{
        .type_name = "ffi-callback",
        .ptr = @ptrCast(ud),
        .closed = false,
        .close_fn = .{ .native = callbackCloseFn },
    };
    try ctx.stack.push(.{ .resource = r });
    // The body escapes into the C callback's user data for the context's lifetime.
    const callable: Callable = .{ .quot = quotation, .owner = quot_val };
    try callable.adoptForTeardown(ctx);
}
