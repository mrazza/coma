const std = @import("std");
const Allocator = std.mem.Allocator;
const llm = @import("llm");
const Provider = llm.Provider;
const types = llm.types;
const ListModelsResult = types.ListModelsResult;
const StepResult = types.StepResult;
const SessionConfig = types.SessionConfig;
const Step = types.Step;

list_models_calls: usize = 0,
execute_step_calls: usize = 0,
deinit_calls: usize = 0,

last_allocator: ?Allocator = null,
last_session_config: ?SessionConfig = null,
last_input: ?[]const Step = null,
last_previous_step: ?StepResult = null,

list_models_result: ?(Provider.ProviderError!ListModelsResult) = null,
execute_step_result: ?(Provider.ProviderError!StepResult) = null,

const MockProvider = @This();

const vtable = Provider.VTable{
    .list_models = MockProvider.list_models,
    .execute_step = MockProvider.execute_step,
    .deinit = MockProvider.deinit,
};

pub fn provider(self: *MockProvider) Provider {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub const mock_list_models_vtable = ListModelsResult.VTable{
    .deinit = dummyDeinit,
};

pub const mock_step_vtable = StepResult.VTable{
    .deinit = dummyDeinit,
};

fn dummyDeinit(ptr: *anyopaque) void {
    _ = ptr;
}

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

fn deinit(ptr: *anyopaque) void {
    const self: *MockProvider = @ptrCast(@alignCast(ptr));
    self.deinit_calls += 1;
}
