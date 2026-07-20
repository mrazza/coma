const std = @import("std");
const shared_api = @import("shared_api.zig");

/// A JSON-RPC response sent by the agent to the client.
pub const AgentResponse = struct {
    /// The ID of the request this response answers.
    id: shared_api.RequestId,
    /// Method-specific response data.
    result: AgentResponseResult,
};

/// Union of all possible response data types.
///
/// The filled member is dependent on the method type the agent is responding to.
pub const AgentResponseResult = union(enum) {
    initialize: InitializeResponse,
    session_new: NewSessionResponse,

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


