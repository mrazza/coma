const std = @import("std");
const agent = @import("agent");
const llm = @import("llm");
const agent_api = @import("agent_api.zig");
const shared_api = @import("shared_api.zig");

/// Extracts the `Delta` payload from a `StreamingChunk` if it is a step delta event.
///
/// - `chunk`: The streaming chunk from the agent layer.
pub fn extractDelta(chunk: agent.types.StreamingChunk) ?llm.types.Delta {
    if (chunk != .model_chunk) return null;
    if (chunk.model_chunk.event != .step_event) return null;
    if (chunk.model_chunk.event.step_event.event != .delta) return null;
    return chunk.model_chunk.event.step_event.event.delta;
}

/// Converts a `ModelOutput` into a `ContentChunk`.
///
/// - `model_output`: The model output payload containing generated text.
pub fn modelOutputToContentChunk(model_output: llm.types.ModelOutput) agent_api.ContentChunk {
    return .{
        .content = .{ .text = model_output.text },
    };
}

/// Converts a `Thought` into a `ContentChunk`.
///
/// - `thought`: The thought payload containing reasoning text.
pub fn thoughtToContentChunk(thought: llm.types.Thought) agent_api.ContentChunk {
    return .{
        .content = .{ .text = thought.text },
    };
}

/// Constructs an `AgentNotification` for an agent message chunk update.
///
/// - `session_id`: The ID of the active session receiving the update.
/// - `model_output`: The model output payload to include in the message chunk notification.
pub fn agentMessageChunk(session_id: shared_api.SessionId, model_output: llm.types.ModelOutput) agent_api.AgentNotification {
    return .{
        .method = .session_update,
        .params = .{
            .session_update = .{
                .sessionId = session_id,
                .update = .{
                    .agent_message_chunk = modelOutputToContentChunk(model_output),
                },
            },
        },
    };
}

/// Constructs an `AgentNotification` for an agent thought chunk update.
///
/// - `session_id`: The ID of the active session receiving the update.
/// - `thought`: The thought payload to include in the thought chunk notification.
pub fn agentThoughtChunk(session_id: shared_api.SessionId, thought: llm.types.Thought) agent_api.AgentNotification {
    return .{
        .method = .session_update,
        .params = .{
            .session_update = .{
                .sessionId = session_id,
                .update = .{
                    .agent_thought_chunk = thoughtToContentChunk(thought),
                },
            },
        },
    };
}

/// Converts a `StreamingChunk` into an optional `AgentNotification`.
///
/// - `session_id`: The ID of the active session receiving the update.
/// - `chunk`: The streaming chunk from the agent layer to convert.
pub fn streamingChunkToNotification(session_id: shared_api.SessionId, chunk: agent.types.StreamingChunk) ?agent_api.AgentNotification {
    const delta = extractDelta(chunk) orelse return null;
    return switch (delta) {
        .model_output => |model_output| agentMessageChunk(session_id, model_output),
        .thought => |thought| agentThoughtChunk(session_id, thought),
        else => null,
    };
}

test "extractDelta extracts model output and thought deltas" {
    const chunk_output = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .{
                .step_event = .{
                    .index = 0,
                    .event = .{
                        .delta = .{
                            .model_output = .{ .text = "hello" },
                        },
                    },
                },
            },
        },
    };
    const delta_output = extractDelta(chunk_output);
    try std.testing.expect(delta_output != null);
    try std.testing.expectEqualStrings("hello", delta_output.?.model_output.text);

    const chunk_thought = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .{
                .step_event = .{
                    .index = 0,
                    .event = .{
                        .delta = .{
                            .thought = .{ .text = "thinking" },
                        },
                    },
                },
            },
        },
    };
    const delta_thought = extractDelta(chunk_thought);
    try std.testing.expect(delta_thought != null);
    try std.testing.expectEqualStrings("thinking", delta_thought.?.thought.text);

    const chunk_other = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .interaction_created,
        },
    };
    try std.testing.expectEqual(@as(?llm.types.Delta, null), extractDelta(chunk_other));
}

test "modelOutputToContentChunk and thoughtToContentChunk" {
    const content_output = modelOutputToContentChunk(.{ .text = "test output" });
    try std.testing.expectEqualStrings("test output", content_output.content.text);

    const content_thought = thoughtToContentChunk(.{ .text = "test thought" });
    try std.testing.expectEqualStrings("test thought", content_thought.content.text);
}

test "agentMessageChunk and agentThoughtChunk build expected notifications" {
    const session_id: shared_api.SessionId = "session-42";

    const msg_notif = agentMessageChunk(session_id, .{ .text = "message delta" });
    try std.testing.expectEqual(agent_api.AgentNotificationMethod.session_update, msg_notif.method);
    try std.testing.expectEqualStrings(session_id, msg_notif.params.session_update.sessionId);
    try std.testing.expectEqualStrings("message delta", msg_notif.params.session_update.update.agent_message_chunk.content.text);

    const thought_notif = agentThoughtChunk(session_id, .{ .text = "thought delta" });
    try std.testing.expectEqual(agent_api.AgentNotificationMethod.session_update, thought_notif.method);
    try std.testing.expectEqualStrings(session_id, thought_notif.params.session_update.sessionId);
    try std.testing.expectEqualStrings("thought delta", thought_notif.params.session_update.update.agent_thought_chunk.content.text);
}

test "streamingChunkToNotification converts streaming chunks correctly" {
    const session_id: shared_api.SessionId = "session-100";

    const chunk_msg = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .{
                .step_event = .{
                    .index = 0,
                    .event = .{
                        .delta = .{
                            .model_output = .{ .text = "hello notification" },
                        },
                    },
                },
            },
        },
    };

    const notif_msg = streamingChunkToNotification(session_id, chunk_msg);
    try std.testing.expect(notif_msg != null);
    try std.testing.expectEqualStrings("hello notification", notif_msg.?.params.session_update.update.agent_message_chunk.content.text);

    const chunk_other = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .interaction_created,
        },
    };
    try std.testing.expectEqual(@as(?agent_api.AgentNotification, null), streamingChunkToNotification(session_id, chunk_other));
}
