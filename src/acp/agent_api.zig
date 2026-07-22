const std = @import("std");
const shared_api = @import("shared_api.zig");

/// A JSON-RPC response sent by the agent to the client.
pub const AgentResponse = struct {
    /// The ID of the request this response answers.
    id: shared_api.RequestId,
    /// Method-specific response data.
    result: AgentResponseResult,
};

/// JSON-RPC 2.0 error codes used in agent error responses.
///
/// See https://www.jsonrpc.org/specification#error_object
pub const JsonRpcErrorCode = enum(i32) {
    /// Invalid JSON was received by the server. An error occurred on the server while parsing the JSON text.
    parse_error = -32700,
    /// The JSON sent is not a valid Request object.
    invalid_request = -32600,
    /// The method does not exist / is not available.
    method_not_found = -32601,
    /// Invalid method parameter(s).
    invalid_params = -32602,
    /// Internal JSON-RPC error.
    internal_error = -32603,
    /// The requested session ID was not found.
    session_not_found = -32001,

    pub fn jsonStringify(self: JsonRpcErrorCode, jw: anytype) !void {
        try jw.write(@intFromEnum(self));
    }
};

/// Represents a JSON-RPC 2.0 error payload.
///
/// See https://www.jsonrpc.org/specification#error_object
pub const JsonRpcError = struct {
    /// Error code indicating the error type that occurred.
    code: JsonRpcErrorCode,
    /// A short description of the error.
    message: []const u8,
};

/// A JSON-RPC error response sent by the agent to the client.
///
/// See https://www.jsonrpc.org/specification#error_object
pub const AgentErrorResponse = struct {
    /// JSON-RPC protocol version string (always "2.0").
    jsonrpc: []const u8 = "2.0",
    /// The ID of the request this error response answers (or null if parsing failed).
    id: shared_api.RequestId,
    /// Error payload describing the failure.
    @"error": JsonRpcError,
};

/// Union of all possible response data types.
///
/// The filled member is dependent on the method type the agent is responding to.
pub const AgentResponseResult = union(enum) {
    initialize: InitializeResponse,
    session_new: NewSessionResponse,
    session_prompt: PromptResponse,

    pub fn jsonStringify(self: AgentResponseResult, jw: anytype) !void {
        switch (self) {
            inline else => |payload| {
                try jw.write(payload);
            },
        }
    }
};

/// Response from creating a new session.
///
/// See protocol docs: [Creating a Session](https://agentclientprotocol.com/protocol/session-setup#creating-a-session)
pub const NewSessionResponse = struct {
    /// Unique identifier for the created session.
    ///
    /// Used in all subsequent requests for this conversation.
    sessionId: shared_api.SessionId,
};

/// Response to the `initialize` method.
///
/// Contains the negotiated protocol version and agent capabilities.
///
/// See protocol docs: [Initialization](https://agentclientprotocol.com/protocol/initialization)
pub const InitializeResponse = struct {
    /// The protocol version the client specified if supported by the agent,
    /// or the latest protocol version supported by the agent.
    ///
    /// The client should disconnect if it does not support this version.
    protocolVersion: shared_api.ProtocolVersion,
    /// Capabilities supported by the agent.
    agentCapabilities: ?AgentCapabilities,
    /// Authentication methods supported by the agent.
    ///
    /// This is currently not implemented.
    authMethods: void,
    /// Information about the Agent name and version sent to the client.
    agentInfo: ?shared_api.Implementation,
};

/// Capabilities supported by the agent.
///
/// These are advertised during initialization to inform the client about
/// available features and content types.
///
/// See protocol docs: [Agent Capabilities](https://agentclientprotocol.com/protocol/initialization#agent-capabilities)
pub const AgentCapabilities = struct {
    /// Whether the agent supports `session/load`.
    loadSession: ?bool,
    /// Prompt capabilities supported by the agent.
    promptCapabilities: ?PromptCapabilities,
    /// MCP capabilities supported by the agent.
    mcpCapabilities: ?McpCapabilities,
    /// Session lifecycle and prompt capabilities advertised by the agent.
    sessionCapabilities: ?SessionCapabilities,
    /// Authentication-related capabilities supported by the agent.
    auth: ?AgentAuthCapabilities,
};

/// Prompt capabilities supported by the agent in `session/prompt` requests.
///
/// Baseline agent functionality requires support for [`ContentBlock::Text`]
/// and [`ContentBlock::ResourceLink`] in prompt requests.
///
/// Other variants must be explicitly opted in to.
/// Capabilities for different types of content in prompt requests.
///
/// Indicates which content types beyond the baseline (text and resource links)
/// the agent can process.
///
/// See protocol docs: [Prompt Capabilities](https://agentclientprotocol.com/protocol/initialization#prompt-capabilities)
pub const PromptCapabilities = struct {
    /// Whether the agent supports `ContentBlock::Image` in prompt requests.
    image: ?bool,
    /// Whether the agent supports `ContentBlock::Audio` in prompt requests.
    audio: ?bool,
    /// Whether the agent supports embedded context in`session/prompt` requests.
    ///
    /// When enabled, the Client is allowed to include [`ContentBlock::Resource`]
    /// in prompt requests for pieces of content that are referenced in the message.
    embeddedContext: ?bool,
};

/// MCP capabilities supported by the agent.
pub const McpCapabilities = struct {
    /// Whether the agent supports MCP HTTP servers.
    http: ?bool,
    /// Whether the agent supports MCP SSE servers.
    sse: ?bool,
};

/// Session capabilities supported by the agent.
///
/// As a baseline, all Agents **MUST** support `session/new`, `session/prompt`, `session/cancel`, and `session/update`.
///
/// Optionally, they **MAY** support other session methods and notifications by specifying additional capabilities.
///
/// Note: `session/load` is still handled by the top-level `load_session` capability. This will be unified in future versions of the protocol.
///
/// See protocol docs: [Session Capabilities](https://agentclientprotocol.com/protocol/initialization#session-capabilities)
pub const SessionCapabilities = struct {};

/// Authentication-related capabilities supported by the agent.
pub const AgentAuthCapabilities = struct {};

pub const StopReason = enum {
    end_turn,
    max_tokens,
    max_turn_requests,
    refusal,
    cancelled,
};

pub const PromptResponse = struct {
    stopReason: StopReason,
};

/// Possible set of notification methods.
pub const AgentNotificationMethod = enum {
    session_update,

    pub fn jsonStringify(self: AgentNotificationMethod, jw: anytype) !void {
        try jw.write(shared_api.stringifyEnum(self));
    }
};

/// A JSON-RPC notification object.
pub const AgentNotification = struct {
    /// The notification method name.
    method: AgentNotificationMethod,
    /// Method-specific notification parameters.
    params: AgentNotificationParams,
};

/// Union for method-specific notification parameters; split by method type.
pub const AgentNotificationParams = union(AgentNotificationMethod) {
    session_update: SessionNotificationParams,

    pub fn jsonStringify(self: AgentNotificationParams, jw: anytype) !void {
        switch (self) {
            inline else => |payload| {
                try jw.write(payload);
            },
        }
    }
};

/// Notification containing a session update from the agent.
///
/// Used to stream real-time progress and results during prompt processing.
///
/// See protocol docs: [Agent Reports Output](https://agentclientprotocol.com/protocol/prompt-turn#3-agent-reports-output)
pub const SessionNotificationParams = struct {
    /// The ID of the session that is receiving an update.
    sessionId: shared_api.SessionId,
    /// The update to send to the session
    update: SessionUpdate,
};

/// Different types of updates that can be sent during session processing.
///
/// These updates provide real-time feedback about the agent's progress.
///
/// See protocol docs: [Agent Reports Output](https://agentclientprotocol.com/protocol/prompt-turn#3-agent-reports-output)
pub const SessionUpdate = union(enum) {
    /// Agent message output chunk.
    agent_message_chunk: ContentChunk,
    /// Agent thinking chunk.
    agent_thought_chunk: ContentChunk,

    pub fn jsonStringify(self: SessionUpdate, jw: anytype) !void {
        switch (self) {
            inline else => |payload| {
                try jw.beginObject();
                try jw.objectField("sessionUpdate");
                try jw.write(@tagName(self));
                try shared_api.jsonStringifyFields(payload, jw);
                try jw.endObject();
            },
        }
    }
};

/// A streamed item of content.
pub const ContentChunk = struct {
    content: shared_api.ContentBlock,

    // TODO(razza): Do we need messageId?
};

/// Serializes a value into a newly allocated JSON string.
///
/// Caller owns the returned slice and must free it using `allocator`.
/// Note: This helper is provided for unit tests to verify JSON output.
fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var stringifier = std.json.Stringify{
        .writer = &buffer.writer,
        .options = .{},
    };
    try stringifier.write(value);
    return allocator.dupe(u8, buffer.written());
}

test "json stringify AgentResponse initialize" {
    const allocator = std.testing.allocator;

    const response: AgentResponse = .{
        .id = .{ .integer = 1 },
        .result = .{
            .initialize = .{
                .protocolVersion = 1,
                .agentCapabilities = .{
                    .loadSession = true,
                    .promptCapabilities = .{
                        .image = true,
                        .audio = false,
                        .embeddedContext = true,
                    },
                    .mcpCapabilities = .{
                        .http = true,
                        .sse = false,
                    },
                    .sessionCapabilities = .{},
                    .auth = null,
                },
                .authMethods = {},
                .agentInfo = .{
                    .name = "coma",
                    .title = "Coma ACP Agent",
                    .version = "0.1.0",
                },
            },
        },
    };

    const json_str = try stringify(allocator, response);
    defer allocator.free(json_str);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, 1), result.get("protocolVersion").?.integer);

    const agent_info = result.get("agentInfo").?.object;
    try std.testing.expectEqualStrings("coma", agent_info.get("name").?.string);
    try std.testing.expectEqualStrings("Coma ACP Agent", agent_info.get("title").?.string);
    try std.testing.expectEqualStrings("0.1.0", agent_info.get("version").?.string);

    const caps = result.get("agentCapabilities").?.object;
    try std.testing.expect(caps.get("loadSession").?.bool);

    const prompt_caps = caps.get("promptCapabilities").?.object;
    try std.testing.expect(prompt_caps.get("image").?.bool);
    try std.testing.expect(!prompt_caps.get("audio").?.bool);
    try std.testing.expect(prompt_caps.get("embeddedContext").?.bool);

    const mcp_caps = caps.get("mcpCapabilities").?.object;
    try std.testing.expect(mcp_caps.get("http").?.bool);
    try std.testing.expect(!mcp_caps.get("sse").?.bool);
}

test "json stringify AgentResponse session_new" {
    const allocator = std.testing.allocator;

    const response: AgentResponse = .{
        .id = .{ .string = "req-123" },
        .result = .{
            .session_new = .{
                .sessionId = "sess-456",
            },
        },
    };

    const json_str = try stringify(allocator, response);
    defer allocator.free(json_str);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("req-123", parsed.value.object.get("id").?.string);

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("sess-456", result.get("sessionId").?.string);
}

test "json stringify InitializeResponse optional fields" {
    const allocator = std.testing.allocator;

    const response: AgentResponse = .{
        .id = .{ .integer = 42 },
        .result = .{
            .initialize = .{
                .protocolVersion = 1,
                .agentCapabilities = null,
                .authMethods = {},
                .agentInfo = null,
            },
        },
    };

    const json_str = try stringify(allocator, response);
    defer allocator.free(json_str);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("id").?.integer);

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(@as(i64, 1), result.get("protocolVersion").?.integer);
    try std.testing.expect(result.get("agentCapabilities").? == .null);
    try std.testing.expect(result.get("agentInfo").? == .null);
}

test "json stringify AgentCapabilities minimal vs full" {
    const allocator = std.testing.allocator;

    // Minimal capabilities (all optionals null)
    {
        const min_caps: AgentCapabilities = .{
            .loadSession = null,
            .promptCapabilities = null,
            .mcpCapabilities = null,
            .sessionCapabilities = null,
            .auth = null,
        };

        const json_str = try stringify(allocator, min_caps);
        defer allocator.free(json_str);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        try std.testing.expect(parsed.value.object.get("loadSession").? == .null);
        try std.testing.expect(parsed.value.object.get("promptCapabilities").? == .null);
        try std.testing.expect(parsed.value.object.get("mcpCapabilities").? == .null);
    }

    // Full capabilities
    {
        const full_caps: AgentCapabilities = .{
            .loadSession = true,
            .promptCapabilities = .{
                .image = true,
                .audio = null,
                .embeddedContext = false,
            },
            .mcpCapabilities = .{
                .http = false,
                .sse = true,
            },
            .sessionCapabilities = .{},
            .auth = .{},
        };

        const json_str = try stringify(allocator, full_caps);
        defer allocator.free(json_str);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        try std.testing.expect(parsed.value.object.get("loadSession").?.bool);

        const prompt_caps = parsed.value.object.get("promptCapabilities").?.object;
        try std.testing.expect(prompt_caps.get("image").?.bool);
        try std.testing.expect(prompt_caps.get("audio").? == .null);
        try std.testing.expect(!prompt_caps.get("embeddedContext").?.bool);

        const mcp_caps = parsed.value.object.get("mcpCapabilities").?.object;
        try std.testing.expect(!mcp_caps.get("http").?.bool);
        try std.testing.expect(mcp_caps.get("sse").?.bool);
    }
}

test "json stringify AgentResponse session_prompt" {
    const allocator = std.testing.allocator;

    const response: AgentResponse = .{
        .id = .{ .integer = 10 },
        .result = .{
            .session_prompt = .{
                .stopReason = .end_turn,
            },
        },
    };

    const json_str = try stringify(allocator, response);
    defer allocator.free(json_str);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 10), parsed.value.object.get("id").?.integer);

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("end_turn", result.get("stopReason").?.string);
}

test "json stringify AgentNotification session_update message chunk" {
    const allocator = std.testing.allocator;

    const notification: AgentNotification = .{
        .method = .session_update,
        .params = .{
            .session_update = .{
                .sessionId = "sess-789",
                .update = .{
                    .agent_message_chunk = .{
                        .content = .{
                            .text = "Hello world chunk",
                        },
                    },
                },
            },
        },
    };

    const json_str = try stringify(allocator, notification);
    defer allocator.free(json_str);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("session/update", parsed.value.object.get("method").?.string);

    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("sess-789", params.get("sessionId").?.string);

    const update = params.get("update").?.object;
    try std.testing.expectEqualStrings("agent_message_chunk", update.get("sessionUpdate").?.string);

    const content = update.get("content").?.object;
    try std.testing.expectEqualStrings("text", content.get("type").?.string);
    try std.testing.expectEqualStrings("Hello world chunk", content.get("text").?.string);
}

test "json stringify AgentNotification session_update thought chunk" {
    const allocator = std.testing.allocator;

    const notification: AgentNotification = .{
        .method = .session_update,
        .params = .{
            .session_update = .{
                .sessionId = "sess-789",
                .update = .{
                    .agent_thought_chunk = .{
                        .content = .{
                            .text = "Thinking...",
                        },
                    },
                },
            },
        },
    };

    const json_str = try stringify(allocator, notification);
    defer allocator.free(json_str);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("session/update", parsed.value.object.get("method").?.string);

    const params = parsed.value.object.get("params").?.object;
    const update = params.get("update").?.object;
    try std.testing.expectEqualStrings("agent_thought_chunk", update.get("sessionUpdate").?.string);

    const content = update.get("content").?.object;
    try std.testing.expectEqualStrings("Thinking...", content.get("text").?.string);
}
