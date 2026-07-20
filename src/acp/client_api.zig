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
            .session_new => .{ .session_new = try std.json.innerParseFromValue(NewSessionRequest, allocator, source.object.get("params") orelse return error.MissingField, options) },
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
    session_new: NewSessionRequest,
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

/// Request parameters for creating a new session.
///
/// See protocol docs: [Session Setup](https://agentclientprotocol.com/protocol/session-setup#creating-a-session)
pub const NewSessionRequest = struct {
    /// The working directory for this session. Must be an absolute path.
    cwd: []const u8,
    /// Additional workspace roots for this session. Each path must be absolute.
    ///
    /// These expand the session's filesystem scope without changing `cwd`, which
    /// remains the base for relative paths. When omitted or empty, no
    /// additional roots are activated for the new session.
    additionalDirectories: ?[][]const u8 = null,
    /// List of MCP (Model Context Protocol) servers the agent should connect to.
    mcpServers: []McpServer,
};

/// MCP server transport types.
pub const McpServerTypes = enum {
    /// HTTP-based MCP server.
    http,
    /// Server-Sent Events (SSE) based MCP server.
    sse,
    /// ACP-based MCP server.
    acp,
    /// Stdio-based MCP server (default).
    stdio,
};

/// Configuration for connecting to an MCP (Model Context Protocol) server.
///
/// MCP servers provide tools and context that the agent can use when
/// processing prompts.
///
/// The default MCP Server type is `stdio`.
///
/// See protocol docs: [MCP Servers](https://agentclientprotocol.com/protocol/session-setup#mcp-servers)
pub const McpServer = union(McpServerTypes) {
    /// HTTP-based MCP server.
    http: void,
    /// Server-Sent Events (SSE) based MCP server.
    sse: void,
    /// ACP-based MCP server.
    acp: void,
    /// Stdio-based MCP server (default).
    stdio: McpServerStdio,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !McpServer {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: Allocator, source: std.json.Value, options: std.json.ParseOptions) !McpServer {
        if (source != .object) return error.UnexpectedToken;
        const server_type = if (source.object.get("type")) |type_val|
            try std.json.innerParseFromValue(McpServerTypes, allocator, type_val, options)
        else
            McpServerTypes.stdio;
        var stdio_options = options;
        stdio_options.ignore_unknown_fields = true;
        return switch (server_type) {
            .http => .{ .http = {} },
            .sse => .{ .sse = {} },
            .acp => .{ .acp = {} },
            .stdio => .{ .stdio = try std.json.innerParseFromValue(McpServerStdio, allocator, source, stdio_options) },
        };
    }
};

/// Stdio transport configuration for an MCP server.
pub const McpServerStdio = struct {
    /// Human-readable name identifying this MCP server.
    name: []const u8,
    /// Absolute path to the MCP server executable.
    command: []const u8,
    /// Command-line arguments to pass to the MCP server.
    args: [][]const u8,
    /// Environment variables to set when launching the MCP server.
    env: []EnvVariable,
};

/// An environment variable to set when launching an MCP server.
pub const EnvVariable = struct {
    /// The name of the environment variable.
    name: []const u8,
    /// The value of the environment variable.
    value: []const u8,
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

test "json parse McpServer stdio" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{
        \\  "name": "filesystem",
        \\  "command": "/path/to/mcp-server",
        \\  "args": ["--stdio"],
        \\  "env": []
        \\}
    ;

    const parsed = try std.json.parseFromSlice(McpServer, allocator, json_str, .{});
    defer parsed.deinit();

    const server = parsed.value;
    try std.testing.expectEqual(McpServerTypes.stdio, @as(McpServerTypes, server));
    try std.testing.expectEqualStrings("filesystem", server.stdio.name);
    try std.testing.expectEqualStrings("/path/to/mcp-server", server.stdio.command);
    try std.testing.expectEqual(1, server.stdio.args.len);
    try std.testing.expectEqualStrings("--stdio", server.stdio.args[0]);
    try std.testing.expectEqual(0, server.stdio.env.len);
}

test "json parse McpServer http" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{
        \\  "type": "http"
        \\}
    ;

    const parsed = try std.json.parseFromSlice(McpServer, allocator, json_str, .{});
    defer parsed.deinit();

    const server = parsed.value;
    try std.testing.expectEqual(McpServerTypes.http, @as(McpServerTypes, server));
}

test "json parse session/new ClientRequest with McpServer" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "session/new",
        \\  "params": {
        \\    "cwd": "/home/user/project",
        \\    "mcpServers": [
        \\      {
        \\        "name": "filesystem",
        \\        "command": "/path/to/mcp-server",
        \\        "args": ["--stdio"],
        \\        "env": []
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(ClientRequest, allocator, json_str, .{});
    defer parsed.deinit();

    const request = parsed.value;
    try std.testing.expectEqualStrings("2.0", request.jsonrpc);
    try std.testing.expectEqual(RequestMethod.session_new, request.method);
    try std.testing.expectEqual(shared_api.RequestId{ .integer = 1 }, request.id);

    const session_params = request.params.session_new;
    try std.testing.expectEqualStrings("/home/user/project", session_params.cwd);
    try std.testing.expectEqual(1, session_params.mcpServers.len);

    const mcp_server = session_params.mcpServers[0];
    try std.testing.expectEqual(McpServerTypes.stdio, @as(McpServerTypes, mcp_server));
    try std.testing.expectEqualStrings("filesystem", mcp_server.stdio.name);
    try std.testing.expectEqualStrings("/path/to/mcp-server", mcp_server.stdio.command);
    try std.testing.expectEqual(1, mcp_server.stdio.args.len);
    try std.testing.expectEqualStrings("--stdio", mcp_server.stdio.args[0]);
    try std.testing.expectEqual(0, mcp_server.stdio.env.len);
}
