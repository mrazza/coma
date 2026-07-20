const std = @import("std");

pub const Server = @import("Server.zig");

// Keep types internal to the module, but ensure their tests are referenced and run.
const client_api = @import("client_api.zig");
const agent_api = @import("agent_api.zig");
const shared_api = @import("shared_api.zig");
const JsonRpcReader = @import("json_rpc/JsonRpcReader.zig");
const JsonRpcWriter = @import("json_rpc/JsonRpcWriter.zig");
const SessionStorage = @import("SessionStorage.zig");

test {
    _ = Server;
    _ = client_api;
    _ = agent_api;
    _ = shared_api;
    _ = JsonRpcReader;
    _ = JsonRpcWriter;
    _ = SessionStorage;
    std.testing.refAllDecls(@This());
}
