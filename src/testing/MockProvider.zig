const std = @import("std");
const Allocator = std.mem.Allocator;
const llm = @import("llm");
const Provider = llm.Provider;
const types = llm.types;

const ListModelsResult = types.ListModelsResult;
const StepResult = types.StepResult;
const StepContinuation = types.StepContinuation;
const SessionConfig = types.SessionConfig;
const Step = types.Step;
const StepOutcome = types.StepOutcome;

/// A mock implementation of the `llm.Provider` interface for testing.
const MockProvider = @This();

/// Tracks the number of times `listModels` was called.
list_models_calls: usize = 0,
/// Tracks the number of times `executeStep` was called.
execute_step_calls: usize = 0,
/// Tracks the number of times `executeStepStreaming` was called.
execute_step_streaming_calls: usize = 0,
/// Tracks the number of times `deinit` was called.
deinit_calls: usize = 0,

/// Stores the allocator used in the last method call.
last_allocator: ?Allocator = null,
/// Stores the session configuration from the last `executeStep` call.
last_session_config: ?SessionConfig = null,
/// Stores the input steps from the last `executeStep` call.
last_input: ?[]const Step = null,
/// Stores the previous step from the last `executeStep` call.
last_previous_step: ?StepContinuation = null,

/// Optional fixed result to return from `listModels`.
list_models_result: ?(Provider.ProviderError!ListModelsResult) = null,
/// Optional sequence of results/outcomes to return from successive `executeStep` or `executeStepStreaming` calls.
execute_step_results: ?[]const (Provider.ProviderError!StepOutcome) = null,
/// Whether to loop back to the start of execute_step_results when more calls are made than outcomes available.
execute_step_results_loop: bool = true,
/// Optional sequence of streaming chunks to emit during successive `executeStepStreaming` calls.
execute_step_streaming_chunks: ?[]const []const types.StreamingChunk = null,


const vtable = Provider.VTable{
    .list_models = MockProvider.list_models,
    .execute_step = MockProvider.execute_step,
    .execute_step_streaming = MockProvider.execute_step_streaming,
    .deinit = MockProvider.deinit,
};

/// Returns the generic `llm.Provider` interface for this mock instance.
pub fn provider(self: *MockProvider) Provider {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

/// A dummy virtual table for `ListModelsResult` used by the mock.
pub const mock_list_models_vtable = ListModelsResult.VTable{
    .deinit = dummyDeinit,
};

/// A dummy virtual table for `StepResult` used by the mock.
pub const mock_step_vtable = StepResult.VTable{
    .deinit = dummyDeinit,
};

/// A dummy virtual table for `StepContinuation` used by the mock.
pub const mock_continuation_vtable = StepContinuation.VTable{
    .deinit = dummyDeinit,
};

/// A no-op implementation of `deinit`.
fn dummyDeinit(ptr: *anyopaque) void {
    _ = ptr;
}

/// Mock implementation of `listModels`.
fn list_models(ptr: *anyopaque, allocator: Allocator) Provider.ProviderError!ListModelsResult {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    self.list_models_calls += 1;
    self.last_allocator = allocator;
    if (self.list_models_result) |res| {
        return res;
    }
    return ListModelsResult{
        .models = &.{},
        .ptr = ptr,
        .vtable = &mock_list_models_vtable,
    };
}

/// Mock implementation of `executeStep`.
fn execute_step(
    ptr: *anyopaque,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?StepContinuation,
) Provider.ProviderError!StepOutcome {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    self.execute_step_calls += 1;
    self.last_allocator = allocator;
    self.last_session_config = session_config;
    self.last_input = input;
    self.last_previous_step = previous_step;
    if (self.execute_step_results) |results| {
        if (results.len == 0) {
            @panic("execute_step_results is empty");
        }
        const call_idx = self.execute_step_calls - 1;
        if (call_idx < results.len) {
            return results[call_idx];
        } else if (self.execute_step_results_loop) {
            return results[call_idx % results.len];
        } else {
            @panic("execute_step called more times than available outcomes");
        }
    }
    return StepOutcome{
        .result = StepResult{
            .model_output = &.{},
            .thoughts = &.{},
            .tool_calls = &.{},
            .ptr = ptr,
            .vtable = &mock_step_vtable,
        },
        .continuation = StepContinuation{ .ptr = ptr, .vtable = &mock_continuation_vtable },
    };
}

/// Mock implementation of `executeStepStreaming`.
fn execute_step_streaming(
    ptr: *anyopaque,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?StepContinuation,
    callback: types.StreamingCallback,
    callback_context: ?*anyopaque,
) Provider.ProviderError!StepOutcome {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    self.execute_step_streaming_calls += 1;
    self.last_allocator = allocator;
    self.last_session_config = session_config;
    self.last_input = input;
    self.last_previous_step = previous_step;
    if (self.execute_step_streaming_chunks) |chunks_list| {
        if (chunks_list.len > 0) {
            const call_idx = self.execute_step_streaming_calls - 1;
            const idx = if (self.execute_step_results_loop) call_idx % chunks_list.len else call_idx;
            if (idx < chunks_list.len) {
                for (chunks_list[idx]) |chunk| {
                    callback(callback_context, chunk);
                }
            } else {
                @panic("execute_step_streaming called more times than available streaming chunks");
            }
        }
    }
    if (self.execute_step_results) |results| {
        if (results.len == 0) {
            @panic("execute_step_results is empty");
        }
        const call_idx = self.execute_step_streaming_calls - 1;
        if (call_idx < results.len) {
            return results[call_idx];
        } else if (self.execute_step_results_loop) {
            return results[call_idx % results.len];
        } else {
            @panic("execute_step_streaming called more times than available outcomes");
        }
    }
    return StepOutcome{
        .result = StepResult{
            .model_output = &.{},
            .thoughts = &.{},
            .tool_calls = &.{},
            .ptr = ptr,
            .vtable = &mock_step_vtable,
        },
        .continuation = StepContinuation{ .ptr = ptr, .vtable = &mock_continuation_vtable },
    };
}

/// Mock implementation of `deinit`.
fn deinit(ptr: *anyopaque) void {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    self.deinit_calls += 1;
}

/// Helper constructor to create a mock `StepResult` with standard mock vtable.
pub fn stepResult(
    model_output: []const types.ModelOutput,
    thoughts: []const types.Thought,
    tool_calls: []const types.ToolCall,
) StepResult {
    return .{
        .model_output = model_output,
        .thoughts = thoughts,
        .tool_calls = tool_calls,
        .ptr = @constCast(&mock_step_vtable),
        .vtable = &mock_step_vtable,
    };
}

/// Helper constructor to create a mock `StepContinuation` with standard mock vtable.
pub fn stepContinuation() StepContinuation {
    return .{
        .ptr = @constCast(&mock_continuation_vtable),
        .vtable = &mock_continuation_vtable,
    };
}

/// Helper constructor to create a mock `ListModelsResult` with standard mock vtable.
pub fn listModelsResult(models: []const types.Model) ListModelsResult {
    return .{
        .models = models,
        .ptr = @constCast(&mock_list_models_vtable),
        .vtable = &mock_list_models_vtable,
    };
}
