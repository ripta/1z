//! Source-level regression tripwire for the consumer-native refcount pattern.
//!
//! A native that pops a `Value` off the operand stack owns that value: the slot
//! transferred its owning reference to the caller's local, which must then
//! release it (`container_backing.releaseValue`), move it back onto the stack
//! (`pushMoved` / `push`), or otherwise transfer ownership. Forgetting that step
//! leaks the backing's refcount.
//!
//! This module flags the recurring mistake -- a plain bound pop with no release
//! or re-store -- via a conservative lexical heuristic. It is a tripwire, not a
//! proof: the ground-truth leak check is the GPA ledger over the integration
//! suite. The heuristic has false negatives by design (a subtly-wrong release on
//! one branch passes) and a `// refcount-audit: allow <reason>` escape hatch for
//! the rare false positive.
//!
//! `scanSource` is pure (no file IO) so it can be unit-tested directly; the
//! tree sweep lives in `refcount_audit_main.zig`.

const std = @import("std");

/// A single flagged pop: a canonical `const`/`var <name> = try ctx.stack.pop();`
/// binding whose `<name>` is never released or re-stored in the same function.
pub const Violation = struct {
    /// Source file the violation was found in (caller-supplied label).
    file: []const u8,
    /// 1-based line number of the binding.
    line: usize,
    /// The bound variable name that is popped but never released.
    name: []const u8,
};

const SUPPRESS_MARKER = "// refcount-audit: allow";
const POP_NEEDLE = "= try ctx.stack.pop()";

/// Scan one Zig source file for consumer-native refcount violations.
///
/// `file` is an opaque label echoed back in each `Violation`. The returned
/// slice and the `name` fields it references are owned by the caller and freed
/// with `freeViolations`.
pub fn scanSource(allocator: std.mem.Allocator, file: []const u8, source: []const u8) ![]Violation {
    // A scrubbed copy with string/char/comment bytes blanked to spaces (newlines
    // preserved) lets brace matching and token search ignore literal contents.
    const scrubbed = try allocator.alloc(u8, source.len);
    defer allocator.free(scrubbed);
    scrub(source, scrubbed);

    var violations: std.ArrayListUnmanaged(Violation) = .{};
    errdefer freeViolations(allocator, violations.items);

    // Walk top-level scopes. Only function bodies (not `test` blocks) are
    // analyzed, and each binding's consuming reference is searched within the
    // same function body, since variable names like `val`/`key` recur across
    // functions.
    var depth: i32 = 0;
    var region_active = false;
    var region_had_open = false;
    var region_is_test = false;
    var region_start: usize = 0;

    var line_start: usize = 0;
    while (line_start <= scrubbed.len) {
        const nl = std.mem.indexOfScalarPos(u8, scrubbed, line_start, '\n') orelse scrubbed.len;
        const line = scrubbed[line_start..nl];

        if (!region_active and depth == 0) {
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (isFnHeader(trimmed)) {
                region_active = true;
                region_had_open = false;
                region_is_test = false;
                region_start = line_start;
            } else if (isTestHeader(trimmed)) {
                region_active = true;
                region_had_open = false;
                region_is_test = true;
                region_start = line_start;
            }
        }

        for (line) |ch| {
            if (ch == '{') {
                depth += 1;
                if (region_active) region_had_open = true;
            } else if (ch == '}') {
                depth -= 1;
            }
        }

        if (region_active and region_had_open and depth == 0) {
            if (!region_is_test) {
                try scanRegion(allocator, file, source, scrubbed, region_start, nl, &violations);
            }
            region_active = false;
        }

        if (nl == scrubbed.len) break;
        line_start = nl + 1;
    }

    return violations.toOwnedSlice(allocator);
}

/// Free a slice returned by `scanSource`, including each `name` allocation.
pub fn freeViolations(allocator: std.mem.Allocator, violations: []const Violation) void {
    for (violations) |v| allocator.free(v.name);
    allocator.free(violations);
}

fn isFnHeader(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "fn ") or
        std.mem.startsWith(u8, trimmed, "pub fn ") or
        std.mem.startsWith(u8, trimmed, "export fn ") or
        std.mem.startsWith(u8, trimmed, "pub export fn ") or
        std.mem.startsWith(u8, trimmed, "inline fn ") or
        std.mem.startsWith(u8, trimmed, "pub inline fn ");
}

fn isTestHeader(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "test ") or
        std.mem.startsWith(u8, trimmed, "test\"") or
        std.mem.startsWith(u8, trimmed, "test{");
}

/// Examine one function body for canonical pop bindings that are never consumed.
fn scanRegion(
    allocator: std.mem.Allocator,
    file: []const u8,
    source: []const u8,
    scrubbed: []const u8,
    start: usize,
    end: usize,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    const region = scrubbed[start..end];

    var search: usize = 0;
    while (std.mem.indexOfPos(u8, region, search, POP_NEEDLE)) |rel| {
        const pop_off = start + rel;
        search = rel + POP_NEEDLE.len;

        // Extract the binding name from the start of the line up to the needle.
        const line_begin = lineStart(scrubbed, pop_off);
        const prefix = std.mem.trim(u8, scrubbed[line_begin..pop_off], " \t");
        const name = bindingName(prefix) orelse continue;

        if (suppressed(source, pop_off)) continue;

        if (!consumed(region, name)) {
            const dup = try allocator.dupe(u8, name);
            errdefer allocator.free(dup);
            try violations.append(allocator, .{
                .file = file,
                .line = lineNumber(scrubbed, pop_off),
                .name = dup,
            });
        }
    }
}

/// Parse `const <name>` / `var <name>` out of the text preceding the pop needle.
/// Returns null for non-canonical shapes (`(try ...).field`, `arr[i] = ...`,
/// `switch (try ...)`, etc.) which are intentionally not analyzed.
fn bindingName(prefix: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, prefix, "const "))
        prefix["const ".len..]
    else if (std.mem.startsWith(u8, prefix, "var "))
        prefix["var ".len..]
    else
        return null;

    const name = std.mem.trim(u8, rest, " \t");
    if (name.len == 0) return null;
    for (name) |ch| {
        if (!isIdentChar(ch)) return null;
    }
    return name;
}

/// Whether `name`'s owning reference is released or re-stored anywhere in the
/// function body: `releaseValue(name)`, `pushMoved(name)`, or `push(name)`. The
/// trailing `)` anchors the identifier so `v` does not match `releaseValue(vec)`.
fn consumed(region: []const u8, name: []const u8) bool {
    var buf: [256]u8 = undefined;
    const forms = [_][]const u8{ "releaseValue(", "pushMoved(", "push(" };
    for (forms) |form| {
        const needle = std.fmt.bufPrint(&buf, "{s}{s})", .{ form, name }) catch continue;
        if (std.mem.indexOf(u8, region, needle) != null) return true;
    }
    return false;
}

/// True if the binding's line or the line immediately above carries the
/// suppression marker. Checked against raw source so the marker comment is not
/// scrubbed away.
fn suppressed(source: []const u8, off: usize) bool {
    const this_begin = lineStart(source, off);
    const this_end = std.mem.indexOfScalarPos(u8, source, this_begin, '\n') orelse source.len;
    if (std.mem.indexOf(u8, source[this_begin..this_end], SUPPRESS_MARKER) != null) return true;

    if (this_begin == 0) return false;
    const prev_end = this_begin - 1;
    const prev_begin = lineStart(source, prev_end);
    return std.mem.indexOf(u8, source[prev_begin..prev_end], SUPPRESS_MARKER) != null;
}

fn lineStart(text: []const u8, off: usize) usize {
    if (std.mem.lastIndexOfScalar(u8, text[0..off], '\n')) |nl| return nl + 1;
    return 0;
}

fn lineNumber(text: []const u8, off: usize) usize {
    return std.mem.count(u8, text[0..off], "\n") + 1;
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Blank string literals, char literals, and comments to spaces (preserving
/// length and newlines) so structural scanning ignores their contents.
fn scrub(source: []const u8, out: []u8) void {
    const State = enum { code, line_comment, block_comment, string, char };
    var state: State = .code;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        const blank = c != '\n';
        switch (state) {
            .code => {
                if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                    state = .line_comment;
                    out[i] = ' ';
                } else if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                    state = .block_comment;
                    out[i] = ' ';
                } else if (c == '"') {
                    state = .string;
                    out[i] = ' ';
                } else if (c == '\'') {
                    state = .char;
                    out[i] = ' ';
                } else {
                    out[i] = c;
                }
            },
            .line_comment => {
                if (c == '\n') {
                    state = .code;
                    out[i] = c;
                } else {
                    out[i] = ' ';
                }
            },
            .block_comment => {
                out[i] = if (blank) ' ' else c;
                if (c == '/' and i > 0 and source[i - 1] == '*') state = .code;
            },
            .string => {
                out[i] = if (blank) ' ' else c;
                if (c == '\\' and i + 1 < source.len) {
                    // Skip the escaped byte so an escaped quote does not end the
                    // string early.
                    i += 1;
                    if (i < source.len) out[i] = if (source[i] != '\n') ' ' else source[i];
                } else if (c == '"') {
                    state = .code;
                }
            },
            .char => {
                out[i] = if (blank) ' ' else c;
                if (c == '\\' and i + 1 < source.len) {
                    i += 1;
                    if (i < source.len) out[i] = if (source[i] != '\n') ' ' else source[i];
                } else if (c == '\'') {
                    state = .code;
                }
            },
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn expectNames(allocator: std.mem.Allocator, source: []const u8, expected: []const []const u8) !void {
    const got = try scanSource(allocator, "fixture.zig", source);
    defer freeViolations(allocator, got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, 0..) |want, idx| {
        try testing.expectEqualStrings(want, got[idx].name);
    }
}

test "flags a bound pop with no release" {
    const src =
        \\fn nativeLeak(ctx: *Context) anyerror!void {
        \\    const val = try ctx.stack.pop();
        \\    _ = val;
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{"val"});
}

test "passes a pop released via defer" {
    const src =
        \\fn nativeOk(ctx: *Context) anyerror!void {
        \\    const val = try ctx.stack.pop();
        \\    defer container_backing.releaseValue(val);
        \\    try ctx.stack.push(.{ .fixnum = 1 });
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{});
}

test "passes a pop moved back onto the stack" {
    const src =
        \\fn nativeDip(ctx: *Context) anyerror!void {
        \\    const x = try ctx.stack.pop();
        \\    errdefer container_backing.releaseValue(x);
        \\    try ctx.stack.pushMoved(x);
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{});
}

test "passes a pop re-stored via push" {
    const src =
        \\fn nativeRestore(ctx: *Context) anyerror!void {
        \\    const v = try ctx.stack.pop();
        \\    try ctx.stack.push(v);
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{});
}

test "respects the suppression marker on the binding line" {
    const src =
        \\fn nativeMoves(ctx: *Context) anyerror!void {
        \\    const v = try ctx.stack.pop(); // refcount-audit: allow (moved into channel)
        \\    sendToChannel(v);
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{});
}

test "respects the suppression marker on the line above" {
    const src =
        \\fn nativeMoves(ctx: *Context) anyerror!void {
        \\    // refcount-audit: allow (ownership transferred to dictionary)
        \\    const v = try ctx.stack.pop();
        \\    storeInDict(v);
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{});
}

test "ignores pops inside test blocks" {
    const src =
        \\test "some unit test" {
        \\    const val = try ctx.stack.pop();
        \\    _ = val;
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{});
}

test "ignores non-canonical pop shapes" {
    const src =
        \\fn nativeShapes(ctx: *Context) anyerror!void {
        \\    const h = (try ctx.stack.pop()).hash;
        \\    arr[i] = try ctx.stack.pop();
        \\    switch (try ctx.stack.pop()) {
        \\        else => {},
        \\    }
        \\    _ = h;
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{});
}

test "scopes the consuming reference to the same function" {
    // The release of `val` lives in a different function, so the leak in
    // nativeLeak must still be flagged.
    const src =
        \\fn nativeLeak(ctx: *Context) anyerror!void {
        \\    const val = try ctx.stack.pop();
        \\    _ = val;
        \\}
        \\
        \\fn nativeOther(ctx: *Context) anyerror!void {
        \\    const val = try ctx.stack.pop();
        \\    container_backing.releaseValue(val);
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{"val"});
}

test "the trailing paren anchors the identifier" {
    // `releaseValue(vector)` must not satisfy a binding named `v`.
    const src =
        \\fn nativeAnchor(ctx: *Context) anyerror!void {
        \\    const v = try ctx.stack.pop();
        \\    container_backing.releaseValue(vector);
        \\    _ = v;
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{"v"});
}

test "braces inside string and char literals do not break scoping" {
    const src =
        \\fn nativeStrings(ctx: *Context) anyerror!void {
        \\    const val = try ctx.stack.pop();
        \\    std.debug.print("a brace { and a } here", .{});
        \\    const brace: u8 = '}';
        \\    _ = brace;
        \\    _ = val;
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{"val"});
}

test "handles a multi-line function header" {
    const src =
        \\fn nativeWide(
        \\    ctx: *Context,
        \\) anyerror!void {
        \\    const val = try ctx.stack.pop();
        \\    _ = val;
        \\}
        \\
    ;
    try expectNames(testing.allocator, src, &.{"val"});
}
