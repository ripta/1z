const std = @import("std");

pub const FfiTypeTag = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    usize_type,
    isize_type,
    bool_type,
    cstring,
    cstring_retained,
    cstring_owned,
    ptr,
    void_type,
};

pub const FfiType = struct {
    tag: FfiTypeTag,
    ptr_name: ?[]const u8 = null,
};

pub const FfiSignature = struct {
    param_types: []const FfiType,
    return_type: FfiType,
};

pub const ParseError = error{
    UnknownFfiType,
};

pub fn parseTypeToken(token: []const u8) ParseError!FfiType {
    if (std.mem.eql(u8, token, "i8")) return .{ .tag = .i8 };
    if (std.mem.eql(u8, token, "i16")) return .{ .tag = .i16 };
    if (std.mem.eql(u8, token, "i32")) return .{ .tag = .i32 };
    if (std.mem.eql(u8, token, "i64")) return .{ .tag = .i64 };
    if (std.mem.eql(u8, token, "u8")) return .{ .tag = .u8 };
    if (std.mem.eql(u8, token, "u16")) return .{ .tag = .u16 };
    if (std.mem.eql(u8, token, "u32")) return .{ .tag = .u32 };
    if (std.mem.eql(u8, token, "u64")) return .{ .tag = .u64 };
    if (std.mem.eql(u8, token, "f32")) return .{ .tag = .f32 };
    if (std.mem.eql(u8, token, "f64")) return .{ .tag = .f64 };
    if (std.mem.eql(u8, token, "usize")) return .{ .tag = .usize_type };
    if (std.mem.eql(u8, token, "isize")) return .{ .tag = .isize_type };
    if (std.mem.eql(u8, token, "bool")) return .{ .tag = .bool_type };
    if (std.mem.eql(u8, token, "cstring")) return .{ .tag = .cstring };
    if (std.mem.eql(u8, token, "cstring-retained")) return .{ .tag = .cstring_retained };
    if (std.mem.eql(u8, token, "cstring-owned")) return .{ .tag = .cstring_owned };
    if (std.mem.eql(u8, token, "ptr")) return .{ .tag = .ptr };
    if (std.mem.eql(u8, token, "void")) return .{ .tag = .void_type };

    if (std.mem.startsWith(u8, token, "ptr:")) {
        const name = token["ptr:".len..];
        if (name.len == 0) return error.UnknownFfiType;
        return .{ .tag = .ptr, .ptr_name = name };
    }

    return error.UnknownFfiType;
}

test "parseTypeToken basic types" {
    try std.testing.expectEqual(FfiTypeTag.i8, (try parseTypeToken("i8")).tag);
    try std.testing.expectEqual(FfiTypeTag.i16, (try parseTypeToken("i16")).tag);
    try std.testing.expectEqual(FfiTypeTag.i32, (try parseTypeToken("i32")).tag);
    try std.testing.expectEqual(FfiTypeTag.i64, (try parseTypeToken("i64")).tag);
    try std.testing.expectEqual(FfiTypeTag.u8, (try parseTypeToken("u8")).tag);
    try std.testing.expectEqual(FfiTypeTag.u16, (try parseTypeToken("u16")).tag);
    try std.testing.expectEqual(FfiTypeTag.u32, (try parseTypeToken("u32")).tag);
    try std.testing.expectEqual(FfiTypeTag.u64, (try parseTypeToken("u64")).tag);
    try std.testing.expectEqual(FfiTypeTag.f32, (try parseTypeToken("f32")).tag);
    try std.testing.expectEqual(FfiTypeTag.f64, (try parseTypeToken("f64")).tag);
    try std.testing.expectEqual(FfiTypeTag.usize_type, (try parseTypeToken("usize")).tag);
    try std.testing.expectEqual(FfiTypeTag.isize_type, (try parseTypeToken("isize")).tag);
    try std.testing.expectEqual(FfiTypeTag.bool_type, (try parseTypeToken("bool")).tag);
    try std.testing.expectEqual(FfiTypeTag.cstring, (try parseTypeToken("cstring")).tag);
    try std.testing.expectEqual(FfiTypeTag.cstring_retained, (try parseTypeToken("cstring-retained")).tag);
    try std.testing.expectEqual(FfiTypeTag.cstring_owned, (try parseTypeToken("cstring-owned")).tag);
    try std.testing.expectEqual(FfiTypeTag.ptr, (try parseTypeToken("ptr")).tag);
    try std.testing.expectEqual(FfiTypeTag.void_type, (try parseTypeToken("void")).tag);
}

test "parseTypeToken ptr:name" {
    const result = try parseTypeToken("ptr:toy-counter");
    try std.testing.expectEqual(FfiTypeTag.ptr, result.tag);
    try std.testing.expectEqualStrings("toy-counter", result.ptr_name.?);
}

test "parseTypeToken ptr: empty name" {
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("ptr:"));
}

test "parseTypeToken unknown" {
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("banana"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("int"));
}
