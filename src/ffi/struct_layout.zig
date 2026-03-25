const std = @import("std");
const c_ffi = @import("dynamic.zig").c_ffi;
const FfiTypeTag = @import("signature.zig").FfiTypeTag;
const VirtualType = @import("../value.zig").VirtualType;

pub const FfiStructField = struct {
    name: []const u8,
    type_token: []const u8,
    ffi_tag: ?FfiTypeTag,
    nested_layout: ?*const FfiStructLayout,
    offset: usize,
    size: usize,
};

pub const FfiStructLayout = struct {
    fields: []const FfiStructField,
    total_size: usize,
    alignment: usize,
    ffi_type: *c_ffi.ffi_type,
    elements: [*c][*c]c_ffi.ffi_type,
    vtype: ?*const VirtualType = null,
};

/// Map a scalar FFI type tag to its byte size.
pub fn ffiTagToSize(tag: FfiTypeTag) usize {
    return switch (tag) {
        .i8, .u8, .bool_type => 1,
        .i16, .u16 => 2,
        .i32, .u32, .f32 => 4,
        .i64, .u64, .f64, .usize_type, .isize_type => 8,
        .cstring, .cstring_retained, .cstring_owned, .ptr => @sizeOf(*anyopaque),
        .void_type => 0,
        .struct_type => unreachable,
    };
}
