const std = @import("std");
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const PragmaRegistration = context_mod.PragmaRegistration;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const Primitive = @import("types.zig").Primitive;
const RegistryEntry = @import("types.zig").RegistryEntry;
const parse_time_mod = @import("parse_time.zig");

const popString = helpers.popString;

pub const primitives = [_]Primitive{
    .{ .name = "register-pragma", .stack_effect = "name validator --", .doc = "Register a pragma key with an optional validator quotation. Pass f for boolean-only pragmas.", .func = nativeRegisterPragma },
    .{ .name = "pragma{", .parse_time = true, .stack_effect = "--", .doc = "Set pragma values for the current file scope.", .func = nativePragmaBlock },
    .{ .name = "pragma-def{", .parse_time = true, .stack_effect = "--", .doc = "Register multiple pragma keys. Bare names are boolean; name: [quot] registers a validated pragma.", .func = nativePragmaDefBlock },
    .{ .name = "pragma?", .stack_effect = "name -- ?", .doc = "Query whether the named pragma is set and truthy.", .func = nativePragmaQuery },
};

pub const registry_entries = [_]RegistryEntry{
    // ( name -- value t | f ) Raw pragma lookup for the prelude pragma-get?/pragma-get wrappers.
    .{ .name = "pragma-get-raw", .func = nativePragmaGetRaw, .stack_effect = "name -- value t | f" },
};

/// register-pragma ( name validator -- ) - Register a pragma key
fn nativeRegisterPragma(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    const validator_val = try ctx.stack.pop();
    const name = try popString(ctx);

    const registration: PragmaRegistration = switch (validator_val) {
        .boolean => |b| blk: {
            if (b) {
                helpers.setErrorContext(ctx, "register-pragma: validator must be a quotation or f, got t", .{});
                return error.TypeMismatch;
            }
            break :blk .{ .validator = null };
        },
        .quotation => |q| .{ .validator = q },
        else => {
            helpers.setTypeMismatchError(ctx, "quotation or f", validator_val);
            return error.TypeMismatch;
        },
    };

    const duped_name = try alloc.dupe(u8, name);
    try ctx.pragma_registry.put(ctx.allocator, duped_name, registration);
}

/// pragma{ ... } - Parse-time word for setting pragma values.
/// Uses parse-until to get a quotation, executes it, then processes
/// the resulting stack values as symbol-value pairs.
fn nativePragmaBlock(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    try ctx.stack.push(.{ .string = "}" });
    try parse_time_mod.nativeParseUntil(ctx);
    const quot_val = try ctx.stack.pop();
    const quot = switch (quot_val) {
        .quotation => |q| q,
        else => return error.TypeMismatch,
    };

    const depth_before = ctx.stack.depth();
    try ctx.executeQuotation(quot);
    const depth_after = ctx.stack.depth();

    if (depth_after < depth_before) {
        return throwPragmaError(ctx, alloc, "pragma-error", "pragma block consumed stack values");
    }

    const count = depth_after - depth_before;
    if (count % 2 != 0) {
        return throwPragmaError(ctx, alloc, "pragma-error", "pragma block must contain key: value pairs");
    }

    var items = try alloc.alloc(Value, count);
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        items[i] = try ctx.stack.pop();
    }

    var j: usize = 0;
    while (j < count) : (j += 2) {
        const key = items[j];
        const value = items[j + 1];

        const pragma_name = switch (key) {
            .symbol => |s| s,
            else => return throwPragmaError(ctx, alloc, "pragma-error", "pragma key must be a symbol (key: value)"),
        };

        const reg = ctx.lookupPragmaRegistration(pragma_name) orelse {
            return throwPragmaError(ctx, alloc, "unknown-pragma", pragma_name);
        };

        if (hasValidator(reg)) {
            try ctx.stack.push(value);
            try runValidator(ctx, alloc, reg, pragma_name);
            continue;
        }

        switch (value) {
            .boolean => try ctx.setPragma(pragma_name, value),
            else => {
                const msg = std.fmt.allocPrint(alloc, "pragma '{s}' accepts only boolean values", .{pragma_name}) catch "pragma accepts only boolean values";
                return throwPragmaError(ctx, alloc, "pragma-error", msg);
            },
        }
    }
}

/// pragma-def{ ... } - Parse-time batch registration of pragma keys.
/// Bare string names register boolean pragmas; symbol names followed by a
/// quotation register validated pragmas.
fn nativePragmaDefBlock(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    try ctx.stack.push(.{ .string = "}" });
    try parse_time_mod.nativeParseValuesUntil(ctx);
    const arr_val = try ctx.stack.pop();
    const items = switch (arr_val) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const item = items[i];

        switch (item) {
            .string => |name| {
                const duped_name = try alloc.dupe(u8, name);
                try ctx.pragma_registry.put(ctx.allocator, duped_name, .{ .validator = null });
            },
            .symbol => |name| {
                if (i + 1 >= items.len) {
                    const msg = std.fmt.allocPrint(alloc, "pragma-def: '{s}' requires a validator quotation", .{name}) catch "missing validator";
                    return throwPragmaError(ctx, alloc, "pragma-error", msg);
                }
                i += 1;
                const next = items[i];
                switch (next) {
                    .quotation => |q| {
                        const duped_name = try alloc.dupe(u8, name);
                        try ctx.pragma_registry.put(ctx.allocator, duped_name, .{ .validator = q });
                    },
                    else => {
                        const msg = std.fmt.allocPrint(alloc, "pragma-def: '{s}' validator must be a quotation", .{name}) catch "expected quotation";
                        return throwPragmaError(ctx, alloc, "pragma-error", msg);
                    },
                }
            },
            else => {
                return throwPragmaError(ctx, alloc, "pragma-error", "pragma-def: expected a name (string) or key: (symbol)");
            },
        }
    }
}

/// pragma? ( name -- ? ) - Query whether the named pragma is set and truthy.
fn nativePragmaQuery(ctx: *Context) anyerror!void {
    const name = try popString(ctx);
    const value = ctx.getPragma(name);
    if (value) |v| {
        switch (v) {
            .boolean => |b| try ctx.stack.push(.{ .boolean = b }),
            else => try ctx.stack.push(.{ .boolean = true }),
        }
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}

/// pragma-get-raw ( name -- value t | f ) - Raw pragma lookup for the prelude wrapper.
fn nativePragmaGetRaw(ctx: *Context) anyerror!void {
    const name = try popString(ctx);
    const value = ctx.getPragma(name);
    if (value) |v| {
        try ctx.stack.push(v);
        try ctx.stack.push(.{ .boolean = true });
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}

/// Run a quotation or native validator, then handle the result.
/// The value to validate must already be on the stack.
/// On success, sets the pragma. On failure, throws a pragma error.
fn runValidator(ctx: *Context, alloc: std.mem.Allocator, reg: PragmaRegistration, pragma_name: []const u8) anyerror!void {
    if (reg.native_validator) |native_fn| {
        try native_fn(ctx);
    } else if (reg.validator) |validator| {
        try ctx.executeQuotation(validator);
    } else unreachable;

    const ok = try helpers.popBoolean(ctx);
    if (ok) {
        const validated = try ctx.stack.pop();
        try ctx.setPragma(pragma_name, validated);
    } else {
        const err_val = try ctx.stack.pop();
        const err_msg = switch (err_val) {
            .string => |s| s,
            else => "validation failed",
        };
        return throwPragmaError(ctx, alloc, "pragma-error", err_msg);
    }
}

/// Return true if the registration has any validator (quotation or native).
fn hasValidator(reg: PragmaRegistration) bool {
    return reg.validator != null or reg.native_validator != null;
}

/// Set up a thrown error and return UserThrown for clean parse-time error display.
fn throwPragmaError(ctx: *Context, alloc: std.mem.Allocator, error_type: []const u8, message: []const u8) anyerror {
    _ = alloc;
    ctx.thrown_error = try value_mod.boxErrorObject(ctx.quotationAllocator(), .{
        .error_type = error_type,
        .message = message,
    });
    return error.UserThrown;
}
