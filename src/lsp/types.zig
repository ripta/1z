const std = @import("std");

/// JSON-RPC 2.0 request parsed from the transport layer.
/// Owns the parsed JSON memory; call `deinit()` when done.
pub const Request = struct {
    id: ?Id = null,
    method: []const u8,
    params: ?std.json.Value = null,
    parsed: std.json.Parsed(std.json.Value),

    pub fn isNotification(self: Request) bool {
        return self.id == null;
    }

    pub fn deinit(self: *Request) void {
        self.parsed.deinit();
    }
};

/// JSON-RPC 2.0 request/response identifier.
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn jsonStringify(self: *const Id, jw: anytype) !void {
        switch (self.*) {
            .integer => |v| try jw.write(v),
            .string => |v| try jw.write(v),
        }
    }
};

/// JSON-RPC 2.0 error codes.
pub const ErrorCode = enum(i64) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
    request_cancelled = -32800,
};

/// LSP InitializeParams (subset we care about).
pub const InitializeParams = struct {
    processId: ?i64 = null,
    rootUri: ?[]const u8 = null,
    capabilities: ?std.json.Value = null,
};

/// Server capabilities returned in the initialize response.
pub const ServerCapabilities = struct {};

/// InitializeResult returned to the client.
pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
    serverInfo: ServerInfo,
};

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};
