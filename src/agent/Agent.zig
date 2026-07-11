const std = @import("std");
const llm = @import("llm");
const Tool = @import("./Tool.zig");
const types = @import("./types.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Provider = llm.Provider;
const Future = std.Io.Future;

const Agent = @This();

allocator: Allocator,
io: Io,
provider: Provider,
tools: []const Tool,
session_config: llm.types.SessionConfig,
prev_continuation: ?llm.types.StepContinuation,

const ToolError = error{ToolNotFound} || Tool.CallError;
pub const AgentError = ToolError || Provider.ProviderError;

/// Initializes a new Agent instance.
///
/// `allocator` is used for all internal dynamic memory allocations.
/// `io` is the I/O context to use for operations.
/// `provider` is a Provider interface implementation that determines the LLM provider to use.
/// `tools` is the set of tools available for the agent to execute.
/// `session_config` contains the initial configuration for the LLM session.
pub fn init(allocator: Allocator, io: Io, provider: Provider, tools: []const Tool, session_config: llm.types.SessionConfig) Agent {
    return Agent{
        .allocator = allocator,
        .io = io,
        .provider = provider,
        .tools = tools,
        .session_config = session_config,
        .prev_continuation = null,
    };
}

/// Deinitializes the Agent, releasing any accumulated session history and internal resources.
pub fn deinit(self: *Agent) void {
    if (self.prev_continuation) |*ls| {
        ls.deinit();
        self.prev_continuation = null;
    }
}

/// Executes a single non-streaming turn of the agent.
///
/// The agent sends the turn's prompt to the LLM, handles any tool calls recommended by the model
/// sequentially/concurrently, and returns a `TurnResult` containing the final output and history
/// when the model is finished thinking and using tools.
///
/// `turn` contains the prompt to send to the LLM.
///
/// The caller is responsible for deinitializing the returned `TurnResult` by calling deinit() on it.
pub fn executeTurn(self: *Agent, turn: types.Turn) AgentError!types.TurnResult {
    return self.executeTurnInternal(turn, null);
}

/// Executes a single turn of the agent while streaming progress back via a callback.
///
/// Model chunks and tool results are streamed back via `callback`.
/// Like `executeTurn`, this handles intermediate tool executions, and returns a final `TurnResult`.
///
/// `turn` contains the prompt to send to the LLM.
/// `callback` is called with the `callback_context` whenever a new streaming chunk or tool execution result is available.
/// `callback_context` is arbitrary data to be passed to the callback as a opaque pointer.
///
/// The caller is responsible for deinitializing the returned `TurnResult` by calling deinit() on it.
pub fn executeTurnStreaming(
    self: *Agent,
    turn: types.Turn,
    callback: types.StreamingCallback,
    callback_context: ?*anyopaque,
) AgentError!types.TurnResult {
    var agent_streaming_ctx: StreamingContext = .{ .callback = callback, .context = callback_context };
    return self.executeTurnInternal(turn, &agent_streaming_ctx);
}

const StreamingContext = struct {
    callback: types.StreamingCallback,
    context: ?*anyopaque,
};

fn streamingCallbackProxy(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
    const streaming_ctx: *StreamingContext = @ptrCast(@alignCast(ctx));
    streaming_ctx.callback(streaming_ctx.context, .{ .model_chunk = chunk });
}

fn executeToolCall(self: *Agent, tool_call: llm.types.ToolCall) ToolError!llm.types.ToolResult {
    const tool = for (self.tools) |t| {
        if (std.mem.eql(u8, t.descriptor.name, tool_call.name)) {
            break t;
        }
    } else {
        return ToolError.ToolNotFound;
    };

    return try tool.execute(self.allocator, self.io, tool_call.id, tool_call.arguments);
}

fn executeTurnInternal(self: *Agent, turn: types.Turn, callback_context: ?*StreamingContext) AgentError!types.TurnResult {
    var next_steps: std.ArrayList(llm.types.Step) = .empty;
    const allocator = self.allocator;
    const io = self.io;
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

            const SingleToolResult = union(enum) { result: ToolError!llm.types.ToolResult };
            const tool_futures_buf: []SingleToolResult = try allocator.alloc(SingleToolResult, step_result.tool_calls.len);
            defer allocator.free(tool_futures_buf);
            var tool_futures = Io.Select(SingleToolResult).init(io, tool_futures_buf);
            defer while (tool_futures.cancel()) |tool_result| {
                var curr_result = tool_result;
                if (curr_result.result) |*tr| {
                    tr.deinit();
                } else |_| {}
            };
            for (step_result.tool_calls) |tool_call| {
                tool_futures.async(.result, executeToolCall, .{ self, tool_call });
            }
            for (0..step_result.tool_calls.len) |_| {
                const tool_result_wrapper = tool_futures.await() catch |err| switch (err) {
                    error.Canceled => unreachable,
                };
                var tool_result = try tool_result_wrapper.result;

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

const testing = @import("testing");

const MockToolImpl = struct {
    pub fn execute(allocator: std.mem.Allocator, val: i64) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "Tool result for {d}", .{val});
    }
};

test "Agent.executeTurn - no tool calls" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock_provider = testing.MockProvider{};
    const prov = mock_provider.provider();

    const mock_model = llm.types.Model{
        .id = "mock-model",
        .display_name = "Mock Model",
    };

    var agent = Agent{
        .allocator = allocator,
        .io = io,
        .provider = prov,
        .tools = &.{},
        .session_config = .{
            .model = mock_model,
            .tools = &.{},
        },
        .prev_continuation = null,
    };
    defer agent.deinit();

    const step_result = testing.MockProvider.stepResult(&.{.{ .text = "Hello user!" }}, &.{}, &.{});
    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        .{ .result = step_result, .continuation = testing.MockProvider.stepContinuation() },
    };
    mock_provider.execute_step_results = &outcomes;

    const turn = types.Turn{ .prompt = "Hi agent" };

    var result = try agent.executeTurn(turn);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_provider.execute_step_calls);
    try std.testing.expect(agent.prev_continuation != null);
    try std.testing.expectEqualStrings("Hello user!", result.final_step.model_output[0].text);
}

test "Agent.executeTurnStreaming - no tool calls" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock_provider = testing.MockProvider{};
    const prov = mock_provider.provider();

    const mock_model = llm.types.Model{
        .id = "mock-model",
        .display_name = "Mock Model",
    };

    var agent: Agent = .init(
        allocator,
        io,
        prov,
        &.{},
        .{
            .model = mock_model,
            .tools = &.{},
        },
    );
    defer agent.deinit();

    const step_result = testing.MockProvider.stepResult(&.{.{ .text = "Hello user!" }}, &.{}, &.{});
    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        .{ .result = step_result, .continuation = testing.MockProvider.stepContinuation() },
    };
    mock_provider.execute_step_results = &outcomes;

    const turn = types.Turn{ .prompt = "Hi agent" };

    const DummyContext = struct {
        called: bool = false,
    };
    var dummy_ctx = DummyContext{};

    const callback = struct {
        fn cb(ctx: ?*anyopaque, chunk: types.StreamingChunk) void {
            _ = chunk;
            const c: *DummyContext = @ptrCast(@alignCast(ctx));
            c.called = true;
        }
    }.cb;

    var result = try agent.executeTurnStreaming(turn, callback, &dummy_ctx);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_provider.execute_step_streaming_calls);
    try std.testing.expectEqual(@as(usize, 0), mock_provider.execute_step_calls);
    try std.testing.expect(agent.prev_continuation != null);
    try std.testing.expectEqualStrings("Hello user!", result.final_step.model_output[0].text);
}

test "Agent.executeTurn - executes tool call and runs again" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock_provider = testing.MockProvider{};
    const prov = mock_provider.provider();

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

    var agent: Agent = .init(
        allocator,
        io,
        prov,
        tools,
        .{
            .model = mock_model,
            .tools = &.{tool.descriptor},
        },
    );
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

    const result1 = testing.MockProvider.stepResult(&.{}, &.{}, &tool_calls);
    const continuation1 = testing.MockProvider.stepContinuation();

    const final_outputs = [_]llm.types.ModelOutput{
        .{ .text = "Final output after tool" },
    };
    const result2 = testing.MockProvider.stepResult(&final_outputs, &.{}, &.{});
    const continuation2 = testing.MockProvider.stepContinuation();

    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        llm.types.StepOutcome{ .result = result1, .continuation = continuation1 },
        llm.types.StepOutcome{ .result = result2, .continuation = continuation2 },
    };
    mock_provider.execute_step_results = &outcomes;


    const turn = types.Turn{ .prompt = "Hi agent, run mock_tool" };

    var result = try agent.executeTurn(turn);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), mock_provider.execute_step_calls);
    try std.testing.expect(agent.prev_continuation != null);
    try std.testing.expectEqualStrings("Final output after tool", result.final_step.model_output[0].text);
}

test "Agent.executeTurnStreaming - model chunks streaming" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock_provider = testing.MockProvider{};
    const prov = mock_provider.provider();

    var agent = Agent.init(
        allocator,
        io,
        prov,
        &.{},
        .{
            .model = .{ .id = "mock-model", .display_name = "Mock Model" },
            .tools = &.{},
        },
    );
    defer agent.deinit();

    const chunk1 = llm.types.StreamingChunk{
        .event = .{
            .step_event = .{
                .index = 0,
                .event = .{
                    .delta = .{
                        .model_output = .{ .text = "Hello " },
                    },
                },
            },
        },
    };
    const chunk2 = llm.types.StreamingChunk{
        .event = .{
            .step_event = .{
                .index = 0,
                .event = .{
                    .delta = .{
                        .model_output = .{ .text = "world!" },
                    },
                },
            },
        },
    };

    const chunks = [_]llm.types.StreamingChunk{ chunk1, chunk2 };
    const chunks_list = [_][]const llm.types.StreamingChunk{ &chunks };
    mock_provider.execute_step_streaming_chunks = &chunks_list;

    const step_result = testing.MockProvider.stepResult(&.{.{ .text = "Hello world!" }}, &.{}, &.{});
    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        .{ .result = step_result, .continuation = testing.MockProvider.stepContinuation() },
    };
    mock_provider.execute_step_results = &outcomes;

    const CallbackState = struct {
        const Self = @This();
        chunks: std.ArrayList(types.StreamingChunk) = .empty,
        allocator: std.mem.Allocator,

        fn init(alloc: std.mem.Allocator) Self {
            return .{ .allocator = alloc };
        }

        fn deinit(self: *Self) void {
            self.chunks.deinit(self.allocator);
        }

        fn cb(ctx: ?*anyopaque, chunk: types.StreamingChunk) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.chunks.append(self.allocator, chunk) catch {};
        }
    };

    var cb_state = CallbackState.init(allocator);
    defer cb_state.deinit();

    const turn = types.Turn{ .prompt = "Hi agent" };
    var result = try agent.executeTurnStreaming(turn, CallbackState.cb, &cb_state);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), cb_state.chunks.items.len);
    try std.testing.expectEqualStrings("Hello ", cb_state.chunks.items[0].model_chunk.event.step_event.event.delta.model_output.text);
    try std.testing.expectEqualStrings("world!", cb_state.chunks.items[1].model_chunk.event.step_event.event.delta.model_output.text);
    try std.testing.expectEqualStrings("Hello world!", result.final_step.model_output[0].text);
}

test "Agent.executeTurnStreaming - with tool calls" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var mock_provider = testing.MockProvider{};
    const prov = mock_provider.provider();

    const args_buf = [_]llm.types.Argument{
        .{ .name = "val", .value = .{ .integer = 42 } },
    };
    const tool_calls_buf = [_]llm.types.ToolCall{
        .{
            .id = "call-id-123",
            .name = "mock_tool",
            .arguments = @constCast(&args_buf),
        },
    };

    const step_result1 = testing.MockProvider.stepResult(&.{}, &.{}, &tool_calls_buf);
    const step_result2 = testing.MockProvider.stepResult(&.{.{ .text = "Tool executed!" }}, &.{}, &.{});
    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        .{ .result = step_result1, .continuation = testing.MockProvider.stepContinuation() },
        .{ .result = step_result2, .continuation = testing.MockProvider.stepContinuation() },
    };
    mock_provider.execute_step_results = &outcomes;

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

    var agent = Agent.init(
        allocator,
        io,
        prov,
        tools,
        .{
            .model = .{ .id = "mock-model", .display_name = "Mock Model" },
            .tools = &.{tool_desc},
        },
    );
    defer agent.deinit();

    const CallbackState = struct {
        const Self = @This();
        chunks: std.ArrayList(types.StreamingChunk) = .empty,
        allocator: std.mem.Allocator,

        fn init(alloc: std.mem.Allocator) Self {
            return .{ .allocator = alloc };
        }

        fn deinit(self: *Self) void {
            self.chunks.deinit(self.allocator);
        }

        fn cb(ctx: ?*anyopaque, chunk: types.StreamingChunk) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.chunks.append(self.allocator, chunk) catch {};
        }
    };

    var cb_state = CallbackState.init(allocator);
    defer cb_state.deinit();

    const turn = types.Turn{ .prompt = "Hi agent" };
    var result = try agent.executeTurnStreaming(turn, CallbackState.cb, &cb_state);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), cb_state.chunks.items.len);
    try std.testing.expect(cb_state.chunks.items[0] == .tool_result);
    try std.testing.expectEqualStrings("mock_tool", cb_state.chunks.items[0].tool_result.tool_name);
    try std.testing.expectEqualStrings("call-id-123", cb_state.chunks.items[0].tool_result.id);
    try std.testing.expectEqualStrings("Tool result for 42", cb_state.chunks.items[0].tool_result.result);
}

test "Agent.executeToolCall - tool not found" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock_provider = testing.MockProvider{};
    const prov = mock_provider.provider();

    var agent = Agent.init(
        allocator,
        io,
        prov,
        &.{},
        .{
            .model = .{ .id = "mock-model", .display_name = "Mock Model" },
            .tools = &.{},
        },
    );
    defer agent.deinit();

    const tool_call = llm.types.ToolCall{
        .id = "call-id",
        .name = "non_existent_tool",
        .arguments = &.{},
    };

    try std.testing.expectError(error.ToolNotFound, agent.executeToolCall(tool_call));
}

test "Agent.executeTurn - tool call error cleanup" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var mock_provider = testing.MockProvider{};
    const prov = mock_provider.provider();

    const tool_desc = llm.types.Tool{
        .name = "error_tool",
        .description = "A tool that returns error",
        .parameters = &.{},
    };
    const error_tool_impl = struct {
        fn execute(alloc: Allocator) ![]const u8 {
            _ = alloc;
            return error.ArgumentTypeMismatch;
        }
    };
    const tool = Tool.init(tool_desc, error_tool_impl.execute);
    const tools = &[_]Tool{tool};

    var agent = Agent.init(
        allocator,
        io,
        prov,
        tools,
        .{
            .model = .{ .id = "mock-model", .display_name = "Mock Model" },
            .tools = &.{tool_desc},
        },
    );
    defer agent.deinit();

    const tool_calls = [_]llm.types.ToolCall{
        .{
            .id = "call-id-123",
            .name = "error_tool",
            .arguments = &.{},
        },
    };
    const step_result = testing.MockProvider.stepResult(&.{}, &.{}, &tool_calls);
    const step_continuation = testing.MockProvider.stepContinuation();
    const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
        .{ .result = step_result, .continuation = step_continuation },
    };
    mock_provider.execute_step_results = &outcomes;


    const turn = types.Turn{ .prompt = "Run error_tool" };
    try std.testing.expectError(error.ArgumentTypeMismatch, agent.executeTurn(turn));
}
