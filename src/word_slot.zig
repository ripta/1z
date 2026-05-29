const std = @import("std");

/// Forward-declared opaque type for `WordDefinition`. The concrete struct
/// lives in `dictionary.zig`; module callers reach it via that file's typed
/// accessors. Decoupling the slot from the definition lets `value.zig`
/// reference `*WordSlot` in `Instruction.Op` without pulling the dictionary
/// type graph -- and the transitive `Context` dependency -- into Value's
/// resolution path.
pub const WordDefinition = opaque {};

/// Stable, heap-boxed cell carrying a pointer to the current `WordDefinition`
/// for a given name. The slot's address is invariant across hash-map rehash
/// and across redefinition; the pointer it holds is what moves when a word is
/// redefined. Callers that pre-resolve a word reference at parse time take
/// the slot's address and follow the indirection to the current definition
/// at execution time, so redefinition stays visible without re-resolving
/// names.
pub const WordSlot = struct {
    name: []const u8,
    definition: std.atomic.Value(*WordDefinition),

    pub fn load(self: *const WordSlot) *WordDefinition {
        return self.definition.load(.acquire);
    }

    pub fn store(self: *WordSlot, def: *WordDefinition) void {
        self.definition.store(def, .release);
    }
};
