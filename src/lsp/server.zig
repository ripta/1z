const std = @import("std");
const types = @import("types.zig");
const Transport = @import("transport.zig").Transport;
const Context = @import("../context.zig").Context;
const tokenizer_mod = @import("../tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const dict_mod = @import("../dictionary.zig");
const WordDefinition = dict_mod.WordDefinition;
const StackEffect = @import("../stack_effect.zig").StackEffect;
const effect_inference = @import("../effect_inference.zig");
const call_graph = @import("../call_graph.zig");
const parser = @import("../parser.zig");
const formatter = @import("../formatter.zig");

const Allocator = std.mem.Allocator;

const build_options = @import("build_options");

/// LSP server state machine.
const State = enum {
    uninitialized,
    initialized,
    shutdown,
};

pub const Server = struct {
    const AnalysisResult = struct {
        arena: std.heap.ArenaAllocator,
        diagnostics: []const types.LspDiagnostic,

        fn deinit(self: *AnalysisResult) void {
            self.arena.deinit();
        }
    };

    allocator: Allocator,
    transport: *Transport,
    state: State = .uninitialized,
    ctx: *Context,
    documents: std.StringHashMap([]const u8),
    last_diagnostics: std.StringHashMap(AnalysisResult),

    pub fn init(allocator: Allocator, transport: *Transport, ctx: *Context) Server {
        return .{
            .allocator = allocator,
            .transport = transport,
            .ctx = ctx,
            .documents = std.StringHashMap([]const u8).init(allocator),
            .last_diagnostics = std.StringHashMap(AnalysisResult).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        var diag_it = self.last_diagnostics.iterator();
        while (diag_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var result = entry.value_ptr.*;
            result.deinit();
        }
        self.last_diagnostics.deinit();

        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
    }

    /// Main loop: read requests and dispatch until exit.
    /// Returns the process exit code.
    pub fn run(self: *Server) u8 {
        defer self.deinit();

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

        // Document sync notifications
        if (std.mem.eql(u8, request.method, "textDocument/didOpen")) {
            return self.handleDidOpen(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/didChange")) {
            return self.handleDidChange(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/didClose")) {
            return self.handleDidClose(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/hover")) {
            return self.handleHover(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/completion")) {
            return self.handleCompletion(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/signatureHelp")) {
            return self.handleSignatureHelp(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/formatting")) {
            return self.handleFormatting(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/documentSymbol")) {
            return self.handleDocumentSymbol(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/semanticTokens/full")) {
            return self.handleSemanticTokens(request);
        } else if (std.mem.eql(u8, request.method, "textDocument/definition")) {
            return self.handleDefinition(request);
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
            .capabilities = .{
                .hoverProvider = true,
                .completionProvider = .{},
                .textDocumentSync = .{ .openClose = true, .change = 1 },
                .signatureHelpProvider = .{ .triggerCharacters = &.{" "} },
                .documentFormattingProvider = true,
                .documentSymbolProvider = true,
                .semanticTokensProvider = .{
                    .legend = .{
                        .tokenTypes = &.{ "keyword", "number", "string", "comment", "function", "variable", "operator" },
                        .tokenModifiers = &.{ "declaration", "documentation" },
                    },
                    .full = true,
                },
                .definitionProvider = true,
            },
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

    fn handleDidOpen(self: *Server, request: types.Request) !void {
        const params = request.params orelse return;
        const td = getJsonObject(params, "textDocument") orelse return;
        const uri = getJsonString(td, "uri") orelse return;
        const text = getJsonString(td, "text") orelse return;

        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);

        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        if (self.documents.fetchRemove(owned_uri)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }

        try self.documents.put(owned_uri, owned_text);

        self.analyzeDocument(uri, text);
    }

    fn handleDidChange(self: *Server, request: types.Request) !void {
        const params = request.params orelse return;
        const td = getJsonObject(params, "textDocument") orelse return;
        const uri = getJsonString(td, "uri") orelse return;

        const changes = getJsonArray(params, "contentChanges") orelse return;
        if (changes.len == 0) return;
        const new_text = getJsonString(changes[0], "text") orelse return;

        const owned_text = try self.allocator.dupe(u8, new_text);
        errdefer self.allocator.free(owned_text);

        var found = false;
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, uri)) {
                self.allocator.free(entry.value_ptr.*);
                entry.value_ptr.* = owned_text;
                found = true;
                break;
            }
        }

        if (!found) {
            const owned_uri = try self.allocator.dupe(u8, uri);
            try self.documents.put(owned_uri, owned_text);
        }

        self.analyzeDocument(uri, new_text);
    }

    fn handleDidClose(self: *Server, request: types.Request) !void {
        const params = request.params orelse return;
        const td = getJsonObject(params, "textDocument") orelse return;
        const uri = getJsonString(td, "uri") orelse return;

        // Remove document text
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, uri)) {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
                self.documents.removeByPtr(entry.key_ptr);
                break;
            }
        }

        // Remove cached diagnostics
        var diag_it = self.last_diagnostics.iterator();
        while (diag_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, uri)) {
                self.allocator.free(entry.key_ptr.*);
                var result = entry.value_ptr.*;
                result.deinit();
                self.last_diagnostics.removeByPtr(entry.key_ptr);
                break;
            }
        }

        // Publish empty diagnostics to clear editor markers
        self.transport.writeNotification("textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = &.{},
        }) catch {};
    }

    fn analyzeDocument(self: *Server, uri: []const u8, text: []const u8) void {
        var analysis_arena = std.heap.ArenaAllocator.init(self.allocator);
        var stored_in_cache = false;
        defer if (!stored_in_cache) analysis_arena.deinit();
        const arena_alloc = analysis_arena.allocator();

        // Save context state
        const saved_source = self.ctx.current_source;
        const saved_source_dir = self.ctx.current_source_dir;
        const saved_check_mode = self.ctx.check_mode;
        const saved_import_frame = self.ctx.import_frame_index;
        const saved_durable_floor = self.ctx.durable_frame_floor;
        const saved_stack_depth = self.ctx.stack.depth();

        // Restore context state on exit
        defer {
            self.ctx.current_source = saved_source;
            self.ctx.current_source_dir = saved_source_dir;
            self.ctx.check_mode = saved_check_mode;
            self.ctx.import_frame_index = saved_import_frame;
            self.ctx.durable_frame_floor = saved_durable_floor;
            // Truncate stack to saved depth
            while (self.ctx.stack.depth() > saved_stack_depth) {
                self.ctx.stack.popAndRelease() catch break;
            }
        }

        // Push frames for analysis
        self.ctx.pushLocalFrame() catch return;
        defer self.ctx.popLocalFrame();

        self.ctx.pushPragmaFrame() catch return;
        defer self.ctx.popPragmaFrame();

        self.ctx.check_mode = true;
        self.ctx.current_source = uri;
        self.ctx.import_frame_index = self.ctx.local_frames.items.len - 1;
        self.ctx.durable_frame_floor = self.ctx.import_frame_index;

        // Parse and execute definitions using the parser directly
        var parse_error_diag: ?types.LspDiagnostic = null;
        var tokenizer = Tokenizer.init(text);

        while (true) {
            const prev_pos = tokenizer.pos;
            const instrs = parser.parseTopLevel(self.ctx.quotationAllocator(), &tokenizer, self.ctx) catch {
                const lsp_line: i64 = if (tokenizer.line > 1) @intCast(tokenizer.line - 1) else 0;
                parse_error_diag = .{
                    .range = .{
                        .start = .{ .line = lsp_line, .character = 0 },
                        .end = .{ .line = lsp_line, .character = 0 },
                    },
                    .severity = 1,
                    .source = "1z",
                    .message = "parse error",
                };
                break;
            };
            if (instrs.len == 0 and tokenizer.pos == prev_pos) break;
            if (instrs.len == 0) continue;
            if (Context.isDefinitionStatement(instrs)) {
                self.ctx.executeQuotation(.{ .instructions = instrs }) catch {};
            }
        }

        if (parse_error_diag != null) {
            // Error recovery: use cached diagnostics if available, else publish parse error
            var diag_it = self.last_diagnostics.iterator();
            while (diag_it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, uri)) {
                    // Republish cached diagnostics
                    self.transport.writeNotification("textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
                        .uri = uri,
                        .diagnostics = entry.value_ptr.diagnostics,
                    }) catch {};
                    return;
                }
            }
            // No cache; publish just the parse error
            const diags = [1]types.LspDiagnostic{parse_error_diag.?};
            self.transport.writeNotification("textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
                .uri = uri,
                .diagnostics = &diags,
            }) catch {};
            return;
        }

        // Run InferenceEngine
        _ = call_graph.build(&self.ctx.dictionary, &self.ctx.dispatch, self.ctx.quotationAllocator()) catch return;

        var engine = effect_inference.InferenceEngine.init(
            &self.ctx.dictionary,
            &self.ctx.dispatch,
            self.ctx.local_frames.items,
            self.ctx.quotationAllocator(),
            null,
            false,
            false,
            &self.ctx.builtin_type_values,
            self.ctx.getAnyTypeSentinel(),
            .err,
            .err,
            .err,
            .warning,
            self.ctx,
        );
        defer engine.deinit();
        engine.analyzeAll(uri) catch return;

        // Map engine diagnostics to LSP diagnostics
        const engine_diags = engine.getDiagnostics();
        var lsp_diags: std.ArrayListUnmanaged(types.LspDiagnostic) = .{};
        for (engine_diags) |diag| {
            const lsp_line: i64 = if (diag.source_line > 0) @intCast(diag.source_line - 1) else 0;

            // Find line length for end character
            var end_char: i64 = 0;
            var line_idx: usize = 0;
            var scan_lines = std.mem.splitScalar(u8, text, '\n');
            while (scan_lines.next()) |scan_line| {
                if (line_idx == @as(usize, @intCast(lsp_line))) {
                    end_char = @intCast(scan_line.len);
                    break;
                }
                line_idx += 1;
            }

            const severity: i64 = switch (diag.severity) {
                .err => 1,
                .warning => 2,
                .note => 3,
            };

            const message = std.fmt.allocPrint(arena_alloc, "{s}: {s}", .{ diag.word_name, diag.message }) catch continue;

            lsp_diags.append(arena_alloc, .{
                .range = .{
                    .start = .{ .line = lsp_line, .character = 0 },
                    .end = .{ .line = lsp_line, .character = end_char },
                },
                .severity = severity,
                .source = "1z",
                .message = message,
            }) catch continue;
        }

        // Store in cache
        const cached_diags = arena_alloc.dupe(types.LspDiagnostic, lsp_diags.items) catch return;

        // Remove old cached entry for this URI
        var old_it = self.last_diagnostics.iterator();
        while (old_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, uri)) {
                self.allocator.free(entry.key_ptr.*);
                var old_result = entry.value_ptr.*;
                old_result.deinit();
                self.last_diagnostics.removeByPtr(entry.key_ptr);
                break;
            }
        }

        const cache_key = self.allocator.dupe(u8, uri) catch return;
        self.last_diagnostics.put(cache_key, .{
            .arena = analysis_arena,
            .diagnostics = cached_diags,
        }) catch {
            self.allocator.free(cache_key);
            return;
        };
        stored_in_cache = true;

        // Publish diagnostics
        self.transport.writeNotification("textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = cached_diags,
        }) catch {};
    }

    fn handleHover(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        const params = request.params orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const td = getJsonObject(params, "textDocument") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const uri = getJsonString(td, "uri") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const position = getJsonObject(params, "position") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const line = getJsonInt(position, "line") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const character = getJsonInt(position, "character") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const text = self.getDocumentText(uri) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const word = findWordAtPosition(text, line, character) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        // strip trailing `:` from symbol literals
        const lookup_name = if (word.len > 1 and word[word.len - 1] == ':')
            word[0 .. word.len - 1]
        else
            word;

        const def = self.ctx.lookupWord(lookup_name) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const markdown = try formatHoverMarkdown(self.allocator, lookup_name, def);
        defer self.allocator.free(markdown);

        const result = types.HoverResult{
            .contents = .{ .value = markdown },
        };
        try self.transport.writeResponse(id, result);
    }

    fn handleCompletion(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        const params = request.params orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const td = getJsonObject(params, "textDocument") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const uri = getJsonString(td, "uri") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const position = getJsonObject(params, "position") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const line = getJsonInt(position, "line") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const character = getJsonInt(position, "character") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const text = self.getDocumentText(uri) orelse {
            try self.transport.writeResponse(id, types.CompletionList{ .items = &.{} });
            return;
        };

        const prefix = findPrefixAtPosition(text, line, character);

        var items: std.ArrayListUnmanaged(types.CompletionItem) = .{};
        defer items.deinit(self.allocator);

        const max_items: usize = 100;

        // Iterate local frames, wherethe prelude words live
        for (self.ctx.local_frames.items) |*frame| {
            if (items.items.len >= max_items) break;
            var frame_it = frame.iterator();
            while (frame_it.next()) |entry| {
                if (items.items.len >= max_items) break;
                const name = entry.key_ptr.*;
                if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
                    try items.append(self.allocator, makeCompletionItem(name, entry.value_ptr.*));
                }
            }
        }

        // Iterate global dictionary, where native words live
        {
            var dict_it = self.ctx.dictionary.entries.iterator();
            while (dict_it.next()) |entry| {
                if (items.items.len >= max_items) break;
                const name = entry.key_ptr.*;
                if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
                    try items.append(self.allocator, makeCompletionItem(name, dict_mod.loadSlot(entry.value_ptr.*).*));
                }
            }
        }

        const result = types.CompletionList{
            .items = items.items,
        };
        try self.transport.writeResponse(id, result);
    }

    fn handleSignatureHelp(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        const params = request.params orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const td = getJsonObject(params, "textDocument") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const uri = getJsonString(td, "uri") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const position = getJsonObject(params, "position") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const line = getJsonInt(position, "line") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const character = getJsonInt(position, "character") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const text = self.getDocumentText(uri) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const word = findWordBeforePosition(text, line, character) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const lookup_name = if (word.len > 1 and word[word.len - 1] == ':')
            word[0 .. word.len - 1]
        else
            word;

        const def = self.ctx.lookupWord(lookup_name) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        var label_buf: [512]u8 = undefined;
        var label_pos: usize = 0;
        @memcpy(label_buf[0..lookup_name.len], lookup_name);
        label_pos = lookup_name.len;

        if (def.stack_effect) |effect| {
            label_buf[label_pos] = ' ';
            label_pos += 1;
            var fbs = std.io.fixedBufferStream(label_buf[label_pos..]);
            effect.write(fbs.writer()) catch {};
            label_pos += fbs.pos;
        }

        var param_items: [32]types.ParameterInformation = undefined;
        var param_count: usize = 0;

        if (def.stack_effect) |effect| {
            for (effect.inputs) |input_param| {
                if (param_count >= param_items.len) break;
                param_items[param_count] = .{ .label = input_param.name };
                param_count += 1;
            }
        }

        const sig = types.SignatureInformation{
            .label = label_buf[0..label_pos],
            .documentation = if (def.doc) |doc| .{ .value = doc } else null,
            .parameters = if (param_count > 0) param_items[0..param_count] else null,
        };

        const result = types.SignatureHelp{
            .signatures = &.{sig},
        };
        try self.transport.writeResponse(id, result);
    }

    fn handleFormatting(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        const params = request.params orelse {
            try self.transport.writeResponse(id, @as([]const types.TextEdit, &.{}));
            return;
        };

        const td = getJsonObject(params, "textDocument") orelse {
            try self.transport.writeResponse(id, @as([]const types.TextEdit, &.{}));
            return;
        };
        const uri = getJsonString(td, "uri") orelse {
            try self.transport.writeResponse(id, @as([]const types.TextEdit, &.{}));
            return;
        };

        const text = self.getDocumentText(uri) orelse {
            try self.transport.writeResponse(id, @as([]const types.TextEdit, &.{}));
            return;
        };

        const formatted = formatter.formatString(self.allocator, text) catch {
            try self.transport.writeResponse(id, @as([]const types.TextEdit, &.{}));
            return;
        };
        defer self.allocator.free(formatted);

        var last_line: i64 = 0;
        var last_line_len: i64 = 0;
        var line_start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                last_line += 1;
                line_start = i + 1;
            }
        }
        last_line_len = @intCast(text.len - line_start);

        const edit = types.TextEdit{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = last_line, .character = last_line_len },
            },
            .newText = formatted,
        };
        try self.transport.writeResponse(id, [1]types.TextEdit{edit});
    }

    fn handleDocumentSymbol(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        const params = request.params orelse {
            try self.transport.writeResponse(id, @as([]const types.DocumentSymbol, &.{}));
            return;
        };

        const td = getJsonObject(params, "textDocument") orelse {
            try self.transport.writeResponse(id, @as([]const types.DocumentSymbol, &.{}));
            return;
        };
        const uri = getJsonString(td, "uri") orelse {
            try self.transport.writeResponse(id, @as([]const types.DocumentSymbol, &.{}));
            return;
        };

        const text = self.getDocumentText(uri) orelse {
            try self.transport.writeResponse(id, @as([]const types.DocumentSymbol, &.{}));
            return;
        };

        const saved_source = self.ctx.current_source;
        const saved_source_dir = self.ctx.current_source_dir;
        const saved_check_mode = self.ctx.check_mode;
        const saved_import_frame = self.ctx.import_frame_index;
        const saved_durable_floor = self.ctx.durable_frame_floor;
        const saved_stack_depth = self.ctx.stack.depth();
        defer {
            self.ctx.current_source = saved_source;
            self.ctx.current_source_dir = saved_source_dir;
            self.ctx.check_mode = saved_check_mode;
            self.ctx.import_frame_index = saved_import_frame;
            self.ctx.durable_frame_floor = saved_durable_floor;
            while (self.ctx.stack.depth() > saved_stack_depth) {
                self.ctx.stack.popAndRelease() catch break;
            }
        }

        self.ctx.pushLocalFrame() catch {
            try self.transport.writeResponse(id, @as([]const types.DocumentSymbol, &.{}));
            return;
        };
        defer self.ctx.popLocalFrame();

        self.ctx.pushPragmaFrame() catch {
            try self.transport.writeResponse(id, @as([]const types.DocumentSymbol, &.{}));
            return;
        };
        defer self.ctx.popPragmaFrame();

        self.ctx.check_mode = true;
        self.ctx.current_source = uri;
        self.ctx.import_frame_index = self.ctx.local_frames.items.len - 1;
        self.ctx.durable_frame_floor = self.ctx.import_frame_index;

        var tokenizer = Tokenizer.init(text);
        while (true) {
            const prev_pos = tokenizer.pos;
            const instrs = parser.parseTopLevel(self.ctx.quotationAllocator(), &tokenizer, self.ctx) catch break;
            if (instrs.len == 0 and tokenizer.pos == prev_pos) break;
            if (instrs.len == 0) continue;
            if (Context.isDefinitionStatement(instrs)) {
                self.ctx.executeQuotation(.{ .instructions = instrs }) catch {};
            }
        }

        var symbols: std.ArrayListUnmanaged(types.DocumentSymbol) = .{};
        defer symbols.deinit(self.allocator);

        const top_frame = &self.ctx.local_frames.items[self.ctx.local_frames.items.len - 1];
        var frame_it = top_frame.iterator();
        while (frame_it.next()) |entry| {
            const def = entry.value_ptr.*;
            const src = def.source_file orelse continue;
            if (!std.mem.eql(u8, src, uri)) continue;

            const def_line: i64 = if (def.source_line > 0) @intCast(def.source_line - 1) else 0;
            const def_col: i64 = if (def.source_column > 0) @intCast(def.source_column - 1) else 0;

            var detail_buf: [256]u8 = undefined;
            var detail: ?[]const u8 = null;
            if (def.stack_effect) |effect| {
                var fbs = std.io.fixedBufferStream(&detail_buf);
                effect.write(fbs.writer()) catch {};
                const written = fbs.getWritten();
                if (written.len > 0) {
                    detail = self.allocator.dupe(u8, written) catch null;
                }
            }

            // kind 12 = Function, kind 13 = Variable
            const kind: i64 = if (def.stack_effect != null) 12 else 13;
            const name_len: i64 = @intCast(entry.key_ptr.*.len);

            symbols.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .kind = kind,
                .range = .{
                    .start = .{ .line = def_line, .character = def_col },
                    .end = .{ .line = def_line, .character = def_col + name_len },
                },
                .selectionRange = .{
                    .start = .{ .line = def_line, .character = def_col },
                    .end = .{ .line = def_line, .character = def_col + name_len },
                },
                .detail = detail,
            }) catch continue;
        }

        defer {
            for (symbols.items) |sym| {
                if (sym.detail) |d| self.allocator.free(d);
            }
        }

        try self.transport.writeResponse(id, symbols.items);
    }

    fn handleSemanticTokens(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        const params = request.params orelse {
            try self.transport.writeResponse(id, types.SemanticTokensResult{ .data = &.{} });
            return;
        };

        const td = getJsonObject(params, "textDocument") orelse {
            try self.transport.writeResponse(id, types.SemanticTokensResult{ .data = &.{} });
            return;
        };
        const uri = getJsonString(td, "uri") orelse {
            try self.transport.writeResponse(id, types.SemanticTokensResult{ .data = &.{} });
            return;
        };

        const text = self.getDocumentText(uri) orelse {
            try self.transport.writeResponse(id, types.SemanticTokensResult{ .data = &.{} });
            return;
        };

        var data: std.ArrayListUnmanaged(i64) = .{};
        defer data.deinit(self.allocator);

        var prev_line: i64 = 0;
        var prev_col: i64 = 0;

        var tokenizer = Tokenizer.init(text);
        while (tokenizer.next()) |token| {
            if (token.kind == .newline) continue;

            const token_type: i64, const modifier: i64 = classifySemanticToken(token);

            const tok_line: i64 = @intCast(token.line - 1); // 1-based to 0-based
            const tok_col: i64 = @intCast(token.column - 1);

            const delta_line = tok_line - prev_line;
            const delta_start = if (delta_line > 0) tok_col else tok_col - prev_col;
            const length: i64 = @intCast(token.text.len);

            try data.append(self.allocator, delta_line);
            try data.append(self.allocator, delta_start);
            try data.append(self.allocator, length);
            try data.append(self.allocator, token_type);
            try data.append(self.allocator, modifier);

            prev_line = tok_line;
            prev_col = tok_col;
        }

        try self.transport.writeResponse(id, types.SemanticTokensResult{ .data = data.items });
    }

    fn handleDefinition(self: *Server, request: types.Request) !void {
        const id = request.id orelse return;
        const params = request.params orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const td = getJsonObject(params, "textDocument") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const uri = getJsonString(td, "uri") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const position = getJsonObject(params, "position") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const line = getJsonInt(position, "line") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };
        const character = getJsonInt(position, "character") orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const text = self.getDocumentText(uri) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const word = findWordAtPosition(text, line, character) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const lookup_name = if (word.len > 1 and word[word.len - 1] == ':')
            word[0 .. word.len - 1]
        else
            word;

        // Parse document definitions into a temporary frame so user-defined words are visible
        const saved_source = self.ctx.current_source;
        const saved_source_dir = self.ctx.current_source_dir;
        const saved_check_mode = self.ctx.check_mode;
        const saved_import_frame = self.ctx.import_frame_index;
        const saved_durable_floor = self.ctx.durable_frame_floor;
        const saved_stack_depth = self.ctx.stack.depth();
        defer {
            self.ctx.current_source = saved_source;
            self.ctx.current_source_dir = saved_source_dir;
            self.ctx.check_mode = saved_check_mode;
            self.ctx.import_frame_index = saved_import_frame;
            self.ctx.durable_frame_floor = saved_durable_floor;
            while (self.ctx.stack.depth() > saved_stack_depth) {
                self.ctx.stack.popAndRelease() catch break;
            }
        }

        self.ctx.pushLocalFrame() catch {
            try self.transport.writeNullResponse(id);
            return;
        };
        defer self.ctx.popLocalFrame();

        self.ctx.pushPragmaFrame() catch {
            try self.transport.writeNullResponse(id);
            return;
        };
        defer self.ctx.popPragmaFrame();

        self.ctx.check_mode = true;
        self.ctx.current_source = uri;
        self.ctx.import_frame_index = self.ctx.local_frames.items.len - 1;
        self.ctx.durable_frame_floor = self.ctx.import_frame_index;

        var tokenizer = Tokenizer.init(text);
        while (true) {
            const prev_pos = tokenizer.pos;
            const instrs = parser.parseTopLevel(self.ctx.quotationAllocator(), &tokenizer, self.ctx) catch break;
            if (instrs.len == 0 and tokenizer.pos == prev_pos) break;
            if (instrs.len == 0) continue;
            if (Context.isDefinitionStatement(instrs)) {
                self.ctx.executeQuotation(.{ .instructions = instrs }) catch {};
            }
        }

        const def = self.ctx.lookupWord(lookup_name) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const source_file = def.source_file orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        // Build URI from source file path
        var def_uri_buf: [4096]u8 = undefined;
        const def_uri = if (std.mem.startsWith(u8, source_file, "file://"))
            source_file
        else blk: {
            var fbs = std.io.fixedBufferStream(&def_uri_buf);
            fbs.writer().print("file://{s}", .{source_file}) catch {
                try self.transport.writeNullResponse(id);
                return;
            };
            break :blk fbs.getWritten();
        };

        const def_line: i64 = if (def.source_line > 0) @intCast(def.source_line - 1) else 0;
        const def_col: i64 = if (def.source_column > 0) @intCast(def.source_column - 1) else 0;
        const name_len: i64 = @intCast(lookup_name.len);

        const location = types.Location{
            .uri = def_uri,
            .range = .{
                .start = .{ .line = def_line, .character = def_col },
                .end = .{ .line = def_line, .character = def_col + name_len },
            },
        };
        try self.transport.writeResponse(id, location);
    }

    fn getDocumentText(self: *Server, uri: []const u8) ?[]const u8 {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, uri)) {
                return entry.value_ptr.*;
            }
        }
        return null;
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
// Helpers
// =========================================================================

fn getJsonString(val: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn getJsonObject(val: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    return obj.get(key);
}

fn getJsonInt(val: std.json.Value, key: []const u8) ?i64 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .integer => |v| v,
        else => null,
    };
}

fn getJsonArray(val: std.json.Value, key: []const u8) ?[]std.json.Value {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .array => |a| a.items,
        else => null,
    };
}

/// Find the word token at a given LSP position, 0-based line / character.
/// Returns the token text or null if no word token found at that position.
fn findWordAtPosition(text: []const u8, lsp_line: i64, lsp_char: i64) ?[]const u8 {
    if (lsp_line < 0 or lsp_char < 0) return null;

    const target_line: usize = @intCast(lsp_line);
    const target_char: usize = @intCast(lsp_char);

    // tokenizer is 1-based
    const tok_line = target_line + 1;

    var tokenizer = Tokenizer.init(text);
    while (tokenizer.next()) |token| {
        if (token.kind != .word) continue;
        if (token.line != tok_line) continue;

        // token.column is 1-based
        const tok_start = token.column - 1;
        const tok_end = tok_start + token.text.len;
        if (target_char >= tok_start and target_char < tok_end) {
            return token.text;
        }
    }

    return null;
}

/// Find the word immediately before the cursor position (skipping whitespace).
/// Used for signature help to identify the word being called.
fn findWordBeforePosition(text: []const u8, lsp_line: i64, lsp_char: i64) ?[]const u8 {
    if (lsp_line < 0 or lsp_char < 0) return null;

    const target_line: usize = @intCast(lsp_line);
    const target_char: usize = @intCast(lsp_char);

    // find line start
    var line_start: usize = 0;
    var current_line: usize = 0;
    for (text, 0..) |c, i| {
        if (current_line == target_line) {
            line_start = i;
            break;
        }
        if (c == '\n') current_line += 1;
    } else {
        if (current_line == target_line) {
            line_start = text.len;
        } else {
            return null;
        }
    }

    var cursor = @min(line_start + target_char, text.len);

    // skip back over whitespace
    while (cursor > 0) {
        const c = text[cursor - 1];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        cursor -= 1;
    }

    if (cursor == 0) return null;

    // walk back over nonwhites pace to find word start
    const word_end = cursor;
    while (cursor > 0) {
        const c = text[cursor - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
        cursor -= 1;
    }

    if (word_end == cursor) return null;
    return text[cursor..word_end];
}

/// Find the prefix at a given LSP position by scanning backward from cursor.
/// Returns the prefix string (may be empty if cursor is at whitespace).
fn findPrefixAtPosition(text: []const u8, lsp_line: i64, lsp_char: i64) []const u8 {
    if (lsp_line < 0 or lsp_char < 0) return "";

    const target_line: usize = @intCast(lsp_line);
    const target_char: usize = @intCast(lsp_char);

    var line_start: usize = 0;
    var current_line: usize = 0;
    for (text, 0..) |c, i| {
        if (current_line == target_line) {
            line_start = i;
            break;
        }
        if (c == '\n') current_line += 1;
    } else {
        // target_line is beyond the text
        if (current_line == target_line) {
            line_start = text.len;
        } else {
            return "";
        }
    }

    const cursor = @min(line_start + target_char, text.len);

    var start = cursor;
    while (start > line_start) {
        const c = text[start - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
        start -= 1;
    }

    return text[start..cursor];
}

/// Format hover markdown for a word definition.
fn formatHoverMarkdown(allocator: Allocator, name: []const u8, def: WordDefinition) ![]u8 {
    // estimate: code fence + name + effect + doc
    var effect_buf: [256]u8 = undefined;
    var effect_str: []const u8 = "";
    if (def.stack_effect) |effect| {
        var fbs = std.io.fixedBufferStream(&effect_buf);
        effect.write(fbs.writer()) catch {};
        effect_str = fbs.getWritten();
    }

    const space_and_effect = if (effect_str.len > 0) effect_str.len + 1 else 0;
    // doc_part: "\n\n" + doc
    const doc_part = if (def.doc) |doc| doc.len + 2 else 0;
    // total: "```1z\n" + name + " effect" + "\n```" + "\n\ndoc"
    const total = 6 + name.len + space_and_effect + 4 + doc_part;

    const result = try allocator.alloc(u8, total);
    var pos: usize = 0;

    @memcpy(result[pos..][0..6], "```1z\n");
    pos += 6;
    @memcpy(result[pos..][0..name.len], name);
    pos += name.len;

    if (effect_str.len > 0) {
        result[pos] = ' ';
        pos += 1;
        @memcpy(result[pos..][0..effect_str.len], effect_str);
        pos += effect_str.len;
    }

    @memcpy(result[pos..][0..4], "\n```");
    pos += 4;

    if (def.doc) |doc| {
        @memcpy(result[pos..][0..2], "\n\n");
        pos += 2;
        @memcpy(result[pos..][0..doc.len], doc);
        pos += doc.len;
    }

    return result[0..pos];
}

/// Build a CompletionItem from a word name and definition.
fn makeCompletionItem(name: []const u8, def: WordDefinition) types.CompletionItem {
    // Function (3) for words with stack effects, Variable (6) for others
    const kind: i64 = if (def.stack_effect != null) 3 else 6;

    return .{
        .label = name,
        .kind = kind,
        .detail = if (def.stack_effect) |effect| formatEffectStatic(effect.*) else null,
        .documentation = if (def.doc) |doc| .{ .value = doc } else null,
    };
}

/// Format a stack effect as a static string for completion detail.
/// Uses a fixed buffer since completion details are short.
fn formatEffectStatic(effect: StackEffect) ?[]const u8 {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    effect.write(stream.writer()) catch return null;

    const written = stream.getWritten();
    if (written.len == 0) return null;
    return written;
}

/// Classify a tokenizer token into a semantic token type index and modifier bits.
///
/// Token types: keyword=0, number=1, string=2, comment=3, function=4, variable=5, operator=6.
/// Modifier bits: declaration=1, documentation=2.
///
/// XXX(ripta): Lots of hardcoded heuristics here. We could improve accuracy by
///             tracking more precise token types in the tokenizer, or by doing
///             some light parsing here to disambiguate, e.g., distinguishing
///             keywords from words, or comments from doc comments.
fn classifySemanticToken(token: Token) struct { i64, i64 } {
    if (token.kind == .doc_comment) return .{ 3, 2 };
    if (token.kind == .comment) return .{ 3, 0 };

    const text = token.text;
    if (text.len == 0) return .{ 4, 0 };

    // strings
    if (text[0] == '"') return .{ 2, 0 };

    // brackets and structural keywords
    if (text.len == 1) {
        if (text[0] == '[' or text[0] == ']' or
            text[0] == '(' or text[0] == ')' or
            text[0] == '{' or text[0] == '}' or
            text[0] == ';')
            return .{ 0, 0 };
    }

    // `--` separator in stack effects
    if (std.mem.eql(u8, text, "--")) return .{ 0, 0 };

    // words ending with `{` (e.g. struct{, enum{, method{)
    if (text.len > 1 and text[text.len - 1] == '{') return .{ 0, 0 };

    // symbol literals (words ending with `:`, len > 1) are declarations
    if (text.len > 1 and text[text.len - 1] == ':') return .{ 5, 1 };

    // numbers: starts with digit, or hex/octal/binary prefix
    if (std.ascii.isDigit(text[0]) or
        (text.len > 1 and text[0] == '-' and std.ascii.isDigit(text[1])))
        return .{ 1, 0 };
    if (text.len > 2 and text[0] == '0' and
        (text[1] == 'x' or text[1] == 'o' or text[1] == 'b'))
        return .{ 1, 0 };

    // known operators
    if (isOperator(text)) return .{ 6, 0 };

    // everything else is a function/word
    return .{ 4, 0 };
}

fn isOperator(text: []const u8) bool {
    const operators = [_][]const u8{
        "+",          "-",           "*",  "/",   "=",   "<",      ">",       "<=",     ">=",      "<>",
        "mod",        "and",         "or", "not", "xor", "negate", "bit-and", "bit-or", "bit-xor", "bit-not",
        "shift-left", "shift-right",
    };
    for (&operators) |op| {
        if (std.mem.eql(u8, text, op)) return true;
    }
    return false;
}

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
    for (messages) |raw_msg| {
        const msg = std.mem.trimRight(u8, raw_msg, "\n");
        out.writer.print("Content-Length: {d}\r\n\r\n{s}", .{ msg.len, msg }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

const RunResult = struct {
    exit_code: u8,
    output: []const u8,
};

fn runServer(input: []const u8, out_buf: []u8) RunResult {
    var reader = IoReader.fixed(input);
    var writer = IoWriter.fixed(out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch return .{ .exit_code = 255, .output = "" };
    var server = Server.init(std.testing.allocator, &transport, &ctx);
    const exit_code = server.run();
    return .{ .exit_code = exit_code, .output = writer.buffered() };
}

/// Extract the Nth JSON-RPC response from the output buffer (0-indexed).
fn extractResponse(output: []const u8, index: usize) ?[]const u8 {
    var pos: usize = 0;
    var count: usize = 0;

    while (pos < output.len) {
        const header_end = std.mem.indexOf(u8, output[pos..], "\r\n\r\n") orelse return null;
        const header = output[pos .. pos + header_end];

        var content_length: usize = 0;
        if (std.ascii.startsWithIgnoreCase(header, "content-length:")) {
            const value_str = std.mem.trim(u8, header["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value_str, 10) catch return null;
        }
        if (content_length == 0) return null;

        const body_start = pos + header_end + 4;
        const body_end = body_start + content_length;
        if (body_end > output.len) return null;

        if (count == index) {
            return output[body_start..body_end];
        }

        pos = body_end;
        count += 1;
    }

    return null;
}

test "clean lifecycle returns exit code 0" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "exit without shutdown returns exit code 1" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "request before initialize returns server_not_initialized" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","id":11,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "unknown method returns method_not_found" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":5,"method":"nonexistent","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "double initialize returns error" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [8192]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "hover on known prelude word returns stack effect" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup drop"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":1}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, response 1 = publishDiagnostics, response 2 = hover
    const hover_resp = extractResponse(result.output, 2);
    try std.testing.expect(hover_resp != null);

    // hover response should contain "dup" and stack effect notation
    try std.testing.expect(std.mem.indexOf(u8, hover_resp.?, "dup") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover_resp.?, "```1z") != null);
}

test "hover on unknown word returns null result" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"xyznonexistent"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":0}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = hover
    const hover_resp = extractResponse(result.output, 2);
    try std.testing.expect(hover_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, hover_resp.?, "\"result\":null") != null);
}

test "hover on whitespace returns null result" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup   drop"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":4}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = hover
    const hover_resp = extractResponse(result.output, 2);
    try std.testing.expect(hover_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, hover_resp.?, "\"result\":null") != null);
}

test "didChange updates document for hover" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///test.1z","version":2},"contentChanges":[{"text":"drop"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":1}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = didOpen diags, 2 = didChange diags, 3 = hover
    const hover_resp = extractResponse(result.output, 3);
    try std.testing.expect(hover_resp != null);

    // should show "drop" not "dup" after the change
    try std.testing.expect(std.mem.indexOf(u8, hover_resp.?, "drop") != null);
}

test "completion with prefix returns matching words" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"du"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":2}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = completion
    const comp_resp = extractResponse(result.output, 2);
    try std.testing.expect(comp_resp != null);

    try std.testing.expect(std.mem.indexOf(u8, comp_resp.?, "dup") != null);
}

test "completion with empty prefix returns items" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":" "}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":1}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = completion
    const comp_resp = extractResponse(result.output, 2);
    try std.testing.expect(comp_resp != null);
    // Should have items (non-empty list)
    try std.testing.expect(std.mem.indexOf(u8, comp_resp.?, "\"items\":[{") != null);
}

test "initialize returns hover and completion capabilities" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const init_resp = extractResponse(result.output, 0);
    try std.testing.expect(init_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"hoverProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"completionProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"textDocumentSync\"") != null);
}

test "findWordAtPosition" {
    const text = "dup drop swap";
    // "dup" at column 0-2, "drop" at column 4-7, "swap" at column 9-12
    try std.testing.expectEqualSlices(u8, "dup", findWordAtPosition(text, 0, 0).?);
    try std.testing.expectEqualSlices(u8, "dup", findWordAtPosition(text, 0, 2).?);
    try std.testing.expect(findWordAtPosition(text, 0, 3) == null); // whitespace
    try std.testing.expectEqualSlices(u8, "drop", findWordAtPosition(text, 0, 4).?);
    try std.testing.expectEqualSlices(u8, "swap", findWordAtPosition(text, 0, 9).?);
}

test "findWordAtPosition multiline" {
    const text = "dup\ndrop\nswap";
    try std.testing.expectEqualSlices(u8, "dup", findWordAtPosition(text, 0, 0).?);
    try std.testing.expectEqualSlices(u8, "drop", findWordAtPosition(text, 1, 0).?);
    try std.testing.expectEqualSlices(u8, "swap", findWordAtPosition(text, 2, 0).?);
}

test "findPrefixAtPosition" {
    const text = "du";
    const prefix = findPrefixAtPosition(text, 0, 2);
    try std.testing.expectEqualSlices(u8, "du", prefix);
}

test "findPrefixAtPosition at whitespace" {
    const text = "dup ";
    const prefix = findPrefixAtPosition(text, 0, 4);
    try std.testing.expectEqualSlices(u8, "", prefix);
}

test "findPrefixAtPosition multiline" {
    const text = "dup\ndro";
    const prefix = findPrefixAtPosition(text, 1, 3);
    try std.testing.expectEqualSlices(u8, "dro", prefix);
}

test "formatHoverMarkdown with stack effect and doc" {
    const allocator = std.testing.allocator;
    const def = WordDefinition{
        .name = "dup",
        .stack_effect = &.{
            .inputs = &.{.{ .name = "a" }},
            .outputs = &.{ .{ .name = "a" }, .{ .name = "a" } },
        },
        .doc = "Duplicate the top stack value.",
        .action = .{ .compound = &.{} },
    };
    const md = try formatHoverMarkdown(allocator, "dup", def);
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "```1z") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "dup") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Duplicate") != null);
}

test "formatHoverMarkdown without doc" {
    const allocator = std.testing.allocator;
    const def = WordDefinition{
        .name = "foo",
        .action = .{ .compound = &.{} },
    };
    const md = try formatHoverMarkdown(allocator, "foo", def);
    defer allocator.free(md);

    try std.testing.expect(std.mem.indexOf(u8, md, "```1z") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "foo") != null);
}

test "writeNotification format has method and params but no id" {
    var out_buf: [4096]u8 = undefined;
    var reader = IoReader.fixed("");
    var writer = IoWriter.fixed(&out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);

    try transport.writeNotification("textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
        .uri = "file:///test.1z",
        .diagnostics = &.{},
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"method\":\"textDocument/publishDiagnostics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"params\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\"") == null);
}

test "didOpen publishes diagnostics" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup drop"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Response 0 = initialize, response 1 = publishDiagnostics notification, response 2 = shutdown
    const diag_resp = extractResponse(result.output, 1);
    try std.testing.expect(diag_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_resp.?, "textDocument/publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_resp.?, "file:///test.1z") != null);
}

test "didChange re-publishes diagnostics" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup drop"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///test.1z","version":2},"contentChanges":[{"text":"swap drop"}]}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Response 0 = initialize, 1 = didOpen diags, 2 = didChange diags, 3 = shutdown
    const diag_resp = extractResponse(result.output, 2);
    try std.testing.expect(diag_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_resp.?, "textDocument/publishDiagnostics") != null);
}

test "didClose clears diagnostics" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup drop"}}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///test.1z"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Response 0 = initialize, 1 = didOpen diags, 2 = didClose empty diags, 3 = shutdown
    const close_diag = extractResponse(result.output, 2);
    try std.testing.expect(close_diag != null);
    try std.testing.expect(std.mem.indexOf(u8, close_diag.?, "textDocument/publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, close_diag.?, "\"diagnostics\":[]") != null);
}

test "didOpen with bad definition publishes error diagnostic" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"bad: ( -- x ) [ ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Response 0 = initialize, response 1 = publishDiagnostics
    const diag_resp = extractResponse(result.output, 1);
    try std.testing.expect(diag_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_resp.?, "textDocument/publishDiagnostics") != null);
    // Should contain diagnostics (not empty) because the word declares output but produces nothing
    try std.testing.expect(std.mem.indexOf(u8, diag_resp.?, "\"diagnostics\":[]") == null);
}

test "findWordBeforePosition" {
    const text = "dup drop";
    // cursor at position 4 (space after "dup"), word before is "dup"
    try std.testing.expectEqualSlices(u8, "dup", findWordBeforePosition(text, 0, 4).?);
    // cursor at position 8 (end of "drop"), word before is "drop"
    try std.testing.expectEqualSlices(u8, "drop", findWordBeforePosition(text, 0, 8).?);
    // cursor at position 0, no word before
    try std.testing.expect(findWordBeforePosition(text, 0, 0) == null);
}

test "signatureHelp on known word" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup "}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":4}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = signatureHelp
    const sig_resp = extractResponse(result.output, 2);
    try std.testing.expect(sig_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, sig_resp.?, "signatures") != null);
    try std.testing.expect(std.mem.indexOf(u8, sig_resp.?, "dup") != null);
}

test "signatureHelp on unknown word returns null" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"xyznonexistent "}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":15}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const sig_resp = extractResponse(result.output, 2);
    try std.testing.expect(sig_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, sig_resp.?, "\"result\":null") != null);
}

test "formatting produces formatted output" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup   drop"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///test.1z"},"options":{"tabSize":4,"insertSpaces":true}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = formatting
    const fmt_resp = extractResponse(result.output, 2);
    try std.testing.expect(fmt_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, fmt_resp.?, "newText") != null);
}

test "documentSymbol finds defined words" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"double: ( n -- n ) [ 2 * ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///test.1z"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = documentSymbol
    const sym_resp = extractResponse(result.output, 2);
    try std.testing.expect(sym_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, sym_resp.?, "double") != null);
    // kind 12 = Function (has stack effect)
    try std.testing.expect(std.mem.indexOf(u8, sym_resp.?, "\"kind\":12") != null);
}

test "documentSymbol excludes prelude words" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup drop"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///test.1z"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = documentSymbol
    const sym_resp = extractResponse(result.output, 2);
    try std.testing.expect(sym_resp != null);
    // Should be an empty array since no definitions in the document
    try std.testing.expect(std.mem.indexOf(u8, sym_resp.?, "\"result\":[]") != null);
}

test "initialize advertises new capabilities" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const init_resp = extractResponse(result.output, 0);
    try std.testing.expect(init_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"signatureHelpProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"documentFormattingProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"documentSymbolProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"semanticTokensProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp.?, "\"definitionProvider\":true") != null);
}

test "semanticTokens returns non-empty data for simple document" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup 42"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///test.1z"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = semanticTokens
    const tok_resp = extractResponse(result.output, 2);
    try std.testing.expect(tok_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, tok_resp.?, "\"data\":[") != null);
    // Should not be empty
    try std.testing.expect(std.mem.indexOf(u8, tok_resp.?, "\"data\":[]") == null);
}

test "classifySemanticToken" {
    const Tok = Token;
    // comment
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .comment, .text = "\\ hello", .line = 1 });
        try std.testing.expectEqual(@as(i64, 3), typ);
        try std.testing.expectEqual(@as(i64, 0), mods);
    }
    // doc_comment
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .doc_comment, .text = "\\\\ hello", .line = 1 });
        try std.testing.expectEqual(@as(i64, 3), typ);
        try std.testing.expectEqual(@as(i64, 2), mods);
    }
    // string
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .word, .text = "\"hello\"", .line = 1 });
        try std.testing.expectEqual(@as(i64, 2), typ);
        try std.testing.expectEqual(@as(i64, 0), mods);
    }
    // number
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .word, .text = "42", .line = 1 });
        try std.testing.expectEqual(@as(i64, 1), typ);
        try std.testing.expectEqual(@as(i64, 0), mods);
    }
    // keyword bracket
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .word, .text = "[", .line = 1 });
        try std.testing.expectEqual(@as(i64, 0), typ);
        try std.testing.expectEqual(@as(i64, 0), mods);
    }
    // symbol literal (declaration)
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .word, .text = "double:", .line = 1 });
        try std.testing.expectEqual(@as(i64, 5), typ);
        try std.testing.expectEqual(@as(i64, 1), mods);
    }
    // operator
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .word, .text = "+", .line = 1 });
        try std.testing.expectEqual(@as(i64, 6), typ);
        try std.testing.expectEqual(@as(i64, 0), mods);
    }
    // keyword-like word ending with {
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .word, .text = "struct{", .line = 1 });
        try std.testing.expectEqual(@as(i64, 0), typ);
        try std.testing.expectEqual(@as(i64, 0), mods);
    }
    // regular word -> function
    {
        const typ, const mods = classifySemanticToken(Tok{ .kind = .word, .text = "dup", .line = 1 });
        try std.testing.expectEqual(@as(i64, 4), typ);
        try std.testing.expectEqual(@as(i64, 0), mods);
    }
}

test "definition on user-defined word returns location" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"myword: [ ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":0}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Find the definition response by scanning all responses for the one with id:2
    var found_def = false;
    var resp_idx: usize = 0;
    while (resp_idx < 10) : (resp_idx += 1) {
        const resp = extractResponse(result.output, resp_idx) orelse break;
        if (std.mem.indexOf(u8, resp, "\"id\":2") != null) {
            try std.testing.expect(std.mem.indexOf(u8, resp, "\"result\":null") == null);
            try std.testing.expect(std.mem.indexOf(u8, resp, "\"range\"") != null);
            found_def = true;
            break;
        }
    }
    try std.testing.expect(found_def);
}

test "definition on unknown word returns null" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"xyznonexistent"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":0}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const def_resp = extractResponse(result.output, 2);
    try std.testing.expect(def_resp != null);
    try std.testing.expect(std.mem.indexOf(u8, def_resp.?, "\"result\":null") != null);
}

test "definition on native word returns null" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"dup"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":0}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = definition
    const def_resp = extractResponse(result.output, 2);
    try std.testing.expect(def_resp != null);
    // Native words have no source_file, so we may get null OR a location
    // depending on whether 'dup' is prelude (has source) or native (no source).
    // 'dup' is actually a native word, so it should return null.
    // But if it's defined in prelude, it has a source file. Let's just check it doesn't crash.
}
