const std = @import("std");
const agent = @import("agent");
const llm = @import("llm");
const agent_api = @import("agent_api.zig");
const client_api = @import("client_api.zig");
const converter = @import("converter.zig");
const JsonRpcReader = @import("json_rpc/JsonRpcReader.zig");
const JsonRpcWriter = @import("json_rpc/JsonRpcWriter.zig");
const SessionStorage = @import("SessionStorage.zig");
pub const Config = @import("Config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const AcpProtocolError = error{
    InvalidJsonRpcVersion,
    MissingId,
} || std.json.Error;

const ServerSessionContext = struct {
    session_state: *SessionStorage.SessionState,
    json_rpc_writer: *JsonRpcWriter,
};

const Server = @This();

allocator: Allocator,
io: Io,
input_reader: *Io.Reader,
output_writer: *Io.Writer,
sessions: SessionStorage,

pub fn init(allocator: Allocator, io: Io, input_reader: *Io.Reader, output_writer: *Io.Writer) Server {
    return .{
        .allocator = allocator,
        .io = io,
        .input_reader = input_reader,
        .output_writer = output_writer,
        .sessions = .init(allocator),
    };
}

pub fn deinit(self: *Server) void {
    self.sessions.deinit();
}

fn handleTurnUpdate(ctx: ?*anyopaque, chunk: agent.types.StreamingChunk) void {
    const stream_ctx: *ServerSessionContext = @ptrCast(@alignCast(ctx));
    const notification = converter.streamingChunkToNotification(stream_ctx.session_state.id, chunk) orelse return;
    stream_ctx.json_rpc_writer.writeJsonObject(notification, .{ .use_headers = false }) catch {};
}

pub fn run(self: *Server, acp_config: Config) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    while (true) {
        try self.io.checkCancel();
        _ = arena.reset(.retain_capacity);

        var json_rpc_reader = JsonRpcReader.init(arena_allocator, self.input_reader);
        defer json_rpc_reader.deinit();

        const client_request = (try json_rpc_reader.readJsonObject(client_api.ClientRequest)).value;
        try checkClientRequestValid(client_request);

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
                const session_state = try self.sessions.createSession(.{
                    self.allocator,
                    self.io,
                    acp_config.provider,
                    acp_config.default_session_config,
                });

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
                const session = try self.sessions.getSession(client_request.params.session_prompt.sessionId);
                var json_rpc_writer = JsonRpcWriter.init(arena_allocator, self.output_writer);
                defer json_rpc_writer.deinit();

                var ctx: ServerSessionContext = .{
                    .session_state = session,
                    .json_rpc_writer = &json_rpc_writer,
                };

                _ = try session.session.executeTurnStreaming(.{ .prompt = client_request.params.session_prompt.prompt[0].text }, handleTurnUpdate, &ctx);

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
                std.debug.print("Unknown message: {any}\n", .{client_request});
            },
        }
    }
}

fn checkClientRequestValid(request: client_api.ClientRequest) AcpProtocolError!void {
    if (!std.mem.eql(u8, request.jsonrpc, "2.0")) return AcpProtocolError.InvalidJsonRpcVersion;
    if (request.id == .null) return AcpProtocolError.MissingId;
}
