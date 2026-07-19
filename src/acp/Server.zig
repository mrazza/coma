const std = @import("std");
const agent_api = @import("agent_api.zig");
const client_api = @import("client_api.zig");
const JsonRpcReader = @import("json_rpc/JsonRpcReader.zig");
const JsonRpcWriter = @import("json_rpc/JsonRpcWriter.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const AcpProtocolError = error{
    InvalidJsonRpcVersion,
    MissingId,
} || std.json.Error;

const Server = @This();

input_reader: *Io.Reader,
output_writer: *Io.Writer,

pub fn init(input_reader: *Io.Reader, output_writer: *Io.Writer) Server {
    return .{
        .input_reader = input_reader,
        .output_writer = output_writer,
    };
}

pub fn deinit(_: *Server) void {}

pub fn run(self: *Server, allocator: Allocator, io: Io) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    while (true) {
        try io.checkCancel();
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
                    .result = .{ .initialize = .{
                        .protocolVersion = 1,
                        .agentCapabilities = null,
                        .agentInfo = null,
                        .authMethods = {},
                    } },
                };
                var json_rpc_writer = JsonRpcWriter.init(arena_allocator, self.output_writer);
                defer json_rpc_writer.deinit();

                try json_rpc_writer.writeJsonObject(reply, .{ .use_headers = false });
            },
            .session_new => {
                std.debug.print("Got session_new request: {any}\n", .{client_request});
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
