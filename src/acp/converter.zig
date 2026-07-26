//! Methods to convert between internal COMA data types and ACP API types.

const std = @import("std");
const agent = @import("agent");
const llm = @import("llm");
const agent_api = @import("agent_api.zig");
const shared_api = @import("shared_api.zig");

const Allocator = std.mem.Allocator;

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
fn agentMessageChunk(session_id: shared_api.SessionId, model_output: llm.types.ModelOutput) agent_api.AgentNotification {
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
fn agentThoughtChunk(session_id: shared_api.SessionId, thought: llm.types.Thought) agent_api.AgentNotification {
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

/// Constructs an `AgentNotification` for a tool call update chunk.
///
/// - `allocator`: Allocator used to JSON-serialize the tool call arguments into `rawInput`.
/// - `session_id`: The ID of the active session receiving the update.
/// - `tool_call_delta`: The tool call delta payload containing tool ID, name, and arguments.
fn agentToolCallUpdate(allocator: Allocator, session_id: shared_api.SessionId, tool_call_delta: llm.types.ToolCallDelta) !agent_api.AgentNotification {
    var write_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer write_buffer.deinit();
    var stringifier = std.json.Stringify{
        .writer = &write_buffer.writer,
        .options = .{},
    };
    try stringifier.write(tool_call_delta.arguments);
    return .{
        .method = .session_update,
        .params = .{
            .session_update = .{
                .sessionId = session_id,
                .update = .{
                    .tool_call_update = .{
                        .toolCallId = tool_call_delta.id,
                        .title = tool_call_delta.name,
                        .name = tool_call_delta.name,
                        .status = .in_progress,
                        .rawInput = try write_buffer.toOwnedSlice(),
                        .rawOutput = null,
                    },
                },
            },
        },
    };
}

/// Constructs an `AgentNotification` for a tool execution result update.
///
/// - `session_id`: The ID of the active session receiving the update.
/// - `tool_result`: The tool result payload containing tool ID, name, and result string.
fn agentToolResult(session_id: shared_api.SessionId, tool_result: llm.types.ToolResult) agent_api.AgentNotification {
    return .{
        .method = .session_update,
        .params = .{
            .session_update = .{
                .sessionId = session_id,
                .update = .{
                    .tool_call_update = .{
                        .toolCallId = tool_result.id,
                        .title = tool_result.tool_name,
                        .name = tool_result.tool_name,
                        .status = .completed,
                        .rawInput = null,
                        .rawOutput = tool_result.result,
                    },
                },
            },
        },
    };
}

/// Converts a `StreamingChunk` into an optional `AgentNotification`.
///
/// - `allocator`: Allocator to use when producing this chunk.
/// - `session_id`: The ID of the active session receiving the update.
/// - `chunk`: The streaming chunk from the agent layer to convert.
pub fn streamingChunkToNotification(allocator: Allocator, session_id: shared_api.SessionId, chunk: agent.types.StreamingChunk) !?agent_api.AgentNotification {
    switch (chunk) {
        .model_chunk => {
            const delta = extractDelta(chunk) orelse return null;
            return switch (delta) {
                .model_output => |model_output| agentMessageChunk(session_id, model_output),
                .thought => |thought| agentThoughtChunk(session_id, thought),
                .tool_call => |tool_call| try agentToolCallUpdate(allocator, session_id, tool_call),
            };
        },
        .tool_result => |tool_result| {
            return agentToolResult(session_id, tool_result);
        },
    }
}

test "extractDelta extracts model output, thought, and tool call deltas" {
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

    const chunk_tool_call = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .{
                .step_event = .{
                    .index = 0,
                    .event = .{
                        .delta = .{
                            .tool_call = .{
                                .id = "call-1",
                                .name = "read_file",
                                .arguments = &.{},
                            },
                        },
                    },
                },
            },
        },
    };
    const delta_tool_call = extractDelta(chunk_tool_call);
    try std.testing.expect(delta_tool_call != null);
    try std.testing.expectEqualStrings("call-1", delta_tool_call.?.tool_call.id);
    try std.testing.expectEqualStrings("read_file", delta_tool_call.?.tool_call.name);

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

test "agentToolCallUpdate and agentToolResult build expected notifications" {
    const session_id: shared_api.SessionId = "session-42";
    const allocator = std.testing.allocator;

    const tool_call_notif = try agentToolCallUpdate(allocator, session_id, .{
        .id = "tc-1",
        .name = "list_dir",
        .arguments = &.{},
    });
    defer allocator.free(tool_call_notif.params.session_update.update.tool_call_update.rawInput.?);

    try std.testing.expectEqual(agent_api.AgentNotificationMethod.session_update, tool_call_notif.method);
    try std.testing.expectEqualStrings(session_id, tool_call_notif.params.session_update.sessionId);

    const tc_update = tool_call_notif.params.session_update.update.tool_call_update;
    try std.testing.expectEqualStrings("tc-1", tc_update.toolCallId);
    try std.testing.expectEqualStrings("list_dir", tc_update.name.?);
    try std.testing.expectEqual(agent_api.ToolCallStatus.in_progress, tc_update.status.?);
    try std.testing.expectEqualStrings("[]", tc_update.rawInput.?);
    try std.testing.expect(tc_update.rawOutput == null);

    const tool_result_notif = agentToolResult(session_id, .{
        .id = "tc-1",
        .tool_name = "list_dir",
        .result = "file1.txt\nfile2.txt",
        .allocator = allocator,
    });
    const tr_update = tool_result_notif.params.session_update.update.tool_call_update;
    try std.testing.expectEqualStrings("tc-1", tr_update.toolCallId);
    try std.testing.expectEqualStrings("list_dir", tr_update.name.?);
    try std.testing.expectEqual(agent_api.ToolCallStatus.completed, tr_update.status.?);
    try std.testing.expect(tr_update.rawInput == null);
    try std.testing.expectEqualStrings("file1.txt\nfile2.txt", tr_update.rawOutput.?);
}

test "streamingChunkToNotification converts streaming chunks correctly" {
    const session_id: shared_api.SessionId = "session-100";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 1. Model output chunk
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

    const notif_msg = try streamingChunkToNotification(arena.allocator(), session_id, chunk_msg);
    try std.testing.expect(notif_msg != null);
    try std.testing.expectEqualStrings("hello notification", notif_msg.?.params.session_update.update.agent_message_chunk.content.text);

    // 2. Thought chunk
    const chunk_thought = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .{
                .step_event = .{
                    .index = 0,
                    .event = .{
                        .delta = .{
                            .thought = .{ .text = "deep thought" },
                        },
                    },
                },
            },
        },
    };

    const notif_thought = try streamingChunkToNotification(arena.allocator(), session_id, chunk_thought);
    try std.testing.expect(notif_thought != null);
    try std.testing.expectEqualStrings("deep thought", notif_thought.?.params.session_update.update.agent_thought_chunk.content.text);

    // 3. Tool call chunk
    const chunk_tool_call = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .{
                .step_event = .{
                    .index = 0,
                    .event = .{
                        .delta = .{
                            .tool_call = .{
                                .id = "tc-99",
                                .name = "grep_search",
                                .arguments = &.{},
                            },
                        },
                    },
                },
            },
        },
    };

    const notif_tc = try streamingChunkToNotification(arena.allocator(), session_id, chunk_tool_call);
    try std.testing.expect(notif_tc != null);
    try std.testing.expectEqualStrings("tc-99", notif_tc.?.params.session_update.update.tool_call_update.toolCallId);
    try std.testing.expectEqual(agent_api.ToolCallStatus.in_progress, notif_tc.?.params.session_update.update.tool_call_update.status.?);

    // 4. Tool result chunk
    const chunk_tool_result = agent.types.StreamingChunk{
        .tool_result = .{
            .id = "tc-99",
            .tool_name = "grep_search",
            .result = "match found",
            .allocator = arena.allocator(),
        },
    };

    const notif_tr = try streamingChunkToNotification(arena.allocator(), session_id, chunk_tool_result);
    try std.testing.expect(notif_tr != null);
    try std.testing.expectEqualStrings("tc-99", notif_tr.?.params.session_update.update.tool_call_update.toolCallId);
    try std.testing.expectEqual(agent_api.ToolCallStatus.completed, notif_tr.?.params.session_update.update.tool_call_update.status.?);
    try std.testing.expectEqualStrings("match found", notif_tr.?.params.session_update.update.tool_call_update.rawOutput.?);

    // 5. Non-delta event returns null
    const chunk_other = agent.types.StreamingChunk{
        .model_chunk = .{
            .event = .interaction_created,
        },
    };
    try std.testing.expectEqual(null, try streamingChunkToNotification(arena.allocator(), session_id, chunk_other));
}
