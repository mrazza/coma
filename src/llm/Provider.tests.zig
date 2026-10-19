const std = @import("std");
const llm = @import("llm");
const testing = @import("testing");

test "Provider.listModels delegates to VTable" {
    const allocator = std.testing.allocator;
    var mock_impl = testing.MockProvider{};
    const prov = mock_impl.provider();

    const result = try prov.listModels(allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_impl.list_models_calls);
    try std.testing.expectEqual(allocator, mock_impl.last_allocator.?);
}

test "Provider.executeStep delegates to VTable" {
    const allocator = std.testing.allocator;
    var mock_impl = testing.MockProvider{};
    defer mock_impl.deinit();
    const prov = mock_impl.provider();

    const model = llm.types.Model{
        .id = "test-model-id",
        .display_name = "Test Model",
    };
    const session_config = llm.types.SessionConfig{ .model = model };
    const input_steps = &[_]llm.types.Step{
        .{ .prompt = "hello" },
    };

    const last_step_continuation = testing.MockProvider.stepContinuation();

    const outcome = try prov.executeStep(allocator, session_config, input_steps, last_step_continuation);
    defer outcome.result.deinit();
    defer outcome.continuation.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_calls);
    try std.testing.expectEqual(allocator, mock_impl.last_allocator.?);
    try std.testing.expectEqualStrings("test-model-id", mock_impl.last_session_config.?.model.id);
    try std.testing.expectEqualStrings("hello", mock_impl.last_input_steps.?[0].prompt);
    try std.testing.expectEqual(last_step_continuation, mock_impl.last_previous_step.?);
}

test "Provider.deinit delegates to VTable" {
    var mock_impl = testing.MockProvider{};
    const prov = mock_impl.provider();

    prov.deinit();
    try std.testing.expectEqual(@as(usize, 1), mock_impl.deinit_calls);
}

test "Provider.listModels returns custom success and error" {
    const allocator = std.testing.allocator;

    // Test custom success
    {
        var mock_impl = testing.MockProvider{};
        const dummy_models = &[_]llm.types.Model{
            .{ .id = "custom-id", .display_name = "Custom Name" },
        };
        var expected_result = testing.MockProvider.listModelsResult(dummy_models);
        mock_impl.list_models_result = &expected_result;

        const prov = mock_impl.provider();
        const result = try prov.listModels(allocator);
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 1), mock_impl.list_models_calls);
        try std.testing.expectEqualStrings("custom-id", result.models[0].id);
    }

    // Test custom error
    {
        var mock_impl = testing.MockProvider{};
        mock_impl.list_models_result = error.HttpRequestFailed;

        const prov = mock_impl.provider();
        try std.testing.expectError(error.HttpRequestFailed, prov.listModels(allocator));
    }
}

test "Provider.executeStep returns custom success and error" {
    const allocator = std.testing.allocator;
    const model = llm.types.Model{ .id = "id", .display_name = "name" };
    const session_config = llm.types.SessionConfig{ .model = model };

    // Test custom success
    {
        var mock_impl = testing.MockProvider{};
        const dummy_outputs = &[_]llm.types.ModelOutput{
            .{ .text = "custom-output" },
        };
        var step_result = testing.MockProvider.stepResult(dummy_outputs, &.{}, &.{});
        const step_continuation = testing.MockProvider.stepContinuation();
        const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
            .{ .result = &step_result, .continuation = step_continuation },
        };
        mock_impl.execute_step_results = &outcomes;

        const prov = mock_impl.provider();
        const outcome = try prov.executeStep(allocator, session_config, &.{}, null);
        defer outcome.result.deinit();
        defer outcome.continuation.deinit();

        try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_calls);
        try std.testing.expectEqualStrings("custom-output", outcome.result.model_output[0].text);
    }

    // Test custom error
    {
        var mock_impl = testing.MockProvider{};
        const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
            error.HttpRequestFailed,
        };
        mock_impl.execute_step_results = &outcomes;

        const prov = mock_impl.provider();
        try std.testing.expectError(error.HttpRequestFailed, prov.executeStep(allocator, session_config, &.{}, null));
    }
}

test "Provider.executeStepStreaming delegates to VTable" {
    const allocator = std.testing.allocator;
    var mock_impl = testing.MockProvider{};
    defer mock_impl.deinit();
    const prov = mock_impl.provider();

    const model = llm.types.Model{
        .id = "test-model-id",
        .display_name = "Test Model",
    };
    const session_config = llm.types.SessionConfig{ .model = model };
    const input_steps = &[_]llm.types.Step{
        .{ .prompt = "hello" },
    };

    const prev_continuation = testing.MockProvider.stepContinuation();

    const CallbackState = struct {
        fn callback(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx;
            _ = chunk;
        }
    };

    const outcome = try prov.executeStepStreaming(allocator, session_config, input_steps, prev_continuation, CallbackState.callback, null);
    defer outcome.result.deinit();
    defer outcome.continuation.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_streaming_calls);
    try std.testing.expectEqual(@as(usize, 0), mock_impl.execute_step_calls);
    try std.testing.expectEqual(allocator, mock_impl.last_allocator.?);
    try std.testing.expectEqualStrings("test-model-id", mock_impl.last_session_config.?.model.id);
    try std.testing.expectEqualStrings("hello", mock_impl.last_input_steps.?[0].prompt);
    try std.testing.expectEqual(prev_continuation, mock_impl.last_previous_step.?);
}

test "Provider.executeStepStreaming returns custom success and error" {
    const allocator = std.testing.allocator;
    const model = llm.types.Model{ .id = "id", .display_name = "name" };
    const session_config = llm.types.SessionConfig{ .model = model };

    const CallbackState = struct {
        fn callback(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx;
            _ = chunk;
        }
    };

    // Test custom success
    {
        var mock_impl = testing.MockProvider{};
        const dummy_outputs = &[_]llm.types.ModelOutput{
            .{ .text = "custom-output" },
        };
        var step_result = testing.MockProvider.stepResult(dummy_outputs, &.{}, &.{});
        const step_continuation = testing.MockProvider.stepContinuation();
        const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
            .{ .result = &step_result, .continuation = step_continuation },
        };
        mock_impl.execute_step_results = &outcomes;

        const prov = mock_impl.provider();
        const outcome = try prov.executeStepStreaming(allocator, session_config, &.{}, null, CallbackState.callback, null);
        defer outcome.result.deinit();
        defer outcome.continuation.deinit();

        try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_streaming_calls);
        try std.testing.expectEqualStrings("custom-output", outcome.result.model_output[0].text);
    }

    // Test custom error
    {
        var mock_impl = testing.MockProvider{};
        const outcomes = [_](llm.Provider.ProviderError!llm.types.StepOutcome){
            error.HttpRequestFailed,
        };
        mock_impl.execute_step_results = &outcomes;

        const prov = mock_impl.provider();
        try std.testing.expectError(error.HttpRequestFailed, prov.executeStepStreaming(allocator, session_config, &.{}, null, CallbackState.callback, null));
    }
}
