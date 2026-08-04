const std = @import("std");
const context_mod = @import("../context.zig");
const Context = context_mod.Context;
const PragmaRegistration = context_mod.PragmaRegistration;
const value_mod = @import("../value.zig");
const Value = value_mod.Value;

const helpers = @import("helpers.zig");
const container_backing = @import("../container_backing.zig");
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
    .{ .name = "pragma-get-raw", .func = nativePragmaGetRaw, .stack_effect = "name -- value t | f" },
};

/// register-pragma ( name validator -- )
fn nativeRegisterPragma(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();
    // validator_val's quotation escapes into pragma_registry below; no release for it.
    const validator_val = try ctx.stack.pop();
    errdefer container_backing.releaseValue(validator_val);
    const name = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = name });

    const registration: PragmaRegistration = switch (validator_val) {
        .boolean => |b| blk: {
            if (b) {
                helpers.setErrorContext(ctx, "register-pragma: validator must be a quotation or f, got t", .{});
                return error.TypeMismatch;
            }
            break :blk .{ .validator = null };
        },
        .quotation, .closure => .{ .validator = (try helpers.asQuotationStamped(ctx, validator_val)).? },
        else => {
            helpers.setTypeMismatchError(ctx, "quotation or f", validator_val);
            return error.TypeMismatch;
        },
    };

    const duped_name = try alloc.dupe(u8, name.bytes);
    try ctx.pragma_registry.put(ctx.allocator, duped_name, registration);
    // The registry keeps only the quotation view; the transferred closure reference needs a
    // holder with a releaser.
    if (validator_val == .closure) {
        try ctx.dictionary.retainValueForTeardown(validator_val);
    }
}

/// pragma{ ( -- )
fn nativePragmaBlock(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    try ctx.stack.push(value_mod.stringValue("}"));
    try parse_time_mod.nativeParseUntil(ctx);
    const quot_val = try ctx.stack.pop();
    defer container_backing.releaseValue(quot_val);
    const quot = (try helpers.asQuotationStamped(ctx, quot_val)) orelse return error.TypeMismatch;

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
    // The popped ownership stays in `items`: escaping names are duped, the validator re-push
    // retains, and non-validator values are booleans, so one sweep releases every reference.
    defer container_backing.releaseValues(items);

    var j: usize = 0;
    while (j < count) : (j += 2) {
        const key = items[j];
        const value = items[j + 1];

        const pragma_name = switch (key) {
            .symbol => |s| try alloc.dupe(u8, s.bytes),
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

/// pragma-def{ ( -- )
fn nativePragmaDefBlock(ctx: *Context) anyerror!void {
    const alloc = ctx.quotationAllocator();

    try ctx.stack.push(value_mod.stringValue("}"));
    try parse_time_mod.nativeParseValuesUntil(ctx);
    const arr_val = try ctx.stack.pop();
    defer container_backing.releaseValue(arr_val);
    const items = switch (arr_val) {
        .array => |a| a.items,
        else => return error.TypeMismatch,
    };

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const item = items[i];

        switch (item) {
            .string => |name| {
                const duped_name = try alloc.dupe(u8, name.bytes);
                try ctx.pragma_registry.put(ctx.allocator, duped_name, .{ .validator = null });
            },
            .symbol => |name| {
                if (i + 1 >= items.len) {
                    const msg = std.fmt.allocPrint(alloc, "pragma-def: '{s}' requires a validator quotation", .{name.bytes}) catch "missing validator";
                    return throwPragmaError(ctx, alloc, "pragma-error", msg);
                }
                i += 1;
                const next = items[i];
                switch (next) {
                    .quotation, .closure => {
                        const q = (try helpers.asQuotationStamped(ctx, next)).?;
                        // The registry keeps only the view while the source array's reference is
                        // released above, so a closure validator needs its own reference.
                        if (next == .closure) {
                            container_backing.retainValue(next);
                            errdefer container_backing.releaseValue(next);
                            try ctx.dictionary.retainValueForTeardown(next);
                        }
                        const duped_name = try alloc.dupe(u8, name.bytes);
                        try ctx.pragma_registry.put(ctx.allocator, duped_name, .{ .validator = q });
                    },
                    else => {
                        const msg = std.fmt.allocPrint(alloc, "pragma-def: '{s}' validator must be a quotation", .{name.bytes}) catch "expected quotation";
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

/// pragma? ( name -- ? )
fn nativePragmaQuery(ctx: *Context) anyerror!void {
    const name = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = name });
    const value = ctx.getPragma(name.bytes);
    if (value) |v| {
        switch (v) {
            .boolean => |b| try ctx.stack.push(.{ .boolean = b }),
            else => try ctx.stack.push(.{ .boolean = true }),
        }
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}

/// pragma-get-raw ( name -- value t | f )
///
/// Raw lookup backing the prelude's pragma-get?/pragma-get wrappers.
fn nativePragmaGetRaw(ctx: *Context) anyerror!void {
    const name = try popString(ctx);
    defer container_backing.releaseValue(.{ .string = name });
    const value = ctx.getPragma(name.bytes);
    if (value) |v| {
        try ctx.stack.push(v);
        try ctx.stack.push(.{ .boolean = true });
    } else {
        try ctx.stack.push(.{ .boolean = false });
    }
}

/// The value to validate must already be on the stack before calling.
fn runValidator(ctx: *Context, alloc: std.mem.Allocator, reg: PragmaRegistration, pragma_name: []const u8) anyerror!void {
    if (reg.native_validator) |native_fn| {
        try native_fn(ctx);
    } else if (reg.validator) |validator| {
        try ctx.executeQuotation(validator);
    } else unreachable;

    const ok = try helpers.popBoolean(ctx);
    if (ok) {
        // The popped reference transfers into the pragma frame, which keeps it for the context.
        const validated = try ctx.stack.pop();
        errdefer container_backing.releaseValue(validated);
        try ctx.setPragma(pragma_name, validated);
    } else {
        const err_val = try ctx.stack.pop();
        defer container_backing.releaseValue(err_val);
        const err_msg = switch (err_val) {
            .string => |s| alloc.dupe(u8, s.bytes) catch "validation failed",
            else => "validation failed",
        };
        return throwPragmaError(ctx, alloc, "pragma-error", err_msg);
    }
}

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
