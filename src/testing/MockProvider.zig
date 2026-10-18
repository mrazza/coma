//! A mock implementation of the `llm.Provider` interface for testing.

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

const MockProvider = @This();

interface: Provider = .{ .vtable = &vtable },

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
last_input_steps: ?[]const Step = null,
/// Stores the previous step from the last `executeStep` call.
last_previous_step: ?*const StepContinuation = null,

/// Optional fixed result to return from `listModels`.
list_models_result: ?(Provider.ProviderError!*ListModelsResult) = null,
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
    .deinit = MockProvider.deinitVtable,
};

/// Returns the generic `llm.Provider` interface for this mock instance.
pub fn provider(self: *MockProvider) *Provider {
    return &self.interface;
}

/// A dummy virtual table for `ListModelsResult` used by the mock.
pub const mock_list_models_vtable = ListModelsResult.VTable{
    .deinit = dummyDeinitListModels,
};

/// A dummy virtual table for `StepResult` used by the mock.
pub const mock_step_vtable = StepResult.VTable{
    .deinit = dummyDeinitStepResult,
};

/// A dummy virtual table for `StepContinuation` used by the mock.
pub const mock_continuation_vtable = StepContinuation.VTable{
    .deinit = dummyDeinitStepContinuation,
};

var default_step_result: StepResult = .{
    .model_output = &.{},
    .thoughts = &.{},
    .tool_calls = &.{},
    .vtable = &mock_step_vtable,
};

var default_step_continuation: StepContinuation = .{
    .vtable = &mock_continuation_vtable,
};

var default_list_models_result: ListModelsResult = .{
    .models = &.{},
    .vtable = &mock_list_models_vtable,
};

fn dummyDeinitListModels(self: *ListModelsResult) void {
    _ = self;
}

fn dummyDeinitStepResult(self: *StepResult) void {
    _ = self;
}

fn dummyDeinitStepContinuation(self: *StepContinuation) void {
    _ = self;
}

/// Mock implementation of `listModels`.
fn list_models(prov: *Provider, allocator: Allocator) Provider.ProviderError!*ListModelsResult {
    const self: *MockProvider = @fieldParentPtr("interface", prov);
    self.list_models_calls += 1;
    self.last_allocator = allocator;
    if (self.list_models_result) |res| {
        return res;
    }
    return &default_list_models_result;
}

fn clearLastInputSteps(self: *MockProvider) void {
    if (self.last_input_steps) |steps| {
        if (self.last_allocator) |alloc| {
            for (steps) |step| {
                switch (step) {
                    .prompt => |p| alloc.free(p),
                    .tool_result => {},
                }
            }
            alloc.free(steps);
        }
        self.last_input_steps = null;
    }
}

fn recordInputSteps(self: *MockProvider, allocator: Allocator, input: []const Step) void {
    self.clearLastInputSteps();
    var list: std.ArrayList(Step) = .empty;
    for (input) |step| {
        switch (step) {
            .prompt => |p| {
                const p_copy = allocator.dupe(u8, p) catch return;
                list.append(allocator, .{ .prompt = p_copy }) catch {
                    allocator.free(p_copy);
                    return;
                };
            },
            .tool_result => |tr| {
                list.append(allocator, .{ .tool_result = tr }) catch return;
            },
        }
    }
    self.last_input_steps = list.toOwnedSlice(allocator) catch return;
}

/// Mock implementation of `executeStep`.
fn execute_step(
    prov: *Provider,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?*const StepContinuation,
) Provider.ProviderError!StepOutcome {
    const self: *MockProvider = @fieldParentPtr("interface", prov);
    self.execute_step_calls += 1;
    self.last_allocator = allocator;
    self.last_session_config = session_config;
    self.recordInputSteps(allocator, input);
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
        .result = &default_step_result,
        .continuation = &default_step_continuation,
    };
}

/// Mock implementation of `executeStepStreaming`.
fn execute_step_streaming(
    prov: *Provider,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?*const StepContinuation,
    callback: types.StreamingCallback,
    callback_context: ?*anyopaque,
) Provider.ProviderError!StepOutcome {
    const self: *MockProvider = @fieldParentPtr("interface", prov);
    self.execute_step_streaming_calls += 1;
    self.last_allocator = allocator;
    self.last_session_config = session_config;
    self.recordInputSteps(allocator, input);
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
        .result = &default_step_result,
        .continuation = &default_step_continuation,
    };
}

/// Mock implementation of `deinit`.
fn deinitVtable(prov: *Provider) void {
    const self: *MockProvider = @fieldParentPtr("interface", prov);
    self.deinit();
}

pub fn deinit(self: *MockProvider) void {
    self.deinit_calls += 1;
    self.clearLastInputSteps();
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
        .vtable = &mock_step_vtable,
    };
}

/// Helper constructor to create a mock `StepContinuation` with standard mock vtable.
pub fn stepContinuation() *StepContinuation {
    return &default_step_continuation;
}

/// Helper constructor to create a mock `ListModelsResult` with standard mock vtable.
pub fn listModelsResult(models: []const types.Model) ListModelsResult {
    return .{
        .models = models,
        .vtable = &mock_list_models_vtable,
    };
}
