const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ListModelsResult = types.ListModelsResult;
const StepResult = types.StepResult;
const SessionConfig = types.SessionConfig;
const Step = types.Step;

const Provider = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const ProviderError = error{
    BadUri,
    HttpRequestFailed,
} || Allocator.Error;

pub const VTable = struct {
    list_models: *const fn (ptr: *anyopaque, allocator: Allocator) ProviderError!ListModelsResult,
    execute_step: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        session_config: SessionConfig,
        input: []const Step,
        previous_step: ?StepResult,
    ) ProviderError!StepResult,
    deinit: *const fn (ptr: *anyopaque) void,
};

/// Lists all models available from the current provider.
pub fn listModels(provider: *Provider, allocator: Allocator) ProviderError!ListModelsResult {
    return provider.vtable.list_models(provider.ptr, allocator);
}

pub fn executeStep(
    provider: *Provider,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?StepResult,
) ProviderError!StepResult {
    return provider.vtable.execute_step(provider.ptr, allocator, session_config, input, previous_step);
}

pub fn deinit(provider: *Provider) void {
    provider.vtable.deinit(provider.ptr);
}
