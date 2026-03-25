const std = @import("std");
const FfiStructLayout = @import("struct_layout.zig").FfiStructLayout;

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
    struct_type,
};

pub const ParamMode = enum {
    normal,
    out,
    inout,
};

pub const FfiType = struct {
    tag: FfiTypeTag,
    ptr_name: ?[]const u8 = null,
    mode: ParamMode = .normal,
    struct_layout: ?*const FfiStructLayout = null,
    struct_name: ?[]const u8 = null,

    pub fn is_out(self: FfiType) bool {
        return self.mode == .out;
    }

    pub fn is_inout(self: FfiType) bool {
        return self.mode == .inout;
    }
};

pub const FfiSignature = struct {
    param_types: []const FfiType,
    return_type: FfiType,
};

pub const ParseError = error{
    UnknownFfiType,
};

fn parseBaseType(token: []const u8) ParseError!FfiType {
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

pub fn parseTypeToken(token: []const u8) ParseError!FfiType {
    if (std.mem.startsWith(u8, token, "inout-")) {
        const base_token = token["inout-".len..];
        if (std.mem.startsWith(u8, base_token, "inout-")) return error.UnknownFfiType;
        if (std.mem.startsWith(u8, base_token, "out-")) return error.UnknownFfiType;

        var ffi_type = try parseBaseType(base_token);
        switch (ffi_type.tag) {
            .void_type, .cstring, .cstring_retained, .cstring_owned, .ptr => return error.UnknownFfiType,
            else => {},
        }

        ffi_type.mode = .inout;
        return ffi_type;
    }

    if (std.mem.startsWith(u8, token, "out-")) {
        const base_token = token["out-".len..];
        if (std.mem.startsWith(u8, base_token, "inout-")) return error.UnknownFfiType;
        if (std.mem.startsWith(u8, base_token, "out-")) return error.UnknownFfiType;

        var ffi_type = try parseBaseType(base_token);
        switch (ffi_type.tag) {
            .void_type => return error.UnknownFfiType,
            else => {},
        }

        ffi_type.mode = .out;
        return ffi_type;
    }

    return parseBaseType(token);
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

test "parseTypeToken out-param types" {
    const out_i32 = try parseTypeToken("out-i32");
    try std.testing.expectEqual(FfiTypeTag.i32, out_i32.tag);
    try std.testing.expect(out_i32.is_out());

    const out_i64 = try parseTypeToken("out-i64");
    try std.testing.expectEqual(FfiTypeTag.i64, out_i64.tag);
    try std.testing.expect(out_i64.is_out());

    const out_f64 = try parseTypeToken("out-f64");
    try std.testing.expectEqual(FfiTypeTag.f64, out_f64.tag);
    try std.testing.expect(out_f64.is_out());

    const out_bool = try parseTypeToken("out-bool");
    try std.testing.expectEqual(FfiTypeTag.bool_type, out_bool.tag);
    try std.testing.expect(out_bool.is_out());

    const out_u8 = try parseTypeToken("out-u8");
    try std.testing.expectEqual(FfiTypeTag.u8, out_u8.tag);
    try std.testing.expect(out_u8.is_out());

    const out_f32 = try parseTypeToken("out-f32");
    try std.testing.expectEqual(FfiTypeTag.f32, out_f32.tag);
    try std.testing.expect(out_f32.is_out());

    const out_usize = try parseTypeToken("out-usize");
    try std.testing.expectEqual(FfiTypeTag.usize_type, out_usize.tag);
    try std.testing.expect(out_usize.is_out());
}

test "parseTypeToken non-out params have is_out false" {
    const i32_type = try parseTypeToken("i32");
    try std.testing.expect(!i32_type.is_out());
}

test "parseTypeToken out-param rejected for invalid bases" {
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("out-void"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("out-out-i32"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("out-inout-i32"));
}

test "parseTypeToken out-cstring types" {
    const out_cstring = try parseTypeToken("out-cstring");
    try std.testing.expectEqual(FfiTypeTag.cstring, out_cstring.tag);
    try std.testing.expect(out_cstring.is_out());

    const out_cstring_retained = try parseTypeToken("out-cstring-retained");
    try std.testing.expectEqual(FfiTypeTag.cstring_retained, out_cstring_retained.tag);
    try std.testing.expect(out_cstring_retained.is_out());

    const out_cstring_owned = try parseTypeToken("out-cstring-owned");
    try std.testing.expectEqual(FfiTypeTag.cstring_owned, out_cstring_owned.tag);
    try std.testing.expect(out_cstring_owned.is_out());
}

test "parseTypeToken out-ptr" {
    const out_ptr = try parseTypeToken("out-ptr");
    try std.testing.expectEqual(FfiTypeTag.ptr, out_ptr.tag);
    try std.testing.expect(out_ptr.is_out());
    try std.testing.expect(out_ptr.ptr_name == null);
}

test "parseTypeToken out-ptr:name" {
    const out_ptr_named = try parseTypeToken("out-ptr:toy-counter");
    try std.testing.expectEqual(FfiTypeTag.ptr, out_ptr_named.tag);
    try std.testing.expect(out_ptr_named.is_out());
    try std.testing.expectEqualStrings("toy-counter", out_ptr_named.ptr_name.?);
}

test "parseTypeToken inout-param types" {
    const inout_i32 = try parseTypeToken("inout-i32");
    try std.testing.expectEqual(FfiTypeTag.i32, inout_i32.tag);
    try std.testing.expect(inout_i32.is_inout());
    try std.testing.expect(!inout_i32.is_out());

    const inout_i64 = try parseTypeToken("inout-i64");
    try std.testing.expectEqual(FfiTypeTag.i64, inout_i64.tag);
    try std.testing.expect(inout_i64.is_inout());

    const inout_f64 = try parseTypeToken("inout-f64");
    try std.testing.expectEqual(FfiTypeTag.f64, inout_f64.tag);
    try std.testing.expect(inout_f64.is_inout());

    const inout_u8 = try parseTypeToken("inout-u8");
    try std.testing.expectEqual(FfiTypeTag.u8, inout_u8.tag);
    try std.testing.expect(inout_u8.is_inout());

    const inout_f32 = try parseTypeToken("inout-f32");
    try std.testing.expectEqual(FfiTypeTag.f32, inout_f32.tag);
    try std.testing.expect(inout_f32.is_inout());

    const inout_bool = try parseTypeToken("inout-bool");
    try std.testing.expectEqual(FfiTypeTag.bool_type, inout_bool.tag);
    try std.testing.expect(inout_bool.is_inout());

    const inout_usize = try parseTypeToken("inout-usize");
    try std.testing.expectEqual(FfiTypeTag.usize_type, inout_usize.tag);
    try std.testing.expect(inout_usize.is_inout());
}

test "parseTypeToken inout-param rejected for invalid bases" {
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("inout-void"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("inout-cstring"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("inout-cstring-retained"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("inout-cstring-owned"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("inout-ptr"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("inout-inout-i32"));
    try std.testing.expectError(error.UnknownFfiType, parseTypeToken("inout-out-i32"));
}

test "parseTypeToken non-inout params have is_inout false" {
    const i32_type = try parseTypeToken("i32");
    try std.testing.expect(!i32_type.is_inout());

    const out_i32 = try parseTypeToken("out-i32");
    try std.testing.expect(!out_i32.is_inout());
}
