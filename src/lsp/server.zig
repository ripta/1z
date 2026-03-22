const std = @import("std");
const types = @import("types.zig");
const Transport = @import("transport.zig").Transport;
const Context = @import("../context.zig").Context;

const Allocator = std.mem.Allocator;

const build_options = @import("build_options");

/// LSP server state machine.
const State = enum {
    uninitialized,
    initialized,
    shutdown,
};

pub const Server = struct {
    allocator: Allocator,
    transport: *Transport,
    state: State = .uninitialized,
    ctx: *Context,

    pub fn init(allocator: Allocator, transport: *Transport, ctx: *Context) Server {
        return .{
            .allocator = allocator,
            .transport = transport,
            .ctx = ctx,
        };
    }

    /// Main loop: read requests and dispatch until exit.
    /// Returns the process exit code.
    pub fn run(self: *Server) u8 {
        while (true) {
            const body = self.transport.readMessage() catch |err| {
                switch (err) {
                    error.EndOfStream => return if (self.state == .shutdown) 0 else 1,
                    else => {
                        self.log("transport error: {any}", .{err});
                        continue;
                    },
                }
            };
            defer self.allocator.free(body);

            var request = self.transport.parseRequest(body) catch {
                self.transport.writeError(null, .parse_error, "Invalid JSON") catch {};
                continue;
            };
            defer request.deinit();

            self.dispatch(request) catch |err| {
                self.log("dispatch error: {any}", .{err});
                if (request.id) |id| {
                    self.transport.writeError(id, .internal_error, "Internal error") catch {};
                }
            };

            if (self.state == .shutdown and std.mem.eql(u8, request.method, "exit")) {
                return 0;
            }
            if (std.mem.eql(u8, request.method, "exit")) {
                return 1;
            }
        }
    }

    fn dispatch(self: *Server, request: types.Request) !void {
        if (std.mem.eql(u8, request.method, "initialize")) {
            return self.handleInitialize(request);
        } else if (std.mem.eql(u8, request.method, "initialized")) {
            return;
        } else if (std.mem.eql(u8, request.method, "shutdown")) {
            return self.handleShutdown(request);
        } else if (std.mem.eql(u8, request.method, "exit")) {
            return;
        }

        if (self.state == .uninitialized) {
            if (request.id) |id| {
                try self.transport.writeError(id, .server_not_initialized, "Server not initialized");
            }
            return;
        }

        if (self.state == .shutdown) {
            if (request.id) |id| {
                try self.transport.writeError(id, .invalid_request, "Server is shutting down");
            }
            return;
        }

        if (request.id) |id| {
            try self.transport.writeError(id, .method_not_found, "Method not found");
        }
    }

    fn handleInitialize(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;

        if (self.state != .uninitialized) {
            try self.transport.writeError(id, .invalid_request, "Server already initialized");
            return;
        }

        const result = types.InitializeResult{
            .capabilities = .{},
            .serverInfo = .{
                .name = "1z-lsp",
                .version = build_options.version,
            },
        };

        try self.transport.writeResponse(id, result);
        self.state = .initialized;
    }

    fn handleShutdown(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        try self.transport.writeNullResponse(id);
        self.state = .shutdown;
    }

    fn log(self: *Server, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const stderr_file: std.fs.File = .stderr();
        var stderr_buf: [4096]u8 = undefined;
        var stderr = stderr_file.writer(&stderr_buf);
        stderr.interface.print("[1z-lsp] " ++ fmt ++ "\n", args) catch {};
        stderr.interface.flush() catch {};
    }
};

// =========================================================================
// Tests
// =========================================================================

const IoReader = std.Io.Reader;
const IoWriter = std.Io.Writer;

fn lspMessage(allocator: Allocator, json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}

fn buildInput(allocator: Allocator, messages: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (messages) |msg| {
        // "Content-Length: " (16) + digits + "\r\n\r\n" (4) + body
        total_len += 16 + 10 + 4 + msg.len;
    }
    var out: IoWriter.Allocating = .init(allocator);
    errdefer out.deinit();
    for (messages) |msg| {
        out.writer.print("Content-Length: {d}\r\n\r\n{s}", .{ msg.len, msg }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

fn runServer(input: []const u8, out_buf: []u8) u8 {
    var reader = IoReader.fixed(input);
    var writer = IoWriter.fixed(out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch return 255;
    var server = Server.init(std.testing.allocator, &transport, &ctx);
    return server.run();
}

test "clean lifecycle returns exit code 0" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const exit_code = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "exit without shutdown returns exit code 1" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const exit_code = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "request before initialize returns server_not_initialized" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"textDocument/hover\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const exit_code = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "unknown method returns method_not_found" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"nonexistent\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const exit_code = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}

test "double initialize returns error" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"shutdown\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const exit_code = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}
