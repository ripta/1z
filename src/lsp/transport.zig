const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const IoReader = std.Io.Reader;
const IoWriter = std.Io.Writer;
const Stringify = std.json.Stringify;

/// JSON-RPC 2.0 transport over stdin/stdout using LSP Content-Length framing.
pub const Transport = struct {
    allocator: Allocator,
    reader: *IoReader,
    writer: *IoWriter,

    pub fn init(allocator: Allocator, reader: *IoReader, writer: *IoWriter) Transport {
        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
        };
    }

    /// Read a single JSON-RPC message from the transport.
    /// Returns the raw JSON body. Caller owns the returned memory.
    pub fn readMessage(self: *Transport) ![]u8 {
        const content_length = try self.readHeaders();
        if (content_length == 0) return error.InvalidContentLength;

        const body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);

        self.reader.readSliceAll(body) catch return error.EndOfStream;
        return body;
    }

    /// Parse Content-Length from HTTP-style headers. Returns the value.
    fn readHeaders(self: *Transport) !usize {
        var content_length: usize = 0;

        while (true) {
            const line = self.reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.ReadFailed,
            };

            var trimmed = line;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }

            // end of headers
            if (trimmed.len == 0) break;

            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                const value_str = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                content_length = std.fmt.parseInt(usize, value_str, 10) catch return error.InvalidContentLength;
            }
        }

        return content_length;
    }

    /// Write a JSON-RPC response with Content-Length framing.
    pub fn writeMessage(self: *Transport, body: []const u8) !void {
        self.writer.print("Content-Length: {d}\r\n\r\n", .{body.len}) catch return error.WriteFailed;
        self.writer.writeAll(body) catch return error.WriteFailed;
        self.writer.flush() catch return error.WriteFailed;
    }

    /// Parse a raw JSON body into a Request.
    /// Caller must call `request.deinit()` when done.
    pub fn parseRequest(self: *Transport, body: []const u8) !types.Request {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return error.ParseError;
        errdefer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidRequest,
        };

        const method_val = obj.get("method") orelse return error.InvalidRequest;
        const method = switch (method_val) {
            .string => |s| s,
            else => return error.InvalidRequest,
        };

        var id: ?types.Id = null;
        if (obj.get("id")) |id_val| {
            switch (id_val) {
                .integer => |v| id = .{ .integer = v },
                .string => |v| id = .{ .string = v },
                else => {},
            }
        }

        const params = obj.get("params");

        return .{
            .id = id,
            .method = method,
            .params = params,
            .parsed = parsed,
        };
    }

    /// Write a successful JSON-RPC response.
    pub fn writeResponse(self: *Transport, id: types.Id, result: anytype) !void {
        const body = try self.serializeResponse(id, result);
        defer self.allocator.free(body);
        try self.writeMessage(body);
    }

    /// Write a JSON-RPC response with a null result.
    pub fn writeNullResponse(self: *Transport, id: types.Id) !void {
        const body = try self.serializeNullResponse(id);
        defer self.allocator.free(body);
        try self.writeMessage(body);
    }

    /// Write a JSON-RPC error response.
    pub fn writeError(self: *Transport, id: ?types.Id, code: types.ErrorCode, message: []const u8) !void {
        const body = try self.serializeError(id, code, message);
        defer self.allocator.free(body);
        try self.writeMessage(body);
    }

    /// Write a JSON-RPC notification (no id field).
    pub fn writeNotification(self: *Transport, method: []const u8, params: anytype) !void {
        const body = try self.serializeNotification(method, params);
        defer self.allocator.free(body);
        try self.writeMessage(body);
    }

    fn serializeNotification(self: *Transport, method: []const u8, params: anytype) ![]u8 {
        var out: IoWriter.Allocating = .init(self.allocator);
        errdefer out.deinit();

        var jw: Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write(method);
        try jw.objectField("params");
        try jw.write(params);
        try jw.endObject();

        return out.toOwnedSlice();
    }

    fn serializeResponse(self: *Transport, id: types.Id, result: anytype) ![]u8 {
        var out: IoWriter.Allocating = .init(self.allocator);
        errdefer out.deinit();

        var jw: Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try writeId(&jw, id);
        try jw.objectField("result");
        try jw.write(result);
        try jw.endObject();

        return out.toOwnedSlice();
    }

    fn serializeNullResponse(self: *Transport, id: types.Id) ![]u8 {
        var out: IoWriter.Allocating = .init(self.allocator);
        errdefer out.deinit();

        var jw: Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        try writeId(&jw, id);
        try jw.objectField("result");
        try jw.write(null);
        try jw.endObject();

        return out.toOwnedSlice();
    }

    fn serializeError(self: *Transport, id: ?types.Id, code: types.ErrorCode, message: []const u8) ![]u8 {
        var out: IoWriter.Allocating = .init(self.allocator);
        errdefer out.deinit();

        var jw: Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("id");
        if (id) |i| {
            try writeId(&jw, i);
        } else {
            try jw.write(null);
        }
        try jw.objectField("error");
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(@intFromEnum(code));
        try jw.objectField("message");
        try jw.write(message);
        try jw.endObject();
        try jw.endObject();

        return out.toOwnedSlice();
    }

    fn writeId(jw: *Stringify, id: types.Id) !void {
        switch (id) {
            .integer => |v| try jw.write(v),
            .string => |v| try jw.write(v),
        }
    }
};

// =========================================================================
// Tests
// =========================================================================

test "readMessage parses Content-Length framing" {
    const input = "Content-Length: 14\r\n\r\n{\"method\":\"x\"}";
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed(input);
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    const body = try transport.readMessage();
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualSlices(u8, "{\"method\":\"x\"}", body);
}

test "readMessage handles multiple headers" {
    const input = "Content-Length: 2\r\nContent-Type: application/json\r\n\r\nhi";
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed(input);
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    const body = try transport.readMessage();
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualSlices(u8, "hi", body);
}

test "parseRequest extracts method and integer id" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"initialize\",\"params\":{}}";
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed("");
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    var req = try transport.parseRequest(json);
    defer req.deinit();
    try std.testing.expectEqualSlices(u8, "initialize", req.method);
    try std.testing.expect(req.id != null);
    try std.testing.expectEqual(@as(i64, 42), req.id.?.integer);
}

test "parseRequest extracts string id" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"shutdown\"}";
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed("");
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    var req = try transport.parseRequest(json);
    defer req.deinit();
    try std.testing.expectEqualSlices(u8, "shutdown", req.method);
    try std.testing.expectEqualSlices(u8, "abc", req.id.?.string);
}

test "parseRequest handles notification (no id)" {
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed("");
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    var req = try transport.parseRequest(json);
    defer req.deinit();
    try std.testing.expectEqualSlices(u8, "initialized", req.method);
    try std.testing.expect(req.id == null);
}

test "writeMessage produces Content-Length framing" {
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed("");
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    try transport.writeMessage("hello");
    const written = writer.buffered();
    try std.testing.expectEqualSlices(u8, "Content-Length: 5\r\n\r\nhello", written);
}

test "writeResponse serializes JSON-RPC response" {
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed("");
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    try transport.writeResponse(.{ .integer = 1 }, null);
    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"result\":null") != null);
}

test "writeError serializes JSON-RPC error" {
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed("");
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    try transport.writeError(.{ .integer = 1 }, .method_not_found, "not found");
    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "not found") != null);
}
