const std = @import("std");

pub const Server = @import("Server.zig");
pub const tools = struct {
    pub const Todo = @import("tool/todo.zig").Tool;
};

// Keep types internal to the module, but ensure their tests are referenced and run.
const client_api = @import("client_api.zig");
const agent_api = @import("agent_api.zig");
const shared_api = @import("shared_api.zig");
const converter = @import("converter.zig");
const JsonRpcReader = @import("json_rpc/JsonRpcReader.zig");
const JsonRpcWriter = @import("json_rpc/JsonRpcWriter.zig");
const SessionStorage = @import("SessionStorage.zig");

test {
    _ = Server;
    _ = client_api;
    _ = agent_api;
    _ = shared_api;
    _ = converter;
    _ = JsonRpcReader;
    _ = JsonRpcWriter;
    _ = SessionStorage;
    _ = @import("tool/todo.zig");
    std.testing.refAllDecls(@This());
}
