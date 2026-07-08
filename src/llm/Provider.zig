const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const ListModelsResult = types.ListModelsResult;
const SessionConfig = types.SessionConfig;
const Step = types.Step;
const StreamingCallback = types.StreamingCallback;
const StepContinuation = types.StepContinuation;
const StepOutcome = types.StepOutcome;

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
    BadResponse,
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
        previous_step: ?StepContinuation,
    ) ProviderError!types.StepOutcome,

    /// Executes a single interaction step with the LLM, streaming the response.
    execute_step_streaming: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        session_config: SessionConfig,
        input: []const Step,
        previous_step: ?StepContinuation,
        callback: types.StreamingCallback,
        callback_context: ?*anyopaque,
    ) ProviderError!types.StepOutcome,

    /// Frees the resources associated with the provider.
    deinit: *const fn (ptr: *anyopaque) void,
};

/// Lists all models available from the current provider.
///
/// `allocator` is used to allocate the structures and strings in the returned `ListModelsResult`.
/// The caller **MUST** call `deinit()` on the returned `ListModelsResult` to free the allocated memory.
pub fn listModels(provider: *Provider, allocator: Allocator) ProviderError!ListModelsResult {
    return provider.vtable.list_models(provider.ptr, allocator);
}

/// Executes a single step of interaction with the LLM provider.
///
/// `allocator` is used to allocate the structures and strings in the returned `StepOutcome`.
/// `session_config` configuration for the session, should be constant for all calls to executeStep within a session.
/// `input` is an array of steps (prompts or tool results) to send to the model.
/// `previous_step` is the result of the previous interaction, if any, to maintain context.
///
/// The caller **MUST** call `deinit()` on both the returned `result` and `continuation` fields of `StepOutcome`
/// to free the allocated memory.
pub fn executeStep(
    provider: *Provider,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?StepContinuation,
) ProviderError!StepOutcome {
    return provider.vtable.execute_step(provider.ptr, allocator, session_config, input, previous_step);
}

/// Executes a single step of interaction with the LLM provider, streaming chunks back to the callback.
///
/// `allocator` is used to allocate internal streaming state and structures in the final returned `StepOutcome`.
/// `session_config` configuration for the session, should be constant for all calls to executeStep within a session.
/// `input` is an array of steps (prompts or tool results) to send to the model.
/// `previous_step` is the result of the previous interaction, if any, to maintain context.
/// `callback` is called with incremental response chunks as they arrive.
/// `callback_context` is user-provided context passed back to the callback function.
///
/// Memory Behavior:
/// - The chunks sent to `callback` are managed by the Provider and will be freed after the callback returns.
///   The callback must copy/duplicate any data it needs to retain past the execution of the callback.
/// - The caller **MUST** call `deinit()` on both the returned `result` and `continuation` fields of `StepOutcome`
///   to free the accumulated response contents and continuation memory.
pub fn executeStepStreaming(
    provider: *Provider,
    allocator: Allocator,
    session_config: SessionConfig,
    input: []const Step,
    previous_step: ?StepContinuation,
    callback: StreamingCallback,
    callback_context: ?*anyopaque,
) ProviderError!StepOutcome {
    return provider.vtable.execute_step_streaming(provider.ptr, allocator, session_config, input, previous_step, callback, callback_context);
}

/// Frees the resources associated with the provider.
pub fn deinit(provider: *Provider) void {
    provider.vtable.deinit(provider.ptr);
}
