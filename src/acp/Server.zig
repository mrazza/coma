//! Agent Communication Protocol (ACP) server implementation.
//!
//! Handles JSON-RPC 2.0 requests from client applications over standard input/output
//! or streaming I/O interfaces, dispatching initialization, session creation, and turn execution.

const std = @import("std");
const agent = @import("agent");
const llm = @import("llm");
const agent_api = @import("agent_api.zig");
const client_api = @import("client_api.zig");
const shared_api = @import("shared_api.zig");
const converter = @import("converter.zig");
const JsonRpcReader = @import("json_rpc/JsonRpcReader.zig");
const JsonRpcWriter = @import("json_rpc/JsonRpcWriter.zig");
const SessionStorage = @import("SessionStorage.zig");

/// ACP server configuration.
pub const Config = @import("Config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Protocol errors encountered when decoding or validating ACP JSON-RPC requests.
pub const AcpProtocolError = error{
    InvalidJsonRpcVersion,
    MissingId,
    MethodParamsMismatch,
} || std.json.Error;

/// Internal context payload passed to session streaming callbacks.
const ServerSessionContext = struct {
    session_state: *SessionStorage.SessionState,
    json_rpc_writer: *JsonRpcWriter,
    allocator: Allocator,
    io: Io,
};

/// ACP JSON-RPC Server instance managing reader/writer loops and session state.
const Server = @This();

allocator: Allocator,
io: Io,
input_reader: *Io.Reader,
output_writer: *Io.Writer,
sessions: SessionStorage,

/// Initializes a new ACP `Server` with the provided allocator, I/O context, reader, and writer.
pub fn init(allocator: Allocator, io: Io, input_reader: *Io.Reader, output_writer: *Io.Writer) Server {
    return .{
        .allocator = allocator,
        .io = io,
        .input_reader = input_reader,
        .output_writer = output_writer,
        .sessions = .init(allocator),
    };
}

/// Deinitializes the server and frees all tracked session resources.
pub fn deinit(self: *Server) void {
    self.sessions.deinit();
}

/// Runs the main server request handling loop.
///
/// Continuously reads JSON-RPC requests from `input_reader`, validates them,
/// and processes supported methods (`initialize`, `session/new`, `session/prompt`).
///
/// This method blocks. As a result, it may make sense to launch this concurrently.
/// It can be terminated by requesting cancelation via `Io.cancel`.
pub fn run(self: *Server, acp_config: Config) !void {
    var json_rpc_reader = JsonRpcReader.init(self.allocator, self.input_reader);
    defer json_rpc_reader.deinit();
    var json_rpc_writer = JsonRpcWriter.init(self.allocator, self.output_writer);
    defer json_rpc_writer.deinit();

    var task_group: Io.Group = .init;
    defer task_group.cancel(self.io);

    while (true) {
        try self.io.checkCancel();

        const parse_result = json_rpc_reader.readJsonObject(client_api.ClientRequest) catch |err| {
            if (err == error.EndOfStream) return;
            try self.sendError(&json_rpc_writer, .null, .parse_error, "Parse error");
            continue;
        };

        const client_request = parse_result.value;
        checkClientRequestValid(client_request) catch |err| {
            parse_result.deinit();
            const msg = switch (err) {
                AcpProtocolError.InvalidJsonRpcVersion => "Invalid JSON-RPC version (must be 2.0)",
                AcpProtocolError.MissingId => "Missing request ID",
                AcpProtocolError.MethodParamsMismatch => "Request method does not match request parameters",
                else => "Invalid request",
            };
            try self.sendError(&json_rpc_writer, client_request.id, .invalid_request, msg);
            continue;
        };

        switch (client_request.params) {
            .initialize => |params| {
                defer parse_result.deinit();
                try self.handleInitialize(&json_rpc_writer, client_request.id, params);
            },
            .session_new => |params| {
                defer parse_result.deinit();
                try self.handleSessionNew(&json_rpc_writer, client_request.id, params, acp_config);
            },
            .session_prompt => {
                task_group.async(self.io, handleSessionPromptFireAndForget, .{ self, &json_rpc_writer, parse_result });
            },
            .unknown => {
                defer parse_result.deinit();
                try self.sendError(&json_rpc_writer, client_request.id, .method_not_found, "Method not found");
            },
        }
    }
}

/// Validates basic ACP JSON-RPC request structure (protocol version, request ID presence, and method/params alignment).
fn checkClientRequestValid(request: client_api.ClientRequest) AcpProtocolError!void {
    if (!std.mem.eql(u8, request.jsonrpc, "2.0")) return AcpProtocolError.InvalidJsonRpcVersion;
    if (request.id == .null) return AcpProtocolError.MissingId;
    if (std.meta.activeTag(request.params) != request.method) return AcpProtocolError.MethodParamsMismatch;
}

/// Callback handler for streaming turn updates, converting agent streaming chunks into JSON-RPC notifications.
fn handleTurnUpdate(ctx: ?*anyopaque, chunk: agent.types.StreamingChunk) void {
    const stream_ctx: *ServerSessionContext = @ptrCast(@alignCast(ctx));
    const notification = converter.streamingChunkToNotification(stream_ctx.allocator, stream_ctx.session_state.id, chunk) catch return orelse return;
    stream_ctx.json_rpc_writer.writeJsonObject(stream_ctx.io, notification, .{ .use_headers = false }) catch {};
}

/// Formats and writes a JSON-RPC error response using the provided JSON-RPC writer.
fn sendError(self: *Server, writer: *JsonRpcWriter, id: shared_api.RequestId, code: agent_api.JsonRpcErrorCode, message: []const u8) !void {
    try writer.writeJsonObject(self.io, agent_api.AgentErrorResponse{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

/// Handles `initialize` request negotiation and writes JSON-RPC `initialize` response.
fn handleInitialize(self: *Server, writer: *JsonRpcWriter, id: shared_api.RequestId, params: client_api.InitializeRequest) !void {
    _ = params;
    const reply: agent_api.AgentResponse = .{
        .id = id,
        .result = .{
            .initialize = .{
                .protocolVersion = 1,
                .agentCapabilities = null,
                .agentInfo = null,
                .authMethods = {},
            },
        },
    };

    try writer.writeJsonObject(self.io, reply, .{});
}

/// Creates a new session storage entry using `acp_config` and responds with the new `sessionId`.
fn handleSessionNew(self: *Server, writer: *JsonRpcWriter, id: shared_api.RequestId, params: client_api.NewSessionRequest, acp_config: Config) !void {
    _ = params;
    const session_state = self.sessions.createSession(.{
        self.allocator,
        self.io,
        acp_config.provider,
        acp_config.default_session_config,
    }) catch {
        try self.sendError(writer, id, .internal_error, "Failed to create session");
        return;
    };

    const reply: agent_api.AgentResponse = .{
        .id = id,
        .result = .{
            .session_new = .{
                .sessionId = session_state.id,
            },
        },
    };

    try writer.writeJsonObject(self.io, reply, .{});
}

/// Wrapper for `handleSessionPrompt` that allows it to be called from the main async loop.
///
/// Takes ownership of `parse_result`, deinit-ing it upon completion.
fn handleSessionPromptFireAndForget(self: *Server, writer: *JsonRpcWriter, parse_result: std.json.Parsed(client_api.ClientRequest)) Io.Cancelable!void {
    defer parse_result.deinit();
    const client_request = parse_result.value;
    self.handleSessionPrompt(writer, client_request.id, client_request.params.session_prompt) catch |err| {
        if (err == Io.Cancelable.Canceled) return Io.Cancelable.Canceled;
    };
}

/// Validates prompt parameters, joins prompt text blocks, streams turn updates, and sends `session/prompt` response.
///
/// TODO(razza): This method currently assume that only one prompt will ever be active for a given session at a time.
/// This gurantee does not exist. We should either buffer the prompts or block/lock waiting to acquire exclusive access
/// to the session.
fn handleSessionPrompt(self: *Server, writer: *JsonRpcWriter, id: shared_api.RequestId, params: client_api.PromptRequest) !void {
    const prompt_blocks = params.prompt;
    if (prompt_blocks.len == 0) {
        try self.sendError(writer, id, .invalid_params, "Prompt array cannot be empty");
        return;
    }

    const session = self.sessions.getSession(params.sessionId) catch |err| {
        const code: agent_api.JsonRpcErrorCode = if (err == error.SessionNotFound) .session_not_found else .internal_error;
        const msg = if (err == error.SessionNotFound) "Session not found" else "Session retrieval error";
        try self.sendError(writer, id, code, msg);
        return;
    };

    var combined_prompt: std.ArrayList(u8) = .empty;
    defer combined_prompt.deinit(self.allocator);
    for (prompt_blocks) |block| {
        switch (block) {
            .text => |txt| try combined_prompt.appendSlice(self.allocator, txt),
        }
    }

    var ctx: ServerSessionContext = .{
        .session_state = session,
        .json_rpc_writer = writer,
        .allocator = self.allocator,
        .io = self.io,
    };

    _ = session.session.executeTurnStreaming(.{ .prompt = combined_prompt.items }, handleTurnUpdate, &ctx) catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "Turn execution failed: {s}", .{@errorName(err)}) catch "Turn execution failed";
        try self.sendError(writer, id, .internal_error, msg);
        return;
    };

    const reply: agent_api.AgentResponse = .{
        .id = id,
        .result = .{
            .session_prompt = .{
                .stopReason = agent_api.StopReason.end_turn,
            },
        },
    };

    try writer.writeJsonObject(self.io, reply, .{});
}

test "Server error handling - malformed JSON and recovery" {
    const allocator = std.testing.allocator;

    const input =
        \\{ malformed json
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
    ;
    var reader_buf = std.Io.Reader.fixed(input);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var server = Server.init(allocator, std.testing.io, &reader_buf, &buffer.writer);
    defer server.deinit();

    try server.run(.{ .provider = undefined, .default_session_config = undefined });

    const output = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "-32700") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"protocolVersion\":1") != null);
}

test "Server error handling - invalid session ID" {
    const allocator = std.testing.allocator;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"nonexistent","prompt":[{"type":"text","text":"hello"}]}}
    ;
    var reader_buf = std.Io.Reader.fixed(input);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var server = Server.init(allocator, std.testing.io, &reader_buf, &buffer.writer);
    defer server.deinit();

    try server.run(.{ .provider = undefined, .default_session_config = undefined });

    const output = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "-32001") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Session not found") != null);
}

test "Server error handling - empty prompt array" {
    const allocator = std.testing.allocator;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s1","prompt":[]}}
    ;
    var reader_buf = std.Io.Reader.fixed(input);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var server = Server.init(allocator, std.testing.io, &reader_buf, &buffer.writer);
    defer server.deinit();

    try server.run(.{ .provider = undefined, .default_session_config = undefined });

    const output = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Prompt array cannot be empty") != null);
}

test "Server prompt handling - multiple items in prompt array" {
    const testing = @import("testing");
    const allocator = std.testing.allocator;

    var mock_provider = testing.MockProvider{};
    defer mock_provider.deinit();
    const prov = mock_provider.provider();

    const step_result = testing.MockProvider.stepResult(&.{.{ .text = "Response text" }}, &.{}, &.{});
    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        .{ .result = step_result, .continuation = testing.MockProvider.stepContinuation() },
    };
    mock_provider.execute_step_results = &outcomes;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"session_0","prompt":[{"type":"text","text":"Hello "},{"type":"text","text":"world!"}]}}
    ;
    var reader_buf = std.Io.Reader.fixed(input);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var server = Server.init(allocator, std.testing.io, &reader_buf, &buffer.writer);
    defer server.deinit();

    try server.run(.{
        .provider = prov,
        .default_session_config = .{
            .model = .{ .id = "mock-model", .display_name = "Mock Model" },
        },
    });

    const output = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "stopReason") != null);
    try std.testing.expectEqual(@as(usize, 1), mock_provider.last_input_steps.?.len);
    try std.testing.expectEqualStrings("Hello world!", mock_provider.last_input_steps.?[0].prompt);
}

test "Server prompt handling - turn execution failure includes error name" {
    const testing = @import("testing");
    const allocator = std.testing.allocator;

    var mock_provider = testing.MockProvider{};
    defer mock_provider.deinit();
    const prov = mock_provider.provider();

    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        error.HttpRequestFailed,
    };
    mock_provider.execute_step_results = &outcomes;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
        \\{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"session_0","prompt":[{"type":"text","text":"Hello"}]}}
    ;
    var reader_buf = std.Io.Reader.fixed(input);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var server = Server.init(allocator, std.testing.io, &reader_buf, &buffer.writer);
    defer server.deinit();

    try server.run(.{
        .provider = prov,
        .default_session_config = .{
            .model = .{ .id = "mock-model", .display_name = "Mock Model" },
        },
    });

    const output = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, output, "-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Turn execution failed: HttpRequestFailed") != null);
}

test "checkClientRequestValid - method params mismatch" {
    const request = client_api.ClientRequest{
        .jsonrpc = "2.0",
        .id = .{ .integer = 1 },
        .method = .session_new,
        .params = .{ .initialize = .{ .protocolVersion = 1 } },
    };
    try std.testing.expectError(AcpProtocolError.MethodParamsMismatch, checkClientRequestValid(request));
}
