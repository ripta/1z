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

/// LSP Position (0-based line and character).
pub const Position = struct {
    line: i64,
    character: i64,
};

/// LSP MarkupContent for hover/completion documentation.
pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

/// LSP Hover result.
pub const HoverResult = struct {
    contents: MarkupContent,
};

/// LSP CompletionItem.
pub const CompletionItem = struct {
    label: []const u8,
    kind: i64,
    detail: ?[]const u8 = null,
    documentation: ?MarkupContent = null,
};

/// LSP CompletionList.
pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

/// LSP CompletionOptions (server capability).
pub const CompletionOptions = struct {};

/// LSP TextDocumentSyncOptions (server capability).
pub const TextDocumentSyncOptions = struct {
    openClose: bool = false,
    change: i64 = 0,
};

/// Server capabilities returned in the initialize response.
pub const ServerCapabilities = struct {
    hoverProvider: bool = false,
    completionProvider: ?CompletionOptions = null,
    textDocumentSync: ?TextDocumentSyncOptions = null,
    signatureHelpProvider: ?SignatureHelpOptions = null,
    documentFormattingProvider: bool = false,
    documentSymbolProvider: bool = false,
    semanticTokensProvider: ?SemanticTokensOptions = null,
    definitionProvider: bool = false,
};

/// InitializeResult returned to the client.
pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
    serverInfo: ServerInfo,
};

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// LSP Range (start and end positions).
pub const LspRange = struct {
    start: Position,
    end: Position,
};

/// LSP Diagnostic with severity, source, and message.
pub const LspDiagnostic = struct {
    range: LspRange,
    severity: i64,
    source: []const u8,
    message: []const u8,
};

/// Parameters for textDocument/publishDiagnostics notification.
pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const LspDiagnostic,
};

/// Signature help trigger configuration.
pub const SignatureHelpOptions = struct {
    triggerCharacters: []const []const u8 = &.{},
};

/// Signature help response.
pub const SignatureHelp = struct {
    signatures: []const SignatureInformation,
    activeSignature: i64 = 0,
    activeParameter: ?i64 = null,
};

/// Information about a single signature.
pub const SignatureInformation = struct {
    label: []const u8,
    documentation: ?MarkupContent = null,
    parameters: ?[]const ParameterInformation = null,
};

/// Information about a single parameter.
pub const ParameterInformation = struct {
    label: []const u8,
};

/// A text edit replacing a range with new text.
pub const TextEdit = struct {
    range: LspRange,
    newText: []const u8,
};

/// A symbol in a document (for outline view).
pub const DocumentSymbol = struct {
    name: []const u8,
    kind: i64,
    range: LspRange,
    selectionRange: LspRange,
    detail: ?[]const u8 = null,
};

/// Semantic tokens legend mapping indices to token type/modifier names.
pub const SemanticTokensLegend = struct {
    tokenTypes: []const []const u8,
    tokenModifiers: []const []const u8,
};

/// Semantic tokens server capability.
pub const SemanticTokensOptions = struct {
    legend: SemanticTokensLegend,
    full: bool = false,
};

/// Semantic tokens response containing encoded token data.
pub const SemanticTokensResult = struct {
    data: []const i64,
};

/// A location in a document (URI + range).
pub const Location = struct {
    uri: []const u8,
    range: LspRange,
};
