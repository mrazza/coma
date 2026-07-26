//! Agent tool for managing and injecting persistent TODO content into session context.

const std = @import("std");
const llm = @import("llm");
const agent = @import("../root.zig");
const SessionState = @import("../SessionState.zig");

/// `write_todo` tool for creating, updating, or clearing the persistent TODO list.
pub const Tool = agent.Tool.init(.{
    .name = "write_todo",
    .description =
    \\Overwrite the entire TODO content.
    \\
    \\The content persists across conversation turns and compaction and
    \\is injected frequently into the context window. Use this for:
    \\  - Task tracking and progress updates
    \\  - Important notes and reminders
    \\
    \\Writing an empty string clears the entire todo list.
    \\
    \\WARNING: This operation completely replaces the existing content.
    \\Always include all content you want to keep, not just the changes.
    ,
    .parameters = &.{
        .{
            .name = "content",
            .description = "The todo list in markdown format. To clear the todo list, pass an empty string.",
            .type = .string,
            .required = true,
        },
    },
}, execute);

/// Executes the tool call to set or clear the session's injected TODO context.
fn execute(allocator: std.mem.Allocator, ctx: agent.ToolCallContext, content: []const u8) ![]const u8 {
    if (content.len == 0) {
        ctx.clearInjectedContext();
        return try allocator.dupe(u8, "Todo list cleared.");
    } else {
        try ctx.setInjectedContext(content);
        return try allocator.dupe(u8, "Todo list updated.");
    }
}

test "Todo tool descriptor metadata" {
    try std.testing.expectEqualStrings("write_todo", Tool.descriptor.name);
    try std.testing.expectEqual(1, Tool.descriptor.parameters.len);
    try std.testing.expectEqualStrings("content", Tool.descriptor.parameters[0].name);
    try std.testing.expectEqual(llm.types.Tool.Param.Type.string, Tool.descriptor.parameters[0].type);
    try std.testing.expect(Tool.descriptor.parameters[0].required);
}

test "Todo tool update content" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const args: []const llm.types.Argument = &.{
        .{
            .name = "content",
            .value = .{ .string = "- [ ] Write tests\n- [ ] Run tests" },
        },
    };

    var result = try Tool.execute(testing_allocator, io, &session_state, "call_1", args);
    defer result.deinit();

    try std.testing.expectEqualStrings("write_todo", result.tool_name);
    try std.testing.expectEqualStrings("call_1", result.id);
    try std.testing.expectEqualStrings("Todo list updated.", result.result);

    const injected = session_state.getInjectedContext(&Tool);
    try std.testing.expect(injected != null);
    try std.testing.expectEqualStrings("- [ ] Write tests\n- [ ] Run tests", injected.?);
}

test "Todo tool clear content with empty string" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    // First update the todo list
    const update_args: []const llm.types.Argument = &.{
        .{
            .name = "content",
            .value = .{ .string = "- [ ] Task to clear" },
        },
    };
    var update_res = try Tool.execute(testing_allocator, io, &session_state, "call_1", update_args);
    update_res.deinit();

    try std.testing.expectEqualStrings("- [ ] Task to clear", session_state.getInjectedContext(&Tool).?);

    // Now clear it
    const clear_args: []const llm.types.Argument = &.{
        .{
            .name = "content",
            .value = .{ .string = "" },
        },
    };
    var clear_res = try Tool.execute(testing_allocator, io, &session_state, "call_2", clear_args);
    defer clear_res.deinit();

    try std.testing.expectEqualStrings("Todo list cleared.", clear_res.result);
    try std.testing.expectEqual(null, session_state.getInjectedContext(&Tool));
}

test "Todo tool overwrite existing content" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const args1: []const llm.types.Argument = &.{
        .{
            .name = "content",
            .value = .{ .string = "Initial todo list" },
        },
    };
    var res1 = try Tool.execute(testing_allocator, io, &session_state, "call_1", args1);
    res1.deinit();

    try std.testing.expectEqualStrings("Initial todo list", session_state.getInjectedContext(&Tool).?);

    const args2: []const llm.types.Argument = &.{
        .{
            .name = "content",
            .value = .{ .string = "Overwritten todo list" },
        },
    };
    var res2 = try Tool.execute(testing_allocator, io, &session_state, "call_2", args2);
    defer res2.deinit();

    try std.testing.expectEqualStrings("Todo list updated.", res2.result);
    try std.testing.expectEqualStrings("Overwritten todo list", session_state.getInjectedContext(&Tool).?);
}

test "Todo tool missing required argument" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const empty_args: []const llm.types.Argument = &.{};
    try std.testing.expectError(agent.Tool.CallError.RequiredArgumentMissing, Tool.execute(testing_allocator, io, &session_state, "call_1", empty_args));
}
