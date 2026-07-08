const std = @import("std");
const llm = @import("llm");
const Tool = @import("./Tool.zig");
const types = @import("./types.zig");

const Agent = @This();

provider: llm.Provider,
tools: []const Tool,
session_config: llm.types.SessionConfig,
last_step: ?llm.types.StepContinuation,

pub fn deinit(self: *Agent) void {
    if (self.last_step) |*ls| {
        ls.deinit();
        self.last_step = null;
    }
}

pub fn executeTurn(self: *Agent, allocator: std.mem.Allocator, turn: types.Turn) !types.TurnResult {
    var first_iter = true;
    var final_step: ?llm.types.StepResult = null;
    const initial_step = llm.types.Step{ .prompt = turn.prompt };
    const current_input = &[_]llm.types.Step{initial_step};

    var tool_results: std.ArrayList(llm.types.ToolResult) = .empty;
    defer {
        for (tool_results.items) |*tr| {
            tr.deinit();
        }
        tool_results.deinit(allocator);
    }

    var tool_steps: std.ArrayList(llm.types.Step) = .empty;
    defer tool_steps.deinit(allocator);

    while (true) {
        var outcome = try self.provider.executeStep(
            allocator,
            self.session_config,
            if (first_iter) current_input else tool_steps.items,
            self.last_step,
        );
        errdefer outcome.result.deinit();
        errdefer outcome.continuation.deinit();

        const step_result = outcome.result;
        const step_continuation = outcome.continuation;

        if (!first_iter) {
            for (tool_results.items) |*tr| {
                tr.deinit();
            }
            tool_results.clearRetainingCapacity();
            tool_steps.clearRetainingCapacity();
        }
        first_iter = false;

        if (step_result.tool_calls.len == 0) {
            if (self.last_step) |*ls| {
                ls.deinit();
            }
            final_step = step_result;
            self.last_step = step_continuation;
            break;
        }

        for (step_result.tool_calls) |tool_call| {
            const tool = for (self.tools) |t| {
                if (std.mem.eql(u8, t.descriptor.name, tool_call.name)) {
                    break t;
                }
            } else {
                return error.ToolNotFound;
            };

            var tr = try tool.execute(allocator, tool_call.id, tool_call.arguments);
            tool_results.append(allocator, tr) catch |err| {
                tr.deinit();
                return err;
            };
            try tool_steps.append(allocator, .{ .tool_result = tr });
        }

        if (self.last_step) |*ls| {
            ls.deinit();
        }
        self.last_step = step_continuation;
    }
    return types.TurnResult{ .allocator = allocator, .final_step = final_step.?, .intermediate_steps = &.{} };
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
        .last_step = null,
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
    try std.testing.expect(agent.last_step != null);
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
        .last_step = null,
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
    try std.testing.expect(agent.last_step != null);
    try std.testing.expectEqualStrings("Final output after tool", result.final_step.model_output[0].text);
}
