const std = @import("std");
const shared_api = @import("shared_api.zig");

const Allocator = std.mem.Allocator;

/// Valid types of request methods that can be invoked by a client.
pub const RequestMethod = enum {
    /// Initialize method used to negotiate protocol version and capabilities.
    ///
    /// Before a Session can be created or any other methods can be called,
    /// Clients MUST initialize the connection by calling this method.
    initialize,
    /// New Session method (mapped to "session/new") used to create a new session.
    session_new,
    /// The request method is not recognized.
    unknown,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !RequestMethod {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(_: Allocator, source: std.json.Value, _: std.json.ParseOptions) !RequestMethod {
        return shared_api.parseEnumWithMappedFallback(RequestMethod, .unknown, source);
    }
};

/// A JSON-RPC request sent by the client to the agent.
///
/// See protocol docs: [Requests](https://agentclientprotocol.com/protocol/overview)
pub const ClientRequest = struct {
    /// The JSON-RPC protocol version.
    jsonrpc: []const u8,
    /// The request id used to correlate the matching response.
    id: shared_api.RequestId,
    /// The method to be invoked.
    method: RequestMethod,
    /// The parameters for the method invocation.
    params: ClientRequestParams,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !ClientRequest {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: Allocator, source: std.json.Value, options: std.json.ParseOptions) !ClientRequest {
        if (source != .object) return error.UnexpectedToken;
        const jsonrpc = try std.json.innerParseFromValue([]const u8, allocator, source.object.get("jsonrpc") orelse return error.MissingField, options);
        const id = try std.json.innerParseFromValue(shared_api.RequestId, allocator, source.object.get("id") orelse return error.MissingField, options);
        const method = try std.json.innerParseFromValue(RequestMethod, allocator, source.object.get("method") orelse return error.MissingField, options);
        const params: ClientRequestParams = switch (method) {
            .initialize => .{ .initialize = try std.json.innerParseFromValue(InitializeRequest, allocator, source.object.get("params") orelse return error.MissingField, options) },
            .session_new => .{ .session_new = {} },
            .unknown => .{ .unknown = {} },
        };
        return ClientRequest{
            .jsonrpc = jsonrpc,
            .id = id,
            .method = method,
            .params = params,
        };
    }
};

/// Union of all possible request parameters.
///
/// The filled member is dependent on the method type.
pub const ClientRequestParams = union(RequestMethod) {
    initialize: InitializeRequest,
    session_new: void,
    unknown,
};

/// Request parameters for the initialize method.
///
/// Sent by the client to establish a connection and negotiate capabilities.
///
/// See protocol docs: [Initialization](https://agentclientprotocol.com/protocol/initialization)
pub const InitializeRequest = struct {
    /// The latest protocol version supported by the client.
    protocolVersion: shared_api.ProtocolVersion,
    /// Capabilities supported by the client.
    clientCapabilities: ?ClientCapabilities = null,
    /// Information about the Client name and version sent to the Agent.
    /// Note: in future versions of the protocol, this will be required.
    clientInfo: ?shared_api.Implementation = null,
};

/// Describes capabilities supported by the client.
///
/// See protocol docs: [Client Capabilities](https://agentclientprotocol.com/protocol/initialization#client-capabilities)
pub const ClientCapabilities = struct {
    /// File system capabilities supported by the client.
    ///
    /// Determines which file operations the agent can request from
    /// the client.
    fs: ?FileSystemCapabilities = null,

    /// Whether the client supports all `terminal*` methods.
    terminal: bool = false,

    /// Session-related capabilities supported by the client.
    ///
    /// Optional. Omitted or `null` both mean the client does not advertise any
    /// session-related extensions.
    session: ?ClientSessionCapabilities = null,
};

/// File system capabilities that a client may support.
///
/// See protocol docs: [FileSystem](https://agentclientprotocol.com/protocol/initialization#filesystem)
pub const FileSystemCapabilities = struct {
    /// Whether the Client supports `fs/read_text_file` requests.
    readTextFile: bool = false,
    /// Whether the Client supports `fs/write_text_file` requests.
    writeTextFile: bool = false,
};

/// Session-related capabilities supported by the client.
pub const ClientSessionCapabilities = struct {
    /// Config option capabilities supported by the client.
    ///
    /// Omitted or `null` both mean the client does not advertise support for any
    /// config option extensions.
    configOptions: ?SessionConfigOptionsCapabilities = null,
};

/// Session configuration option capabilities supported by the client.
pub const SessionConfigOptionsCapabilities = struct {
    /// Whether the client supports boolean session configuration options.
    ///
    /// Optional. Omitted or `null` both mean the client does not advertise support.
    /// Supplying `{}` means agents may include `type: "boolean"` entries in
    /// `configOptions`, and the client may send `session/set_config_option`
    /// requests with `type: "boolean"` and a boolean `value`.
    boolean: bool = false,
};

test "json parse initialize ClientRequest" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 42,
        \\  "method": "initialize",
        \\  "params": {
        \\    "protocolVersion": 1,
        \\    "clientCapabilities": {
        \\      "fs": {
        \\        "readTextFile": true,
        \\        "writeTextFile": false
        \\      },
        \\      "terminal": true
        \\    },
        \\    "clientInfo": {
        \\      "name": "test-client",
        \\      "version": "1.0.0"
        \\    }
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(ClientRequest, allocator, json_str, .{});
    defer parsed.deinit();

    const request = parsed.value;
    try std.testing.expectEqualStrings("2.0", request.jsonrpc);
    try std.testing.expectEqual(RequestMethod.initialize, request.method);
    try std.testing.expectEqual(shared_api.RequestId{ .integer = 42 }, request.id);

    const init_params = request.params.initialize;
    try std.testing.expectEqual(@as(shared_api.ProtocolVersion, 1), init_params.protocolVersion);

    const capabilities = init_params.clientCapabilities.?;
    try std.testing.expect(capabilities.terminal);
    const fs = capabilities.fs.?;
    try std.testing.expect(fs.readTextFile);
    try std.testing.expect(!fs.writeTextFile);

    const client_info = init_params.clientInfo.?;
    try std.testing.expectEqualStrings("test-client", client_info.name);
    try std.testing.expectEqualStrings("1.0.0", client_info.version);
    try std.testing.expect(client_info.title == null);
}

test "json parse RequestMethod mapping" {
    const allocator = std.testing.allocator;

    {
        const parsed = try std.json.parseFromSlice(RequestMethod, allocator, "\"initialize\"", .{});
        defer parsed.deinit();
        try std.testing.expectEqual(RequestMethod.initialize, parsed.value);
    }

    {
        const parsed = try std.json.parseFromSlice(RequestMethod, allocator, "\"session/new\"", .{});
        defer parsed.deinit();
        try std.testing.expectEqual(RequestMethod.session_new, parsed.value);
    }

    {
        const parsed = try std.json.parseFromSlice(RequestMethod, allocator, "\"some/unknown/method\"", .{});
        defer parsed.deinit();
        try std.testing.expectEqual(RequestMethod.unknown, parsed.value);
    }
}
