const std = @import("std");
const llm = @import("llm");
const testing = @import("testing");

test "Provider.listModels delegates to VTable" {
    const allocator = std.testing.allocator;
    var mock_impl = testing.MockProvider{};
    var prov = mock_impl.provider();

    var result = try prov.listModels(allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_impl.list_models_calls);
    try std.testing.expectEqual(allocator, mock_impl.last_allocator.?);
}

test "Provider.executeStep delegates to VTable" {
    const allocator = std.testing.allocator;
    var mock_impl = testing.MockProvider{};
    var prov = mock_impl.provider();

    const model = llm.types.Model{
        .id = "test-model-id",
        .display_name = "Test Model",
    };
    const session_config = llm.types.SessionConfig{
        .model = model,
        .tools = &.{},
    };
    const input_steps = &[_]llm.types.Step{
        .{ .prompt = "hello" },
    };

    var mock_step_continuation: testing.MockProvider.MockStepContinuation = .{};
    const last_step_continuation = mock_step_continuation.stepContinuation();

    var outcome = try prov.executeStep(allocator, session_config, input_steps, last_step_continuation);
    defer outcome.result.deinit();
    defer outcome.continuation.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_calls);
    try std.testing.expectEqual(allocator, mock_impl.last_allocator.?);
    try std.testing.expectEqualStrings("test-model-id", mock_impl.last_session_config.?.model.id);
    try std.testing.expectEqualStrings("hello", mock_impl.last_input.?[0].prompt);
    try std.testing.expectEqual(last_step_continuation.ptr, mock_impl.last_previous_step.?.ptr);
}

test "Provider.deinit delegates to VTable" {
    var mock_impl = testing.MockProvider{};
    var prov = mock_impl.provider();

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
        mock_impl.list_models_result = llm.types.ListModelsResult{
            .models = dummy_models,
            .ptr = &mock_impl,
            .vtable = &testing.MockProvider.mock_list_models_vtable,
        };

        var prov = mock_impl.provider();
        var result = try prov.listModels(allocator);
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 1), mock_impl.list_models_calls);
        try std.testing.expectEqualStrings("custom-id", result.models[0].id);
    }

    // Test custom error
    {
        var mock_impl = testing.MockProvider{};
        mock_impl.list_models_result = error.HttpRequestFailed;

        var prov = mock_impl.provider();
        try std.testing.expectError(error.HttpRequestFailed, prov.listModels(allocator));
    }
}

test "Provider.executeStep returns custom success and error" {
    const allocator = std.testing.allocator;
    const model = llm.types.Model{ .id = "id", .display_name = "name" };
    const session_config = llm.types.SessionConfig{ .model = model, .tools = &.{} };

    // Test custom success
    {
        var mock_impl = testing.MockProvider{};
        const dummy_outputs = &[_]llm.types.ModelOutput{
            .{ .text = "custom-output" },
        };
        mock_impl.execute_step_result = llm.types.StepResult{
            .model_output = dummy_outputs,
            .thoughts = &.{},
            .tool_calls = &.{},
            .ptr = &mock_impl,
            .vtable = &testing.MockProvider.mock_step_vtable,
        };
        mock_impl.execute_step_continuation = llm.types.StepContinuation{
            .ptr = &mock_impl,
            .vtable = &testing.MockProvider.mock_continuation_vtable,
        };

        var prov = mock_impl.provider();
        var outcome = try prov.executeStep(allocator, session_config, &.{}, null);
        defer outcome.result.deinit();
        defer outcome.continuation.deinit();

        try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_calls);
        try std.testing.expectEqualStrings("custom-output", outcome.result.model_output[0].text);
    }

    // Test custom error
    {
        var mock_impl = testing.MockProvider{};
        mock_impl.execute_step_result = error.HttpRequestFailed;

        var prov = mock_impl.provider();
        try std.testing.expectError(error.HttpRequestFailed, prov.executeStep(allocator, session_config, &.{}, null));
    }
}

test "Provider.executeStepStreaming delegates to VTable" {
    const allocator = std.testing.allocator;
    var mock_impl = testing.MockProvider{};
    var prov = mock_impl.provider();

    const model = llm.types.Model{
        .id = "test-model-id",
        .display_name = "Test Model",
    };
    const session_config = llm.types.SessionConfig{
        .model = model,
        .tools = &.{},
    };
    const input_steps = &[_]llm.types.Step{
        .{ .prompt = "hello" },
    };

    var mock_continuation: testing.MockProvider.MockStepContinuation = .{};
    const prev_continuation = mock_continuation.stepContinuation();

    const CallbackState = struct {
        fn callback(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx;
            _ = chunk;
        }
    };

    var outcome = try prov.executeStepStreaming(allocator, session_config, input_steps, prev_continuation, CallbackState.callback, null);
    defer outcome.result.deinit();
    defer outcome.continuation.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_streaming_calls);
    try std.testing.expectEqual(@as(usize, 0), mock_impl.execute_step_calls);
    try std.testing.expectEqual(allocator, mock_impl.last_allocator.?);
    try std.testing.expectEqualStrings("test-model-id", mock_impl.last_session_config.?.model.id);
    try std.testing.expectEqualStrings("hello", mock_impl.last_input.?[0].prompt);
    try std.testing.expectEqual(prev_continuation.ptr, mock_impl.last_previous_step.?.ptr);
}

test "Provider.executeStepStreaming returns custom success and error" {
    const allocator = std.testing.allocator;
    const model = llm.types.Model{ .id = "id", .display_name = "name" };
    const session_config = llm.types.SessionConfig{ .model = model, .tools = &.{} };

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
        mock_impl.execute_step_result = llm.types.StepResult{
            .model_output = dummy_outputs,
            .thoughts = &.{},
            .tool_calls = &.{},
            .ptr = &mock_impl,
            .vtable = &testing.MockProvider.mock_step_vtable,
        };
        mock_impl.execute_step_continuation = llm.types.StepContinuation{
            .ptr = &mock_impl,
            .vtable = &testing.MockProvider.mock_continuation_vtable,
        };

        var prov = mock_impl.provider();
        var outcome = try prov.executeStepStreaming(allocator, session_config, &.{}, null, CallbackState.callback, null);
        defer outcome.result.deinit();
        defer outcome.continuation.deinit();

        try std.testing.expectEqual(@as(usize, 1), mock_impl.execute_step_streaming_calls);
        try std.testing.expectEqualStrings("custom-output", outcome.result.model_output[0].text);
    }

    // Test custom error
    {
        var mock_impl = testing.MockProvider{};
        mock_impl.execute_step_result = error.HttpRequestFailed;

        var prov = mock_impl.provider();
        try std.testing.expectError(error.HttpRequestFailed, prov.executeStepStreaming(allocator, session_config, &.{}, null, CallbackState.callback, null));
    }
}
