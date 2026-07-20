const std = @import("std");
const agent = @import("agent");
const agent_api = @import("agent_api.zig");
const client_api = @import("client_api.zig");
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
    server: *Server,
    session_state: *SessionStorage.SessionState,
    json_rpc_writer: *JsonRpcWriter,
};

const Server = @This();

allocator: Allocator,
io: Io,
input_reader: *Io.Reader,
output_writer: *Io.Writer,
sessions: SessionStorage,
acp_config: Config,

pub fn init(allocator: Allocator, io: Io, input_reader: *Io.Reader, output_writer: *Io.Writer, acp_config: Config) Server {
    return .{
        .allocator = allocator,
        .io = io,
        .input_reader = input_reader,
        .output_writer = output_writer,
        .sessions = .init(allocator),
        .acp_config = acp_config,
    };
}

pub fn deinit(self: *Server) void {
    self.sessions.deinit();
}

fn handleTurnUpdate(ctx: ?*anyopaque, chunk: agent.types.StreamingChunk) void {
    const stream_ctx: *ServerSessionContext = @ptrCast(@alignCast(ctx));
    const session_state = stream_ctx.session_state;
    const json_rpc_writer = stream_ctx.json_rpc_writer;

    switch (chunk) {
        .model_chunk => |model_chunk| {
            switch (model_chunk.event) {
                .step_event => |step| {
                    switch (step.event) {
                        .delta => |delta| {
                            switch (delta) {
                                .model_output => |mo| {
                                    const output_reply: agent_api.AgentNotification = .{
                                        .method = .session_update,
                                        .params = .{
                                            .session_update = .{
                                                .sessionId = session_state.id,
                                                .update = .{
                                                    .agent_message_chunk = .{
                                                        .content = .{
                                                            .text = mo.text,
                                                        },
                                                    },
                                                },
                                            },
                                        },
                                    };

                                    json_rpc_writer.writeJsonObject(output_reply, .{ .use_headers = false }) catch {};
                                },
                                .thought => |thought| {
                                    const thinking_reply: agent_api.AgentNotification = .{
                                        .method = .session_update,
                                        .params = .{
                                            .session_update = .{
                                                .sessionId = session_state.id,
                                                .update = .{
                                                    .agent_thought_chunk = .{
                                                        .content = .{
                                                            .text = thought.text,
                                                        },
                                                    },
                                                },
                                            },
                                        },
                                    };

                                    json_rpc_writer.writeJsonObject(thinking_reply, .{ .use_headers = false }) catch {};
                                },
                                else => {},
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

pub fn run(self: *Server) !void {
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
                std.debug.print("Got init: {any}", .{client_request});

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

                try json_rpc_writer.writeJsonObject(reply, .{ .use_headers = false });
            },
            .session_new => {
                std.debug.print("Got session_new request: {any}\n", .{client_request});

                const session_state = try self.sessions.createSession(.{
                    self.allocator,
                    self.io,
                    self.acp_config.provider,
                    self.acp_config.default_session_config,
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

                try json_rpc_writer.writeJsonObject(reply, .{ .use_headers = false });
            },
            .session_prompt => {
                std.debug.print("Got session_prompt request: {any}\n", .{client_request.params.session_prompt.prompt});

                const session = try self.sessions.getSession(client_request.params.session_prompt.sessionId);
                var json_rpc_writer = JsonRpcWriter.init(arena_allocator, self.output_writer);
                defer json_rpc_writer.deinit();

                var ctx: ServerSessionContext = .{
                    .server = self,
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

                try json_rpc_writer.writeJsonObject(reply, .{ .use_headers = false });
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
