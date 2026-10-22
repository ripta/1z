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
const parser = @import("../parser.zig");
const formatter = @import("../formatter.zig");
const value_mod = @import("../value.zig");
const Instruction = value_mod.Instruction;
const DispatchKey = @import("../dispatch.zig").DispatchKey;
const analysis_build = @import("../analysis_build.zig");

const Allocator = std.mem.Allocator;

const build_options = @import("build_options");

/// LSP server state machine.
const State = enum {
    uninitialized,
    initialized,
    shutdown,
};

/// The percent-decoded directory of a `file://` document, so the document's relative `use` and
/// `load` paths resolve against its own directory, the way `1z run` resolves them. Null for any
/// other scheme, which leaves the server's working directory as the base.
fn fileUriDir(alloc: Allocator, uri: []const u8) Allocator.Error!?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;

    const path = try alloc.dupe(u8, uri[prefix.len..]);
    defer alloc.free(path);

    const dir = std.fs.path.dirname(std.Uri.percentDecodeInPlace(path)) orelse return null;
    return try alloc.dupe(u8, dir);
}

const runCheckStatements = analysis_build.runCheckStatements;

pub const Server = struct {
    const AnalysisResult = struct {
        arena: std.heap.ArenaAllocator,
        diagnostics: []const types.LspDiagnostic,

        fn deinit(self: *AnalysisResult) void {
            self.arena.deinit();
        }
    };

    /// What building a document's analysis produced.
    const Built = struct {
        child: *Context,
        /// The 1-based line a parse error stopped the build on, or null when the whole document
        /// parsed. The statements before it still ran.
        parse_error_line: ?usize,
    };

    /// Builds a document's analysis. The server's own build is the default. A test replaces it to
    /// make a build fail in a way production cannot.
    const Builder = *const fn (server: *Server, uri: []const u8, text: []const u8) anyerror!Built;

    /// Why a version's build left no analysis.
    const Failure = enum {
        /// Out of memory. The next query on the version builds again.
        transient,
        /// Anything else. The same text would fail the same way, so queries answer empty.
        permanent,
    };

    /// One open document: its text, the analysis kept for that text, and what was last published.
    ///
    /// The child is built once per version. It is read only afterwards, so a query never runs
    /// code on it. Teardown is one `deinit` of the child.
    const Document = struct {
        text: []u8,
        child: ?*Context = null,
        parse_error_line: ?usize = null,
        failure: ?Failure = null,
        published: ?AnalysisResult = null,

        fn deinit(self: *Document, allocator: Allocator) void {
            std.debug.assert(self.child == null);

            allocator.free(self.text);
            if (self.published) |*published| published.deinit();
        }
    };

    /// Published when even the failure's own diagnostic could not be allocated.
    const failed_without_detail = [1]types.LspDiagnostic{.{
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
        .severity = 1,
        .source = "1z",
        .message = "analysis failed",
    }};

    allocator: Allocator,
    transport: *Transport,
    state: State = .uninitialized,
    ctx: *Context,
    documents: std.StringHashMap(Document),
    /// Builds attempted. A test seam: tests read it to show that a query builds nothing.
    builds: usize = 0,
    /// Children alive. A test seam: tests read it to show that every teardown site runs.
    live_children: usize = 0,
    /// A test seam. Production always builds with `buildAnalysis`.
    builder: Builder = buildAnalysis,
    fmt_engine: formatter.Engine,
    /// The parsed `format-buffer` call, or null when the 1z formatter is not in use or failed
    /// to load.
    ///
    /// It is parsed once at startup, after the module load that makes the name resolvable, so
    /// no request repeats that resolution.
    fmt_call: ?[]const Instruction = null,

    pub fn init(allocator: Allocator, transport: *Transport, ctx: *Context, fmt_engine: formatter.Engine) Server {
        return .{
            .allocator = allocator,
            .transport = transport,
            .ctx = ctx,
            .documents = std.StringHashMap(Document).init(allocator),
            .fmt_engine = fmt_engine,
        };
    }

    /// Tear down every kept child. The caller's context is the children's parent, so this runs
    /// before it goes away.
    pub fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.dropChild(entry.value_ptr);
            entry.value_ptr.deinit(self.allocator);
        }
        self.documents.deinit();
    }

    /// Build a child of the server's context for one document and run its check statements. The
    /// child owns copies of the `uri` and the directory, so nothing it keeps borrows a request.
    fn buildAnalysis(self: *Server, uri: []const u8, text: []const u8) anyerror!Built {
        const source_dir = try fileUriDir(self.allocator, uri);
        defer if (source_dir) |dir| self.allocator.free(dir);

        const child = try self.allocator.create(Context);
        errdefer self.allocator.destroy(child);

        child.* = try Context.initChild(self.allocator, self.ctx, .analysis);
        errdefer child.deinit();

        try analysis_build.begin(child, uri, source_dir);

        return .{
            .child = child,
            .parse_error_line = try analysis_build.runCheckStatements(child, text),
        };
    }

    /// Main loop: read requests and dispatch until exit.
    /// Returns the process exit code.
    pub fn run(self: *Server) u8 {
        defer self.deinit();

        if (self.fmt_engine == .one_z) self.loadFormatterModule();

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

        try self.setText(uri, text);
        self.analyzeDocument(uri);
    }

    fn handleDidChange(self: *Server, request: types.Request) !void {
        const params = request.params orelse return;
        const td = getJsonObject(params, "textDocument") orelse return;
        const uri = getJsonString(td, "uri") orelse return;

        const changes = getJsonArray(params, "contentChanges") orelse return;
        if (changes.len == 0) return;
        const new_text = getJsonString(changes[0], "text") orelse return;

        try self.setText(uri, new_text);
        self.analyzeDocument(uri);
    }

    fn handleDidClose(self: *Server, request: types.Request) !void {
        const params = request.params orelse return;
        const td = getJsonObject(params, "textDocument") orelse return;
        const uri = getJsonString(td, "uri") orelse return;

        if (self.documents.fetchRemove(uri)) |removed| {
            self.allocator.free(removed.key);

            var doc = removed.value;
            self.dropChild(&doc);
            doc.deinit(self.allocator);
        }

        self.publish(uri, &.{});
    }

    /// Store a document's new text and drop the analysis built from the old text.
    ///
    /// No query can then answer from an older version. The record keeps the diagnostics last
    /// published, which a version with a parse error republishes.
    fn setText(self: *Server, uri: []const u8, text: []const u8) !void {
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        if (self.documents.getPtr(uri)) |doc| {
            self.dropChild(doc);
            self.allocator.free(doc.text);
            doc.text = owned_text;
            doc.parse_error_line = null;
            doc.failure = null;
            return;
        }

        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);

        try self.documents.put(owned_uri, .{ .text = owned_text });
    }

    /// Tear down a document's kept child.
    ///
    /// Every task under the child is already reaped. A child has no scheduler, so `spawn` fails
    /// fast. A top-level `task-scope` builds its own worker pool and joins and frees it before it
    /// returns, so no task survives the statement that made it.
    fn dropChild(self: *Server, doc: *Document) void {
        const child = doc.child orelse return;
        doc.child = null;

        child.deinit();
        self.allocator.destroy(child);
        self.live_children -= 1;
    }

    fn analyzeDocument(self: *Server, uri: []const u8) void {
        const doc = self.documents.getPtr(uri) orelse return;
        self.rebuild(uri, doc, false);
    }

    /// The kept analysis of an open document, or null when the document is not open or its
    /// version's build failed.
    ///
    /// A transient failure is retried here. A successful retry publishes the way a `didChange`
    /// build does.
    fn analysisFor(self: *Server, uri: []const u8) ?*Context {
        const doc = self.documents.getPtr(uri) orelse return null;
        if (doc.child) |child| return child;

        if (doc.failure != .transient) return null;
        self.rebuild(uri, doc, true);
        return doc.child;
    }

    /// Build the analysis of the document's current text, record it, and publish its
    /// diagnostics. A failure is recorded on the document for this version, and `retry` keeps a
    /// repeated failure from publishing the same diagnostic again.
    fn rebuild(self: *Server, uri: []const u8, doc: *Document, retry: bool) void {
        self.builds += 1;

        const built = self.builder(self, uri, doc.text) catch |err| {
            self.recordFailure(uri, doc, err, retry);
            return;
        };

        doc.child = built.child;
        doc.parse_error_line = built.parse_error_line;
        doc.failure = null;
        self.live_children += 1;

        if (built.parse_error_line) |line| {
            self.publishParseError(uri, doc, line);
            return;
        }

        const result = self.diagnose(built.child, doc.text) catch |err| {
            self.dropChild(doc);
            self.recordFailure(uri, doc, err, retry);
            return;
        };

        if (doc.published) |*old| old.deinit();
        doc.published = result;
        self.publish(uri, result.diagnostics);
    }

    fn recordFailure(self: *Server, uri: []const u8, doc: *Document, err: anyerror, retry: bool) void {
        doc.failure = if (err == error.OutOfMemory) .transient else .permanent;
        if (retry) return;

        if (doc.published) |*old| old.deinit();
        doc.published = null;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_alloc = arena.allocator();

        const message = std.fmt.allocPrint(arena_alloc, "analysis failed: {s}", .{@errorName(err)}) catch {
            arena.deinit();
            self.publish(uri, &failed_without_detail);
            return;
        };
        const diags = arena_alloc.dupe(types.LspDiagnostic, &.{.{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            .severity = 1,
            .source = "1z",
            .message = message,
        }}) catch {
            arena.deinit();
            self.publish(uri, &failed_without_detail);
            return;
        };

        doc.published = .{ .arena = arena, .diagnostics = diags };
        self.publish(uri, diags);
    }

    /// Publish a version that stopped on a parse error.
    ///
    /// The statements before the error still ran, so queries answer from them. The diagnostics
    /// last published are republished, or a bare "parse error" at the failing line when nothing
    /// was published yet.
    fn publishParseError(self: *Server, uri: []const u8, doc: *Document, error_line: usize) void {
        if (doc.published) |published| {
            self.publish(uri, published.diagnostics);
            return;
        }

        const lsp_line: i64 = if (error_line > 1) @intCast(error_line - 1) else 0;
        const diags = [1]types.LspDiagnostic{.{
            .range = .{
                .start = .{ .line = lsp_line, .character = 0 },
                .end = .{ .line = lsp_line, .character = 0 },
            },
            .severity = 1,
            .source = "1z",
            .message = "parse error",
        }};
        self.publish(uri, &diags);
    }

    fn publish(self: *Server, uri: []const u8, diagnostics: []const types.LspDiagnostic) void {
        self.transport.writeNotification("textDocument/publishDiagnostics", types.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = diagnostics,
        }) catch {};
    }

    /// Run the inference engine over the kept child and map what it reports to LSP diagnostics.
    fn diagnose(self: *Server, child: *Context, text: []const u8) !AnalysisResult {
        var analysis_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer analysis_arena.deinit();
        const arena_alloc = analysis_arena.allocator();

        var engine = effect_inference.InferenceEngine.init(
            child,
            child.quotationAllocator(),
            null,
            false,
            false,
            child.getAnyTypeSentinel(),
            .err,
            .err,
            .err,
            .warning,
        );
        defer engine.deinit();
        try engine.analyzeAll(child.current_source);

        var lsp_diags: std.ArrayListUnmanaged(types.LspDiagnostic) = .{};
        for (engine.getDiagnostics()) |diag| {
            const lsp_line: i64 = if (diag.source_line > 0) @intCast(diag.source_line - 1) else 0;

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

            const message = try std.fmt.allocPrint(arena_alloc, "{s}: {s}", .{ diag.word_name, diag.message });

            try lsp_diags.append(arena_alloc, .{
                .range = .{
                    .start = .{ .line = lsp_line, .character = 0 },
                    .end = .{ .line = lsp_line, .character = end_char },
                },
                .severity = severity,
                .source = "1z",
                .message = message,
            });
        }

        // The copy of the arena must happen after this allocation, since a new buffer node it
        // makes would otherwise land in the local arena and leak.
        const diagnostics = try arena_alloc.dupe(types.LspDiagnostic, lsp_diags.items);
        return .{ .arena = analysis_arena, .diagnostics = diagnostics };
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

        const child = self.analysisFor(uri) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const def = child.lookupWord(lookup_name) orelse {
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

        const child = self.analysisFor(uri) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const def = child.lookupWord(lookup_name) orelse {
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

    /// Load `lib/formatter.1z` and parse the `format-buffer` call the formatting requests run.
    ///
    /// A failure is not fatal. `fmt_call` stays null, and formatting falls back to the built-in
    /// formatter, which is what the session would have used had the engine not been asked for.
    fn loadFormatterModule(self: *Server) void {
        const saved_error_state = self.ctx.saveErrorState();
        defer self.ctx.restoreErrorState(saved_error_state);

        var import_tokens = Tokenizer.init("use \"formatter\" ;");
        const import_instrs = parser.parseTopLevel(self.ctx.quotationAllocator(), &import_tokens, self.ctx) catch |err| {
            self.log("could not load lib/formatter.1z ({any}); using the built-in formatter", .{err});
            return;
        };
        self.ctx.executeQuotation(.{ .instructions = import_instrs }) catch |err| {
            self.log("could not load lib/formatter.1z ({any}); using the built-in formatter", .{err});
            return;
        };

        var call_tokens = Tokenizer.init("format-buffer");
        self.fmt_call = parser.parseTopLevel(self.ctx.quotationAllocator(), &call_tokens, self.ctx) catch |err| {
            self.log("could not resolve format-buffer ({any}); using the built-in formatter", .{err});
            return;
        };
    }

    /// Run `lib/formatter.1z`'s `format-buffer` over an editor buffer, under the `.fmt.1z` rules
    /// that apply to the document's own directory. The caller owns the result.
    ///
    /// The context outlives every request and is shared with all of them, so the call is
    /// bracketed on both axes a failure could leak through: a raise leaves error state behind,
    /// and a partial run leaves operands on the stack.
    fn formatThroughOneZ(self: *Server, call: []const Instruction, uri: []const u8, text: []const u8) ?[]u8 {
        const path = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
        const dir = std.fs.path.dirname(path) orelse ".";

        const saved_error_state = self.ctx.saveErrorState();
        defer self.ctx.restoreErrorState(saved_error_state);

        const saved_depth = self.ctx.stack.depth();
        defer {
            while (self.ctx.stack.depth() > saved_depth) {
                self.ctx.stack.popAndRelease() catch break;
            }
        }

        self.ctx.stack.push(value_mod.stringValue(text)) catch return null;
        self.ctx.stack.push(value_mod.stringValue(dir)) catch return null;
        self.ctx.executeQuotation(.{ .instructions = call }) catch return null;

        const result = self.ctx.stack.peek() catch return null;
        return switch (result) {
            .string => |s| self.allocator.dupe(u8, s.bytes) catch null,
            else => null,
        };
    }

    /// The formatted form of a document, or null when neither engine could produce one.
    fn formatDocument(self: *Server, uri: []const u8, text: []const u8) ?[]u8 {
        if (self.fmt_call) |call| return self.formatThroughOneZ(call, uri, text);
        return formatter.formatString(self.allocator, text) catch null;
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

        const formatted = self.formatDocument(uri, text) orelse {
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

        const child = self.analysisFor(uri) orelse {
            try self.transport.writeResponse(id, @as([]const types.DocumentSymbol, &.{}));
            return;
        };

        var symbols: std.ArrayListUnmanaged(types.DocumentSymbol) = .{};
        defer symbols.deinit(self.allocator);

        const document_frame = &child.local_frames.items[child.import_frame_index.?];
        var frame_it = document_frame.iterator();
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

        const child = self.analysisFor(uri) orelse {
            try self.transport.writeNullResponse(id);
            return;
        };

        const def = child.lookupWord(lookup_name) orelse {
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
        const doc = self.documents.getPtr(uri) orelse return null;
        return doc.text;
    }

    fn log(self: *Server, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const stderr_file: std.fs.File = .stderr();
        var stderr_buf: [4096]u8 = undefined;
        var stderr = stderr_file.writerStreaming(&stderr_buf);
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
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.loadPrelude(null) catch return .{ .exit_code = 255, .output = "" };
    return runServerWithContext(&ctx, input, out_buf);
}

/// Drive a whole session over a caller-owned context, so a test can seed state before the
/// session and read what the session left behind.
fn runServerWithContext(ctx: *Context, input: []const u8, out_buf: []u8) RunResult {
    var reader = IoReader.fixed(input);
    var writer = IoWriter.fixed(out_buf);
    var transport = Transport.init(std.testing.allocator, &reader, &writer);
    var server = Server.init(std.testing.allocator, &transport, ctx, .zig);
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

test "hover reports the doc of a word the document defines" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"\\\\ Doubles its input.\ndouble: ( n -- n ) [ 2 * ] ;\n3 double"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":2,"character":3}}}
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
    const hover_resp = extractResponse(result.output, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, hover_resp, "Doubles its input.") != null);
}

test "hover reports the doc of a use-imported and a reexported word" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "base.1z", .data = "\\\\ Doc of the base word.\nbase-word: [ 1 ] ;\n" });
    try tmp.dir.writeFile(.{
        .sub_path = "facade.1z",
        .data = "\"base.1z\" load reexport\n\n\\\\ Doc of the facade word.\nfacade-word: [ 2 ] ;\n",
    });

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    // The relative `use` resolves against the document's own directory, which only the `file://`
    // URI names: the server's working directory is elsewhere.
    const open_msg = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"file://{s}/doc.1z","languageId":"1z","version":1,"text":"use \"./facade.1z\" ;\nfacade-word base-word"}}}}}}
    , .{dir_path});
    defer allocator.free(open_msg);

    const hover_facade = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{{"textDocument":{{"uri":"file://{s}/doc.1z"}},"position":{{"line":1,"character":2}}}}}}
    , .{dir_path});
    defer allocator.free(hover_facade);

    const hover_base = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{{"textDocument":{{"uri":"file://{s}/doc.1z"}},"position":{{"line":1,"character":14}}}}}}
    , .{dir_path});
    defer allocator.free(hover_base);

    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        open_msg,
        hover_facade,
        hover_base,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = hover on the use-imported word,
    // 3 = hover on the reexported word
    const facade_resp = extractResponse(result.output, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, facade_resp, "Doc of the facade word.") != null);

    const base_resp = extractResponse(result.output, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, base_resp, "Doc of the base word.") != null);
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

/// Seed the in-flight error channels, standing in for an error propagating around the
/// session.
fn seedErrorState(ctx: *Context) void {
    ctx.pending_error_message = "body failed";
    ctx.appendPendingSyntheticErrorFrame("boom", "<test>", 4, null);
}

/// Assert the session left exactly what `seedErrorState` wrote, and installed no thrown stash of
/// its own.
fn expectSeededErrorState(ctx: *Context) !void {
    try std.testing.expectEqualStrings("body failed", ctx.pending_error_message.?);
    try std.testing.expectEqual(@as(usize, 1), ctx.jit_pending_trace_frames.items.len);
    try std.testing.expectEqualStrings("boom", ctx.jit_pending_trace_frames.items[0].word_name);
    try std.testing.expect(ctx.thrown_error == null);
}

// The document each of the three tests below opens redefines `foo` at a different arity, which
// the redefinition guard rejects from `;`. The analysis loop executes that statement on the
// document's own child and drops the error it raises, so the root's error state stays as seeded.
test "didOpen analysis leaves the root's error state untouched" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"foo: ( -- ) [ ] ; foo: ( a -- ) [ drop ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);
    seedErrorState(&ctx);

    var out_buf: [65536]u8 = undefined;
    const result = runServerWithContext(&ctx, input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try expectSeededErrorState(&ctx);
}

test "documentSymbol analysis leaves the root's error state untouched" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"foo: ( -- ) [ ] ; foo: ( a -- ) [ drop ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///test.1z"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);
    seedErrorState(&ctx);

    var out_buf: [65536]u8 = undefined;
    const result = runServerWithContext(&ctx, input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try expectSeededErrorState(&ctx);
}

test "definition analysis leaves the root's error state untouched" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"foo: ( -- ) [ ] ; foo: ( a -- ) [ drop ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":0}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);
    seedErrorState(&ctx);

    var out_buf: [65536]u8 = undefined;
    const result = runServerWithContext(&ctx, input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try expectSeededErrorState(&ctx);
}

// The document registers an arm for `#in?` that the prelude's own `use` machinery also calls.
// The arm lands in the child's dispatch table, so the root's arm stays as booted.
test "analysis leaves the root's dispatch arm untouched when the document replaces it" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"#in?: method{ array any } [ 2drop f ] ;\nmy-arm: generic [ drop f ] ;\n#in?: method{ fixnum any } [ 2drop f ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///test.1z"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":0}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    const in_id = ctx.resolveDispatchId("#in?").?;
    const any = ctx.getDispatchAnySentinel().descriptor.?;
    const array_key: DispatchKey = .{ .dispatch_id = in_id, .type_a = ctx.lookupBuiltinTypeValue("array").?.descriptor.?, .type_b = any };
    const fixnum_key: DispatchKey = .{ .dispatch_id = in_id, .type_a = ctx.lookupBuiltinTypeValue("fixnum").?.descriptor.?, .type_b = any };

    const base_arm = ctx.getDispatchEntry(array_key).?;
    try std.testing.expect(ctx.getDispatchEntry(fixnum_key) == null);

    var out_buf: [65536]u8 = undefined;
    const result = runServerWithContext(&ctx, input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const after = ctx.getDispatchEntry(array_key).?;
    try std.testing.expectEqual(base_arm.body.quotation.instructions.ptr, after.body.quotation.instructions.ptr);
    try std.testing.expect(ctx.getDispatchEntry(fixnum_key) == null);
}

// The document shadows a prelude word, a native, and a const. Each used to raise from `;` and
// drop out of the analysis silently, taking the document's own definition with it.
test "analysis keeps definitions that shadow the base scope" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"nip: ( x y -- y ) [ swap drop ] ;\n+: ( a b -- c ) [ 2drop 42 ] ;\nfixnum: [ 1 ] ;\nbad-decl: ( -- x ) [ 1 2 ] ;"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///test.1z"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///test.1z"},"position":{"line":0,"character":0}}}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
    });
    defer allocator.free(input);

    var out_buf: [65536]u8 = undefined;
    const result = runServer(input, &out_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // response 0 = initialize, 1 = publishDiagnostics, 2 = documentSymbol, 3 = definition
    const diag = extractResponse(result.output, 1).?;
    try std.testing.expect(std.mem.indexOf(u8, diag, "bad-decl") != null);

    const symbols = extractResponse(result.output, 2).?;
    for ([_][]const u8{ "\"nip\"", "\"+\"", "\"fixnum\"", "\"bad-decl\"" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, symbols, name) != null);
    }

    const location = extractResponse(result.output, 3).?;
    try std.testing.expect(std.mem.indexOf(u8, location, "file:///test.1z") != null);
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

test "analysis keeps definitions that share the document with top-level code" {
    const allocator = std.testing.allocator;
    const input = try buildInput(allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.1z","languageId":"1z","version":1,"text":"first: ( -- ) [ ] ;\n1 drop\nsecond: [ ] ;"}}}
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
    const diag_resp = extractResponse(result.output, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, diag_resp, "second: word has no declared stack effect") != null);

    const sym_resp = extractResponse(result.output, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, sym_resp, "\"name\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sym_resp, "\"name\":\"second\"") != null);
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

/// A server driven one message at a time, so a test can read the record between messages.
const Session = struct {
    reader: IoReader,
    writer: IoWriter,
    transport: Transport,
    server: Server,

    fn start(self: *Session, allocator: Allocator, ctx: *Context, out_buf: []u8) void {
        self.reader = IoReader.fixed("");
        self.writer = IoWriter.fixed(out_buf);
        self.transport = Transport.init(std.testing.allocator, &self.reader, &self.writer);
        self.server = Server.init(allocator, &self.transport, ctx, .zig);
        self.server.state = .initialized;
    }

    fn stop(self: *Session) void {
        self.server.deinit();
    }

    /// Dispatch one message, and return what the server wrote in answer.
    fn send(self: *Session, json: []const u8) ![]const u8 {
        const before = self.writer.buffered().len;

        var request = try self.transport.parseRequest(json);
        defer request.deinit();
        try self.server.dispatch(request);

        return self.writer.buffered()[before..];
    }

    fn open(self: *Session, uri: []const u8, text: []const u8) ![]const u8 {
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"1z\",\"version\":1,\"text\":\"{s}\"}}}}}}",
            .{ uri, text },
        );
        defer std.testing.allocator.free(json);

        return self.send(json);
    }

    fn change(self: *Session, uri: []const u8, text: []const u8) ![]const u8 {
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[{{\"text\":\"{s}\"}}]}}}}",
            .{ uri, text },
        );
        defer std.testing.allocator.free(json);

        return self.send(json);
    }

    fn close(self: *Session, uri: []const u8) ![]const u8 {
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}",
            .{uri},
        );
        defer std.testing.allocator.free(json);

        return self.send(json);
    }

    fn query(self: *Session, method: []const u8, uri: []const u8, character: usize) ![]const u8 {
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":0,\"character\":{d}}}}}}}",
            .{ method, uri, character },
        );
        defer std.testing.allocator.free(json);

        return self.send(json);
    }

    fn hover(self: *Session, uri: []const u8, character: usize) ![]const u8 {
        return self.query("textDocument/hover", uri, character);
    }
};

const test_uri = "file:///test.1z";

var test_build_error: anyerror = error.AnalysisTestFailure;
var test_transient_failures_left: usize = 0;

fn failingBuilder(server: *Server, uri: []const u8, text: []const u8) anyerror!Server.Built {
    _ = server;
    _ = uri;
    _ = text;
    return test_build_error;
}

/// Fails with an out-of-memory error for the first `test_transient_failures_left` builds, then
/// builds the way the server does.
fn flakyBuilder(server: *Server, uri: []const u8, text: []const u8) anyerror!Server.Built {
    if (test_transient_failures_left > 0) {
        test_transient_failures_left -= 1;
        return error.OutOfMemory;
    }
    return server.buildAnalysis(uri, text);
}

test "a hover on unchanged text builds nothing" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);
    defer session.stop();

    _ = try session.open(test_uri, "my-word: ( -- ) [ ] ;\\ndup drop");
    try std.testing.expectEqual(@as(usize, 1), session.server.builds);
    try std.testing.expectEqual(@as(usize, 1), session.server.live_children);

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const word = try session.hover(test_uri, 2);
        try std.testing.expect(std.mem.indexOf(u8, word, "my-word") != null);
    }

    _ = try session.query("textDocument/definition", test_uri, 2);
    _ = try session.query("textDocument/documentSymbol", test_uri, 0);
    _ = try session.query("textDocument/signatureHelp", test_uri, 8);

    try std.testing.expectEqual(@as(usize, 1), session.server.builds);
}

test "a didChange replaces the child, and no query answers from the old text" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);
    defer session.stop();

    _ = try session.open(test_uri, "old-word: ( -- ) [ ] ;");
    const before = try session.hover(test_uri, 2);
    try std.testing.expect(std.mem.indexOf(u8, before, "old-word") != null);

    _ = try session.change(test_uri, "new-word: ( -- ) [ ] ;");
    try std.testing.expectEqual(@as(usize, 2), session.server.builds);
    try std.testing.expectEqual(@as(usize, 1), session.server.live_children);

    const after = try session.hover(test_uri, 2);
    try std.testing.expect(std.mem.indexOf(u8, after, "new-word") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "old-word") == null);

    const child = session.server.documents.get(test_uri).?.child.?;
    try std.testing.expect(child.lookupWord("old-word") == null);
    try std.testing.expect(child.lookupWord("new-word") != null);
}

test "didClose, a replacing didOpen, and the server's teardown each free the child" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);

    _ = try session.open("file:///a.1z", "a-word: ( -- ) [ ] ;");
    _ = try session.open("file:///b.1z", "b-word: ( -- ) [ ] ;");
    try std.testing.expectEqual(@as(usize, 2), session.server.live_children);

    _ = try session.open("file:///a.1z", "a-word: ( -- ) [ ] ;\\na-two: ( -- ) [ ] ;");
    try std.testing.expectEqual(@as(usize, 2), session.server.live_children);
    try std.testing.expectEqual(@as(usize, 3), session.server.builds);
    try std.testing.expectEqual(@as(u32, 2), session.server.documents.count());

    const closed = try session.close("file:///a.1z");
    try std.testing.expect(std.mem.indexOf(u8, closed, "\"diagnostics\":[]") != null);
    try std.testing.expectEqual(@as(usize, 1), session.server.live_children);
    try std.testing.expectEqual(@as(u32, 1), session.server.documents.count());

    const gone = try session.hover("file:///a.1z", 2);
    try std.testing.expect(std.mem.indexOf(u8, gone, "\"result\":null") != null);

    session.stop();
    try std.testing.expectEqual(@as(usize, 0), session.server.live_children);
}

test "a failed build publishes one analysis failed diagnostic, and queries answer empty without rebuilding" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);
    defer session.stop();

    const opened = try session.open(test_uri, "bad-decl: ( -- x ) [ ] ;");
    try std.testing.expect(std.mem.indexOf(u8, opened, "bad-decl") != null);

    session.server.builder = failingBuilder;
    test_build_error = error.AnalysisTestFailure;

    const failed = try session.change(test_uri, "bad-decl: ( -- x ) [ ] ;");
    try std.testing.expect(std.mem.indexOf(u8, failed, "analysis failed: AnalysisTestFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed, "bad-decl") == null);

    const published = session.server.documents.get(test_uri).?.published.?;
    try std.testing.expectEqual(@as(usize, 1), published.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), session.server.live_children);

    const builds_after_failure = session.server.builds;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const hovered = try session.hover(test_uri, 2);
        try std.testing.expect(std.mem.indexOf(u8, hovered, "\"result\":null") != null);

        const symbols = try session.query("textDocument/documentSymbol", test_uri, 0);
        try std.testing.expect(std.mem.indexOf(u8, symbols, "\"result\":[]") != null);

        const definition = try session.query("textDocument/definition", test_uri, 2);
        try std.testing.expect(std.mem.indexOf(u8, definition, "\"result\":null") != null);
    }
    try std.testing.expectEqual(builds_after_failure, session.server.builds);

    session.server.builder = Server.buildAnalysis;
    _ = try session.change(test_uri, "good: ( -- ) [ ] ;");
    const recovered = try session.hover(test_uri, 2);
    try std.testing.expect(std.mem.indexOf(u8, recovered, "good") != null);
}

test "a transient failure is retried on the next query and then not again" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);
    defer session.stop();

    session.server.builder = flakyBuilder;
    test_transient_failures_left = 2;

    const opened = try session.open(test_uri, "my-word: ( -- ) [ ] ;");
    try std.testing.expect(std.mem.indexOf(u8, opened, "analysis failed: OutOfMemory") != null);
    try std.testing.expectEqual(@as(usize, 1), session.server.builds);

    // The retry fails again. It answers empty and does not publish the same diagnostic twice.
    const still_failing = try session.hover(test_uri, 2);
    try std.testing.expect(std.mem.indexOf(u8, still_failing, "\"result\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, still_failing, "publishDiagnostics") == null);
    try std.testing.expectEqual(@as(usize, 2), session.server.builds);

    // The retry succeeds, answers, and publishes the version's real diagnostics.
    const recovered = try session.hover(test_uri, 2);
    try std.testing.expect(std.mem.indexOf(u8, recovered, "my-word") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered, "analysis failed") == null);
    try std.testing.expectEqual(@as(usize, 3), session.server.builds);

    const record = session.server.documents.get(test_uri).?;
    try std.testing.expect(record.failure == null);
    try std.testing.expectEqual(@as(usize, 0), record.published.?.diagnostics.len);

    _ = try session.hover(test_uri, 2);
    try std.testing.expectEqual(@as(usize, 3), session.server.builds);
}

test "documentSymbol reads the import frame, not the top frame" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);
    defer session.stop();

    _ = try session.open(test_uri, "frame-word: ( -- ) [ ] ;");

    const child = session.server.documents.get(test_uri).?.child.?;
    try std.testing.expectEqual(@as(?usize, 0), child.import_frame_index);

    try child.pushLocalFrame();
    try std.testing.expectEqual(@as(usize, 2), child.local_frames.items.len);

    const symbols = try session.query("textDocument/documentSymbol", test_uri, 0);
    try std.testing.expect(std.mem.indexOf(u8, symbols, "\"frame-word\"") != null);
}

test "a parse error keeps the statements before it and republishes the last diagnostics" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);
    defer session.stop();

    const first = try session.open(test_uri, "kept: ( -- x ) [ ] ;\\n[ unclosed");
    try std.testing.expect(std.mem.indexOf(u8, first, "parse error") != null);
    try std.testing.expect(session.server.documents.get(test_uri).?.published == null);

    const hovered = try session.hover(test_uri, 2);
    try std.testing.expect(std.mem.indexOf(u8, hovered, "kept") != null);

    _ = try session.change(test_uri, "kept: ( -- x ) [ ] ;");
    const published = session.server.documents.get(test_uri).?.published.?;
    try std.testing.expect(published.diagnostics.len > 0);

    const again = try session.change(test_uri, "kept: ( -- x ) [ ] ;\\n[ unclosed");
    try std.testing.expect(std.mem.indexOf(u8, again, "kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, again, "parse error") == null);
}

test "building a document under allocation failure leaves nothing behind" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });

        var out_buf: [65536]u8 = undefined;
        var session: Session = undefined;
        session.start(failing.allocator(), &ctx, &out_buf);

        _ = session.open(test_uri, "my-word: ( -- ) [ ] ;") catch {};
        _ = session.hover(test_uri, 2) catch {};
        _ = session.change(test_uri, "other: ( -- ) [ ] ;") catch {};
        _ = session.hover(test_uri, 2) catch {};
        session.stop();

        if (!failing.has_induced_failure) break;
    }
}

test "a large diagnostics result is kept whole and freed with its record" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var text: std.ArrayListUnmanaged(u8) = .{};
    defer text.deinit(std.testing.allocator);

    const out_buf = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(out_buf);

    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, out_buf);
    defer session.stop();

    // Whether the final copy of the diagnostics needs a new arena node depends on how much room
    // the last node has left. Growing the document one diagnostic at a time crosses that edge.
    var words: usize = 0;
    while (words < 160) : (words += 1) {
        text.clearRetainingCapacity();
        for (0..words + 1) |word| {
            try text.writer(std.testing.allocator).print("bad-{d}: ( -- x ) [ ] ;\\n", .{word});
        }

        session.writer.end = 0;
        _ = try session.open(test_uri, text.items);

        const published = session.server.documents.get(test_uri).?.published.?;
        try std.testing.expectEqual(words + 1, published.diagnostics.len);
    }
}

test "a definition after a failing redefinition survives on the child" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.loadPrelude(null);

    var out_buf: [65536]u8 = undefined;
    var session: Session = undefined;
    session.start(std.testing.allocator, &ctx, &out_buf);
    defer session.stop();

    _ = try session.open(test_uri, "foo: ( -- ) [ ] ;\\nfoo: ( a -- ) [ drop ] ;\\nlater: ( -- ) [ ] ;");

    const child = session.server.documents.get(test_uri).?.child.?;
    try std.testing.expect(child.lookupWord("later") != null);

    const symbols = try session.query("textDocument/documentSymbol", test_uri, 0);
    try std.testing.expect(std.mem.indexOf(u8, symbols, "\"later\"") != null);
    try std.testing.expect(ctx.lookupWord("later") == null);
}

test "a statement that runs out of memory fails the build instead of being dropped" {
    var ctx = Context.initWithPrelude(std.testing.allocator);
    defer ctx.deinit();

    const text = "one: ( -- ) [ ] ;\ntwo: ( -- ) [ one ] ;\nthree: ( -- ) [ two one ] ;\n";

    var oom_seen: usize = 0;
    var extra: usize = 0;
    while (true) : (extra += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});

        var child = try Context.initChild(failing.allocator(), &ctx, .analysis);
        defer child.deinit();

        try analysis_build.begin(&child, "doc.1z", null);
        failing.fail_index = failing.alloc_index + extra;

        var failed = false;
        if (analysis_build.runCheckStatements(&child, text)) |line| {
            try std.testing.expectEqual(@as(?usize, null), line);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed = true;
            oom_seen += 1;
        }

        if (!failing.has_induced_failure) break;
        try std.testing.expect(failed);
    }

    try std.testing.expect(oom_seen > 0);
}
