const std = @import("std");
const llm = @import("llm");
const Tool = @import("./Tool.zig");
const types = @import("./types.zig");

const Allocator = std.mem.Allocator;

const Agent = @This();

provider: llm.Provider,
tools: []const Tool,
session_config: llm.types.SessionConfig,
prev_continuation: ?llm.types.StepContinuation,

pub fn deinit(self: *Agent) void {
    if (self.prev_continuation) |*ls| {
        ls.deinit();
        self.prev_continuation = null;
    }
}

pub fn executeTurn(self: *Agent, allocator: Allocator, turn: types.Turn) !types.TurnResult {
    return self.executeTurnInternal(allocator, turn, null, null);
}

pub fn executeTurnStreaming(
    self: *Agent,
    allocator: Allocator,
    turn: types.Turn,
    callback: types.StreamingCallback,
    callback_context: ?*anyopaque,
) !types.TurnResult {
    var agent_streaming_ctx: StreamingContext = .{ .callback = callback, .context = callback_context };
    return self.executeTurnInternal(allocator, turn, &agent_streaming_ctx);
}

const StreamingContext = struct {
    callback: types.StreamingCallback,
    context: ?*anyopaque,
};

fn streamingCallbackProxy(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
    const streaming_ctx: *StreamingContext = @ptrCast(@alignCast(ctx));
    streaming_ctx.callback(streaming_ctx.context, .{ .model_chunk = chunk });
}

fn executeTurnInternal(self: *Agent, allocator: Allocator, turn: types.Turn, callback_context: ?*StreamingContext) !types.TurnResult {
    var next_steps: std.ArrayList(llm.types.Step) = .empty;
    defer next_steps.deinit(allocator);
    try next_steps.append(allocator, .{ .prompt = turn.prompt });

    var intermediate_results: std.ArrayList(types.IntermediateStepResult) = .empty;
    defer {
        // `intermediate_results` will own the memory for all non-final steps; that is, all steps
        // that are model or tool outputs but not the initial user input or final result.
        // These values will, in the event of a non-error, have their ownership transfered to
        // the returned `TurnResult`.
        for (intermediate_results.items) |*ir| {
            ir.deinit();
        }
        intermediate_results.deinit(allocator);
    }

    while (true) {
        const step_outcome = if (callback_context) |cb|
            try self.provider.executeStepStreaming(
                allocator,
                self.session_config,
                next_steps.items,
                self.prev_continuation,
                streamingCallbackProxy,
                cb,
            )
        else
            try self.provider.executeStep(
                allocator,
                self.session_config,
                next_steps.items,
                self.prev_continuation,
            );
        next_steps.clearRetainingCapacity();

        var step_result = step_outcome.result;
        const step_continuation = step_outcome.continuation;

        if (self.prev_continuation) |*old_continuation| old_continuation.deinit();
        self.prev_continuation = step_continuation;

        if (step_result.tool_calls.len > 0) {
            intermediate_results.append(allocator, .{ .step_result = step_result }) catch |err| {
                step_result.deinit();
                return err;
            };
            for (step_result.tool_calls) |tool_call| {
                const tool = for (self.tools) |t| {
                    if (std.mem.eql(u8, t.descriptor.name, tool_call.name)) {
                        break t;
                    }
                } else {
                    return error.ToolNotFound;
                };

                var tool_result = try tool.execute(allocator, tool_call.id, tool_call.arguments);
                intermediate_results.append(allocator, .{ .tool_result = tool_result }) catch |err| {
                    tool_result.deinit();
                    return err;
                };
                try next_steps.append(allocator, .{ .tool_result = tool_result });

                if (callback_context) |cb| {
                    cb.callback(cb.context, .{ .tool_result = tool_result });
                }
            }
        } else {
            return .{
                .allocator = allocator,
                .final_step = step_result,
                .intermediate_steps = try intermediate_results.toOwnedSlice(allocator),
            };
        }
    }
}

const testing_pkg = @import("testing");
threadlocal var test_mock_provider: ?*testing_pkg.MockProvider = null;

test "Agent.executeTurn - no tool calls" {
    const allocator = std.testing.allocator;
    var mock_provider = testing_pkg.MockProvider{};
    const prov = mock_provider.provider();

    const mock_model = llm.types.Model{
        .id = "mock-model",
        .display_name = "Mock Model",
    };

    var agent = Agent{
        .provider = prov,
        .tools = &.{},
        .session_config = .{
            .model = mock_model,
            .tools = &.{},
        },
        .prev_continuation = null,
    };
    defer agent.deinit();

    mock_provider.execute_step_result = llm.types.StepResult{
        .model_output = &.{.{ .text = "Hello user!" }},
        .thoughts = &.{},
        .tool_calls = &.{},
        .ptr = &mock_provider,
        .vtable = &testing_pkg.MockProvider.mock_step_vtable,
    };
    var mock_continuation: testing_pkg.MockProvider.MockStepContinuation = .{};
    mock_provider.execute_step_continuation = mock_continuation.stepContinuation();

    const turn = types.Turn{ .prompt = "Hi agent" };

    var result = try agent.executeTurn(allocator, turn);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_provider.execute_step_calls);
    try std.testing.expect(agent.prev_continuation != null);
    try std.testing.expectEqualStrings("Hello user!", result.final_step.model_output[0].text);
}

test "Agent.executeTurnStreaming - no tool calls" {
    const allocator = std.testing.allocator;
    var mock_provider = testing_pkg.MockProvider{};
    const prov = mock_provider.provider();

    const mock_model = llm.types.Model{
        .id = "mock-model",
        .display_name = "Mock Model",
    };

    var agent = Agent{
        .provider = prov,
        .tools = &.{},
        .session_config = .{
            .model = mock_model,
            .tools = &.{},
        },
        .prev_continuation = null,
    };
    defer agent.deinit();

    mock_provider.execute_step_result = llm.types.StepResult{
        .model_output = &.{.{ .text = "Hello user!" }},
        .thoughts = &.{},
        .tool_calls = &.{},
        .ptr = &mock_provider,
        .vtable = &testing_pkg.MockProvider.mock_step_vtable,
    };
    var mock_continuation: testing_pkg.MockProvider.MockStepContinuation = .{};
    mock_provider.execute_step_continuation = mock_continuation.stepContinuation();

    const turn = types.Turn{ .prompt = "Hi agent" };

    const DummyContext = struct {
        called: bool = false,
    };
    var dummy_ctx = DummyContext{};

    const callback = struct {
        fn cb(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = chunk;
            const c: *DummyContext = @ptrCast(@alignCast(ctx));
            c.called = true;
        }
    }.cb;

    var result = try agent.executeTurnStreaming(allocator, turn, callback, &dummy_ctx);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_provider.execute_step_streaming_calls);
    try std.testing.expectEqual(@as(usize, 0), mock_provider.execute_step_calls);
    try std.testing.expect(agent.prev_continuation != null);
    try std.testing.expectEqualStrings("Hello user!", result.final_step.model_output[0].text);
}

const MockToolImpl = struct {
    pub fn execute(allocator: std.mem.Allocator, val: i64) ![]const u8 {
        if (test_mock_provider) |mp| {
            mp.execute_step_result = llm.types.StepResult{
                .model_output = &.{.{ .text = "Final output after tool" }},
                .thoughts = &.{},
                .tool_calls = &.{},
                .ptr = mp,
                .vtable = &testing_pkg.MockProvider.mock_step_vtable,
            };
        }
        return try std.fmt.allocPrint(allocator, "Tool result for {d}", .{val});
    }
};

test "Agent.executeTurn - executes tool call and runs again" {
    const allocator = std.testing.allocator;
    var mock_provider = testing_pkg.MockProvider{};
    const prov = mock_provider.provider();
    test_mock_provider = &mock_provider;
    defer test_mock_provider = null;

    const tool_desc = llm.types.Tool{
        .name = "mock_tool",
        .description = "A mock tool for testing",
        .parameters = &.{
            .{
                .name = "val",
                .description = "integer value",
                .type = .integer,
                .required = true,
            },
        },
    };

    const tool = Tool.init(tool_desc, MockToolImpl.execute);
    const tools = &[_]Tool{tool};

    const mock_model = llm.types.Model{
        .id = "mock-model",
        .display_name = "Mock Model",
    };

    var agent = Agent{
        .provider = prov,
        .tools = tools,
        .session_config = .{
            .model = mock_model,
            .tools = &.{tool.descriptor},
        },
        .prev_continuation = null,
    };
    defer agent.deinit();

    const args = [_]llm.types.Argument{
        .{ .name = "val", .value = .{ .integer = 42 } },
    };
    const tool_calls = [_]llm.types.ToolCall{
        .{
            .id = "call-id-123",
            .name = "mock_tool",
            .arguments = @constCast(&args),
        },
    };

    mock_provider.execute_step_result = llm.types.StepResult{
        .model_output = &.{},
        .thoughts = &.{},
        .tool_calls = &tool_calls,
        .ptr = &mock_provider,
        .vtable = &testing_pkg.MockProvider.mock_step_vtable,
    };
    mock_provider.execute_step_continuation = llm.types.StepContinuation{
        .ptr = &mock_provider,
        .vtable = &testing_pkg.MockProvider.mock_continuation_vtable,
    };

    const turn = types.Turn{ .prompt = "Hi agent, run mock_tool" };

    var result = try agent.executeTurn(allocator, turn);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), mock_provider.execute_step_calls);
    try std.testing.expect(agent.prev_continuation != null);
    try std.testing.expectEqualStrings("Final output after tool", result.final_step.model_output[0].text);
}
