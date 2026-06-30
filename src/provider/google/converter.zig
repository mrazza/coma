const std = @import("std");
const llm = @import("llm");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;

/// Converts a generic `llm.types.Tool` into a Gemini API-specific `api.Tool`.
pub fn toGoogleTool(arena: Allocator, tool: llm.types.Tool) !api.Tool {
    const properties = if (tool.parameters.len > 0) try arena.alloc(api.Function.Parameters.Property, tool.parameters.len) else null;
    errdefer if (properties) |p| arena.free(p);

    var required_count: usize = 0;
    for (tool.parameters) |param| {
        if (param.required) {
            required_count += 1;
        }
    }

    var required: ?[]const []const u8 = null;
    if (required_count > 0) {
        const req_list = try arena.alloc([]const u8, required_count);
        errdefer arena.free(req_list);
        var req_idx: usize = 0;
        for (tool.parameters) |param| {
            if (param.required) {
                req_list[req_idx] = param.name;
                req_idx += 1;
            }
        }
        required = req_list;
    }

    if (properties) |p| {
        for (tool.parameters, 0..) |param, i| {
            switch (param.type) {
                .string => {
                    p[i] = .{
                        .string = .{
                            .name = param.name,
                            .description = param.description,
                            .enum_values = null,
                        },
                    };
                },
            }
        }
    }

    return .{
        .function = .{
            .name = tool.name,
            .description = tool.description,
            .parameters = .{
                .properties = properties,
                .required = required,
            },
        },
    };
}

/// Converts a generic `llm.types.Step` into a Gemini API-specific `api.CreateInteractionRequest.Step`.
pub fn toGoogleStep(arena: Allocator, step: llm.types.Step) !api.CreateInteractionRequest.Step {
    switch (step) {
        .prompt => |prompt| {
            const content = try arena.alloc(api.Content, 1);
            content[0] = .{
                .type = .text,
                .text = prompt,
            };
            return .{
                .user_input = .{
                    .content = content,
                },
            };
        },
        .tool_result => |tool_result| {
            return .{
                .function_result = .{
                    .name = tool_result.tool_name,
                    .call_id = tool_result.id,
                    .result = tool_result.result,
                },
            };
        },
    }
}

/// Converts a Gemini API step type into a generic step start payload.
pub fn toStepStartPayload(step: api.Step) llm.types.StepStartPayload {
    return switch (step) {
        .thought => .thought,
        .model_output => .model_output,
        .function_call => |fc| .{
            .tool_call = .{
                .id = fc.id,
                .name = fc.name,
            },
        },
    };
}

/// Converts a Gemini API step delta into a generic delta.
/// For tool calls, the parsed arguments must be provided.
///
/// Returns null if no interesting or reasonable `Delta` object can be constructed. For example,
/// if a tool call delta is received but no arguments have been provided yet.
pub fn toDelta(delta: api.InteractionStepDelta, arguments: []const llm.types.Argument) ?llm.types.Delta {
    return switch (delta) {
        .arguments_delta => if (arguments.len > 0) .{
            .tool_call = arguments,
        } else null,
        .text_delta => |td| .{
            .model_output = .{
                .text = td.text orelse "",
            },
        },
        .thought_summary => |ts| .{
            .thought = .{
                .text = ts.content.text orelse "",
            },
        },
    };
}

/// Converts a Gemini API function argument to a generic argument without duplicating strings.
pub fn toArgument(arg: api.FunctionArgument) llm.types.Argument {
    return .{
        .name = arg.name,
        .value = arg.value,
    };
}

/// Converts a slice of Gemini API function arguments to a generic argument slice.
/// Caller owns the returned slice, but not the individual strings.
pub fn toArguments(allocator: Allocator, args: []const api.FunctionArgument) ![]llm.types.Argument {
    const result = try allocator.alloc(llm.types.Argument, args.len);
    for (args, 0..) |arg, i| {
        result[i] = toArgument(arg);
    }
    return result;
}

/// Converts a slice of Gemini API function arguments to a generic argument slice, duplicating all strings.
/// Caller owns the returned slice and the individual strings.
pub fn dupeArguments(allocator: Allocator, args: []const api.FunctionArgument) ![]llm.types.Argument {
    const result = try allocator.alloc(llm.types.Argument, args.len);
    errdefer {
        for (result) |arg| {
            allocator.free(arg.name);
            allocator.free(arg.value);
        }
        allocator.free(result);
    }
    for (args, 0..) |arg, i| {
        result[i] = .{
            .name = try allocator.dupe(u8, arg.name),
            .value = try allocator.dupe(u8, arg.value),
        };
    }
    return result;
}

/// Converts a Gemini API model to a generic model structure.
pub fn toModel(model: api.GeminiModel) llm.types.Model {
    return .{
        .id = model.name,
        .display_name = model.displayName,
    };
}

/// Converts a slice of Gemini API models to a generic model slice.
/// Caller owns the returned slice.
pub fn toModels(allocator: Allocator, models: []const api.GeminiModel) ![]llm.types.Model {
    const result = try allocator.alloc(llm.types.Model, models.len);
    for (models, 0..) |model, i| {
        result[i] = toModel(model);
    }
    return result;
}

test toGoogleTool {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const tool = llm.types.Tool{
        .name = "get_weather",
        .description = "Get the current weather",
        .parameters = &.{
            .{
                .name = "location",
                .description = "The city and state, e.g. San Francisco, CA",
                .type = .string,
                .required = true,
            },
            .{
                .name = "unit",
                .description = "Temperature unit",
                .type = .string,
                .required = false,
            },
        },
    };

    const google_tool = try toGoogleTool(arena_allocator, tool);

    try std.testing.expectEqualStrings("get_weather", google_tool.function.name);
    try std.testing.expectEqualStrings("Get the current weather", google_tool.function.description);

    const properties = google_tool.function.parameters.properties.?;
    try std.testing.expectEqual(2, properties.len);
    try std.testing.expectEqualStrings("location", properties[0].string.name);
    try std.testing.expectEqualStrings("The city and state, e.g. San Francisco, CA", properties[0].string.description);
    try std.testing.expectEqualStrings("unit", properties[1].string.name);
    try std.testing.expectEqualStrings("Temperature unit", properties[1].string.description);

    const required = google_tool.function.parameters.required.?;
    try std.testing.expectEqual(1, required.len);
    try std.testing.expectEqualStrings("location", required[0]);
}

test "toGoogleTool with no parameters" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const tool = llm.types.Tool{
        .name = "simple_tool",
        .description = "A tool with no parameters",
        .parameters = &.{},
    };

    const google_tool = try toGoogleTool(arena_allocator, tool);

    try std.testing.expectEqualStrings("simple_tool", google_tool.function.name);
    try std.testing.expectEqualStrings("A tool with no parameters", google_tool.function.description);
    try std.testing.expect(google_tool.function.parameters.properties == null);
    try std.testing.expect(google_tool.function.parameters.required == null);
}

test toGoogleStep {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const prompt_step = llm.types.Step{
        .prompt = "Hello, world!",
    };
    const google_prompt = try toGoogleStep(arena_allocator, prompt_step);
    try std.testing.expectEqualStrings("Hello, world!", google_prompt.user_input.content[0].text.?);
    try std.testing.expect(google_prompt.user_input.content[0].type == api.Content.Type.text);

    const tool_step = llm.types.Step{
        .tool_result = .{
            .tool_name = "test_tool",
            .id = "call_123",
            .result = "success",
        },
    };
    const google_tool = try toGoogleStep(arena_allocator, tool_step);
    try std.testing.expectEqualStrings("test_tool", google_tool.function_result.name);
    try std.testing.expectEqualStrings("call_123", google_tool.function_result.call_id);
    try std.testing.expectEqualStrings("success", google_tool.function_result.result);
}

test toStepStartPayload {
    const thought_step = api.Step{ .thought = &.{} };
    const thought_payload = toStepStartPayload(thought_step);
    try std.testing.expect(thought_payload == .thought);

    const model_output_step = api.Step{ .model_output = &.{} };
    const model_payload = toStepStartPayload(model_output_step);
    try std.testing.expect(model_payload == .model_output);

    const function_call_step = api.Step{
        .function_call = .{
            .id = "call_id",
            .name = "func_name",
            .arguments = &.{},
        },
    };
    const fc_payload = toStepStartPayload(function_call_step);
    try std.testing.expectEqualStrings("call_id", fc_payload.tool_call.id);
    try std.testing.expectEqualStrings("func_name", fc_payload.tool_call.name);
}

test toDelta {
    const arguments = &[_]llm.types.Argument{
        .{ .name = "arg1", .value = "val1" },
    };
    const arg_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "foo" },
    };
    const delta1 = toDelta(arg_delta, arguments);
    try std.testing.expect(delta1.? == .tool_call);
    try std.testing.expectEqualStrings("arg1", delta1.?.tool_call[0].name);

    const text_delta = api.InteractionStepDelta{
        .text_delta = .{ .type = .text, .text = "hello" },
    };
    const delta2 = toDelta(text_delta, &.{});
    try std.testing.expect(delta2.? == .model_output);
    try std.testing.expectEqualStrings("hello", delta2.?.model_output.text);

    const thought_delta = api.InteractionStepDelta{
        .thought_summary = .{
            .content = .{ .type = .text, .text = "thinking" },
        },
    };
    const delta3 = toDelta(thought_delta, &.{});
    try std.testing.expect(delta3.? == .thought);
    try std.testing.expectEqualStrings("thinking", delta3.?.thought.text);
}

test toArguments {
    const allocator = std.testing.allocator;
    const args = &[_]api.FunctionArgument{
        .{ .name = "param", .value = "value" },
    };

    const generic_args = try toArguments(allocator, args);
    defer allocator.free(generic_args);
    try std.testing.expectEqual(1, generic_args.len);
    try std.testing.expectEqualStrings("param", generic_args[0].name);
    try std.testing.expectEqualStrings("value", generic_args[0].value);
}

test dupeArguments {
    const allocator = std.testing.allocator;
    const args = &[_]api.FunctionArgument{
        .{ .name = "param", .value = "value" },
    };

    const generic_duped = try dupeArguments(allocator, args);
    defer {
        for (generic_duped) |arg| {
            allocator.free(arg.name);
            allocator.free(arg.value);
        }
        allocator.free(generic_duped);
    }
    try std.testing.expectEqual(1, generic_duped.len);
    try std.testing.expectEqualStrings("param", generic_duped[0].name);
    try std.testing.expectEqualStrings("value", generic_duped[0].value);
}

test toModels {
    const allocator = std.testing.allocator;
    const models = &[_]api.GeminiModel{
        .{
            .name = "gemini-model",
            .version = "1.0",
            .displayName = "Gemini Model",
            .description = "Test",
            .inputTokenLimit = 100,
            .outputTokenLimit = 50,
        },
    };

    const generic_models = try toModels(allocator, models);
    defer allocator.free(generic_models);
    try std.testing.expectEqual(1, generic_models.len);
    try std.testing.expectEqualStrings("gemini-model", generic_models[0].id);
    try std.testing.expectEqualStrings("Gemini Model", generic_models[0].display_name);
}

test "toDelta with empty arguments_delta" {
    const arg_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "foo" },
    };
    const delta = toDelta(arg_delta, &.{});
    try std.testing.expect(delta == null);
}

test "toGoogleTool OOM" {
    const tool = llm.types.Tool{
        .name = "get_weather",
        .description = "Get weather",
        .parameters = &.{
            .{
                .name = "location",
                .description = "City",
                .type = .string,
                .required = true,
            },
        },
    };
    try std.testing.expectError(error.OutOfMemory, toGoogleTool(std.testing.failing_allocator, tool));
}

test "toGoogleStep OOM" {
    const prompt_step = llm.types.Step{ .prompt = "Hello" };
    try std.testing.expectError(error.OutOfMemory, toGoogleStep(std.testing.failing_allocator, prompt_step));
}

test "toArguments OOM" {
    const args = &[_]api.FunctionArgument{
        .{ .name = "param", .value = "val" },
    };
    try std.testing.expectError(error.OutOfMemory, toArguments(std.testing.failing_allocator, args));
}

test "dupeArguments OOM" {
    const args = &[_]api.FunctionArgument{
        .{ .name = "param", .value = "val" },
    };
    try std.testing.expectError(error.OutOfMemory, dupeArguments(std.testing.failing_allocator, args));
}

test "toModels OOM" {
    const models = &[_]api.GeminiModel{
        .{
            .name = "gemini-model",
            .version = "1.0",
            .displayName = "Gemini Model",
            .description = "Test",
            .inputTokenLimit = 100,
            .outputTokenLimit = 50,
        },
    };
    try std.testing.expectError(error.OutOfMemory, toModels(std.testing.failing_allocator, models));
}
