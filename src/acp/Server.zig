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
} || std.json.Error;

/// Internal context payload passed to session streaming callbacks.
const ServerSessionContext = struct {
    session_state: *SessionStorage.SessionState,
    json_rpc_writer: *JsonRpcWriter,
    allocator: Allocator,
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

/// Callback handler for streaming turn updates, converting agent streaming chunks into JSON-RPC notifications.
fn handleTurnUpdate(ctx: ?*anyopaque, chunk: agent.types.StreamingChunk) void {
    const stream_ctx: *ServerSessionContext = @ptrCast(@alignCast(ctx));
    const notification = converter.streamingChunkToNotification(stream_ctx.allocator, stream_ctx.session_state.id, chunk) catch return orelse return;
    stream_ctx.json_rpc_writer.writeJsonObject(notification, .{ .use_headers = false }) catch {};
}

/// Formats and writes a JSON-RPC error response to the output writer.
fn sendError(self: *Server, allocator: Allocator, id: shared_api.RequestId, code: agent_api.JsonRpcErrorCode, message: []const u8) !void {
    var writer = JsonRpcWriter.init(allocator, self.output_writer);
    defer writer.deinit();
    try writer.writeJsonObject(agent_api.AgentErrorResponse{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

/// Runs the main server request handling loop.
///
/// Continuously reads JSON-RPC requests from `input_reader`, validates them,
/// and processes supported methods (`initialize`, `session/new`, `session/prompt`).
///
/// This method blocks. To cancel, request cancelation via `Io.cancel`.
pub fn run(self: *Server, acp_config: Config) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    while (true) {
        try self.io.checkCancel();
        _ = arena.reset(.retain_capacity);

        var json_rpc_reader = JsonRpcReader.init(arena_allocator, self.input_reader);
        defer json_rpc_reader.deinit();

        const parse_result = json_rpc_reader.readJsonObject(client_api.ClientRequest) catch |err| {
            if (err == error.EndOfStream) return;
            try self.sendError(arena_allocator, .null, .parse_error, "Parse error");
            continue;
        };

        const client_request = parse_result.value;
        checkClientRequestValid(client_request) catch |err| {
            const msg = switch (err) {
                AcpProtocolError.InvalidJsonRpcVersion => "Invalid JSON-RPC version (must be 2.0)",
                AcpProtocolError.MissingId => "Missing request ID",
                else => "Invalid request",
            };
            try self.sendError(arena_allocator, client_request.id, .invalid_request, msg);
            continue;
        };

        switch (client_request.method) {
            .initialize => {
                const reply: agent_api.AgentResponse = .{
                    .id = client_request.id,
                    .result = .{
                        .initialize = .{
                            .protocolVersion = 1,
                            .agentCapabilities = null,
                            .agentInfo = null,
                            .authMethods = {},
                        },
                    },
                };
                var json_rpc_writer = JsonRpcWriter.init(arena_allocator, self.output_writer);
                defer json_rpc_writer.deinit();

                try json_rpc_writer.writeJsonObject(reply, .{});
            },
            .session_new => {
                const session_state = self.sessions.createSession(.{
                    self.allocator,
                    self.io,
                    acp_config.provider,
                    acp_config.default_session_config,
                }) catch {
                    try self.sendError(arena_allocator, client_request.id, .internal_error, "Failed to create session");
                    continue;
                };

                const reply: agent_api.AgentResponse = .{
                    .id = client_request.id,
                    .result = .{
                        .session_new = .{
                            .sessionId = session_state.id,
                        },
                    },
                };
                var json_rpc_writer = JsonRpcWriter.init(arena_allocator, self.output_writer);
                defer json_rpc_writer.deinit();

                try json_rpc_writer.writeJsonObject(reply, .{});
            },
            .session_prompt => {
                const session = self.sessions.getSession(client_request.params.session_prompt.sessionId) catch |err| {
                    const code: agent_api.JsonRpcErrorCode = if (err == error.SessionNotFound) .session_not_found else .internal_error;
                    const msg = if (err == error.SessionNotFound) "Session not found" else "Session retrieval error";
                    try self.sendError(arena_allocator, client_request.id, code, msg);
                    continue;
                };
                var json_rpc_writer = JsonRpcWriter.init(arena_allocator, self.output_writer);
                defer json_rpc_writer.deinit();

                var ctx: ServerSessionContext = .{
                    .session_state = session,
                    .json_rpc_writer = &json_rpc_writer,
                    .allocator = arena_allocator,
                };

                _ = session.session.executeTurnStreaming(.{ .prompt = client_request.params.session_prompt.prompt[0].text }, handleTurnUpdate, &ctx) catch {
                    try self.sendError(arena_allocator, client_request.id, .internal_error, "Failed to execute turn");
                    continue;
                };

                const reply: agent_api.AgentResponse = .{
                    .id = client_request.id,
                    .result = .{
                        .session_prompt = .{
                            .stopReason = agent_api.StopReason.end_turn,
                        },
                    },
                };

                try json_rpc_writer.writeJsonObject(reply, .{});
            },
            .unknown => {
                try self.sendError(arena_allocator, client_request.id, .method_not_found, "Method not found");
            },
        }
    }
}

/// Validates basic ACP JSON-RPC request structure (protocol version and request ID presence).
fn checkClientRequestValid(request: client_api.ClientRequest) AcpProtocolError!void {
    if (!std.mem.eql(u8, request.jsonrpc, "2.0")) return AcpProtocolError.InvalidJsonRpcVersion;
    if (request.id == .null) return AcpProtocolError.MissingId;
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
