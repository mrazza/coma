const std = @import("std");
const Allocator = std.mem.Allocator;
const llm = @import("llm");
const Provider = llm.Provider;
const types = llm.types;
const ListModelsResult = types.ListModelsResult;
const StepResult = types.StepResult;
const SessionConfig = types.SessionConfig;
const Step = types.Step;

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
last_previous_step: ?StepResult = null,

/// Optional fixed result to return from `listModels`.
list_models_result: ?(Provider.ProviderError!ListModelsResult) = null,
/// Optional fixed result to return from `executeStep`.
execute_step_result: ?(Provider.ProviderError!StepResult) = null,

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
    previous_step: ?StepResult,
) Provider.ProviderError!StepResult {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    self.execute_step_calls += 1;
    self.last_allocator = allocator;
    self.last_session_config = session_config;
    self.last_input = input;
    self.last_previous_step = previous_step;
    if (self.execute_step_result) |res| {
        return res;
    }
    return StepResult{
        .model_output = &.{},
        .thoughts = &.{},
        .tool_calls = &.{},
        .ptr = ptr,
        .vtable = &mock_step_vtable,
    };
}

/// Mock implementation of `executeStepStreaming`.
fn execute_step_streaming(
    ptr: *anyopaque,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?StepResult,
    callback: types.StreamingCallback,
    callback_context: ?*anyopaque,
) Provider.ProviderError!StepResult {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    _ = callback;
    _ = callback_context;
    self.execute_step_streaming_calls += 1;
    self.last_allocator = allocator;
    self.last_session_config = session_config;
    self.last_input = input;
    self.last_previous_step = previous_step;
    if (self.execute_step_result) |res| {
        return res;
    }
    return StepResult{
        .model_output = &.{},
        .thoughts = &.{},
        .tool_calls = &.{},
        .ptr = ptr,
        .vtable = &mock_step_vtable,
    };
}

/// Mock implementation of `deinit`.
fn deinit(ptr: *anyopaque) void {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    self.deinit_calls += 1;
}
