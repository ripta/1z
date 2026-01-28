const Context = @import("../context.zig").Context;
const Primitive = @import("types.zig").Primitive;

pub const primitives = [_]Primitive{
    .{ .name = "type-of", .stack_effect = "val -- symbol", .func = nativeTypeOf },
};

/// type-of ( val -- symbol ) - Return type of value as a symbol
fn nativeTypeOf(ctx: *Context) anyerror!void {
    const val = try ctx.stack.pop();
    const type_name: []const u8 = switch (val) {
        .integer => "integer",
        .boolean => "boolean",
        .string => "string",
        .symbol => "symbol",
        .array => "array",
        .quotation => "quotation",
        .hash => "hash",
        .vector => "vector",
        .byte_array => "byte-array",
        .set => "set",
        .mutable_map => "mutable-map",
        .stream => "stream",
        .parameter => "parameter",
        .module => "module",
        .marker => "marker",
        .struct_type => "struct-type",
        .struct_instance => |si| si.struct_type.name,
        .benchmark_report => "benchmark-report",
        .stack_effect => "stack-effect",
        .parse_time_marker => "parse-time",
        .error_value => "error",
    };
    try ctx.stack.push(.{ .symbol = type_name });
}
