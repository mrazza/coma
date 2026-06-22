const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const ListModelsResult = types.ListModelsResult;
const StepResult = types.StepResult;
const SessionConfig = types.SessionConfig;
const Step = types.Step;

/// An interface for an LLM provider.
const Provider = @This();

/// Opaque pointer to the provider implementation's context.
ptr: *anyopaque,
/// Pointer to the provider implementation's virtual function table.
vtable: *const VTable,

/// Errors that can occur during provider operations.
pub const ProviderError = error{
    BadUri,
    HttpRequestFailed,
} || Allocator.Error;

/// The virtual function table defining the methods that an LLM provider must implement.
pub const VTable = struct {
    /// Lists all models available from the provider.
    list_models: *const fn (ptr: *anyopaque, allocator: Allocator) ProviderError!ListModelsResult,
    /// Executes a single interaction step with the LLM.
    execute_step: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        session_config: SessionConfig,
        input: []const Step,
        previous_step: ?StepResult,
    ) ProviderError!StepResult,
    /// Frees the resources associated with the provider.
    deinit: *const fn (ptr: *anyopaque) void,
};

/// Lists all models available from the current provider.
pub fn listModels(provider: *Provider, allocator: Allocator) ProviderError!ListModelsResult {
    return provider.vtable.list_models(provider.ptr, allocator);
}

/// Executes a single step of interaction with the LLM provider.
///
/// `session_config` configuration for the session, should be constant for all calls to executeStep within a session.
/// `input` is an array of steps (prompts or tool results) to send to the model.
/// `previous_step` is the result of the previous interaction, if any, to maintain context.
pub fn executeStep(
    provider: *Provider,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?StepResult,
) ProviderError!StepResult {
    return provider.vtable.execute_step(provider.ptr, allocator, session_config, input, previous_step);
}

/// Frees the resources associated with the provider.
pub fn deinit(provider: *Provider) void {
    provider.vtable.deinit(provider.ptr);
}
