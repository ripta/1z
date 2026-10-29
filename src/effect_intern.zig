const std = @import("std");
const Allocator = std.mem.Allocator;

const value_mod = @import("value.zig");
const Marker = value_mod.Marker;
const stack_effect_mod = @import("stack_effect.zig");
const StackEffect = stack_effect_mod.StackEffect;
const StackEffectParam = stack_effect_mod.StackEffectParam;

/// Content-keyed tables for the metadata a definition records durably: its stack effect and its
/// marker list.
///
/// A definition made inside a word body is made again on every call. Without interning, each one
/// would add a fresh copy to the state target's arena, which frees only at teardown. With it,
/// definitions that agree on content share one copy, so the arena grows by program text and not by
/// call count.
///
/// An entry is its own key, so a match is a match on content. A marker or annotation address that
/// outlives the thing it named cannot make a lookup return a stale answer, because the entry holds
/// the same address the lookup is asking for.
///
/// The tables are guarded by the shared write lock of the context that owns them.
pub const Tables = struct {
    effects: std.HashMapUnmanaged(*const StackEffect, void, EffectKey, 80) = .{},
    marker_lists: std.HashMapUnmanaged([]const *Marker, void, MarkerListKey, 80) = .{},

    /// Free the maps. The interned contents live on the arena passed to `internEffect` and
    /// `internMarkers`, so they are not freed here.
    pub fn deinit(self: *Tables, allocator: Allocator) void {
        self.effects.deinit(allocator);
        self.marker_lists.deinit(allocator);
    }

    /// The one copy of `effect` that `arena` holds for its content.
    ///
    /// A miss copies the effect onto `arena`, parameter names included. The result is shared by
    /// every definition with an equal effect, and a definition's source text may be freed before
    /// the arena is, so the copy cannot borrow a name from it.
    ///
    /// The result is shared, so it must never be widened or otherwise written in place.
    pub fn internEffect(
        self: *Tables,
        allocator: Allocator,
        arena: Allocator,
        effect: StackEffect,
    ) Allocator.Error!*const StackEffect {
        if (self.effects.getKeyContext(&effect, .{})) |hit| return hit;

        const owned = try copyOwningNames(arena, effect);
        try self.effects.putContext(allocator, owned, {}, .{});
        return owned;
    }

    /// The one copy of `markers` that `arena` holds for its content, in order.
    ///
    /// An empty list shares the empty slice and allocates nothing.
    pub fn internMarkers(
        self: *Tables,
        allocator: Allocator,
        arena: Allocator,
        markers: []const *Marker,
    ) Allocator.Error![]const *Marker {
        if (markers.len == 0) return &.{};
        if (self.marker_lists.getKeyContext(markers, .{})) |hit| return hit;

        const owned = try arena.dupe(*Marker, markers);
        try self.marker_lists.putContext(allocator, owned, {}, .{});
        return owned;
    }
};

/// An annotation hashes as its tag and its address, never by what it points at, because
/// annotations compare by address.
const EffectKey = struct {
    pub fn hash(_: EffectKey, effect: *const StackEffect) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashEffect(&hasher, effect.*);
        return hasher.final();
    }

    pub fn eql(_: EffectKey, a: *const StackEffect, b: *const StackEffect) bool {
        return a.eql(b.*);
    }
};

const MarkerListKey = struct {
    pub fn hash(_: MarkerListKey, markers: []const *Marker) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(markers));
    }

    pub fn eql(_: MarkerListKey, a: []const *Marker, b: []const *Marker) bool {
        return std.mem.eql(*Marker, a, b);
    }
};

fn hashEffect(hasher: *std.hash.Wyhash, effect: StackEffect) void {
    hashParams(hasher, effect.inputs);
    hashParams(hasher, effect.outputs);
}

fn hashParams(hasher: *std.hash.Wyhash, params: []const StackEffectParam) void {
    std.hash.autoHash(hasher, params.len);

    for (params) |param| {
        std.hash.autoHash(hasher, param.name.len);
        hasher.update(param.name);
        std.hash.autoHash(hasher, param.is_row_variable);

        if (param.type_annotation) |annotation| {
            std.hash.autoHash(hasher, @as(u8, 1));
            std.hash.autoHash(hasher, std.meta.activeTag(annotation));
            switch (annotation) {
                inline else => |ptr| std.hash.autoHash(hasher, @intFromPtr(ptr)),
            }
        } else {
            std.hash.autoHash(hasher, @as(u8, 0));
        }

        if (param.quotation_effect) |nested| {
            std.hash.autoHash(hasher, @as(u8, 1));
            hashEffect(hasher, nested.*);
        } else {
            std.hash.autoHash(hasher, @as(u8, 0));
        }
    }
}

/// `stack_effect_mod.copyOnto`, plus a copy of every parameter name.
fn copyOwningNames(alloc: Allocator, effect: StackEffect) Allocator.Error!*const StackEffect {
    return stack_effect_mod.box(alloc, .{
        .inputs = try copyParamsOwningNames(alloc, effect.inputs),
        .outputs = try copyParamsOwningNames(alloc, effect.outputs),
    });
}

fn copyParamsOwningNames(alloc: Allocator, params: []const StackEffectParam) Allocator.Error![]const StackEffectParam {
    const copied = try alloc.alloc(StackEffectParam, params.len);

    for (params, copied) |src, *dst| {
        dst.* = src;
        dst.name = try alloc.dupe(u8, src.name);
        if (src.quotation_effect) |nested| dst.quotation_effect = try copyOwningNames(alloc, nested.*);
    }

    return copied;
}
