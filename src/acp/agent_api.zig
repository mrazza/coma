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

    pub fn jsonStringify(self: AgentResponseResult, jw: anytype) !void {
        switch (self) {
            inline else => |payload| {
                try jw.write(payload);
            },
        }
    }
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
