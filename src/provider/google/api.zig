const std = @import("std");
const llm = @import("llm");

/// A generic JSON stringifier that iterates over the fields of a struct.
/// It skips fields that are optional and have a null value.
///
/// Useful when implementing a custom json stringifier that writes additional fields before the object fields.
/// But still needs the object fields.
fn jsonStringifyFields(object: anytype, jw: anytype) !void {
    inline for (std.meta.fields(@TypeOf(object))) |field| {
        const value = @field(object, field.name);
        if (@typeInfo(field.type) == .optional and value == null) {
            continue;
        }
        try jw.objectField(field.name);
        try jw.write(value);
    }
}

/// The response format for listing available Gemini models.
pub const ListModelsResponse = struct { models: []GeminiModel, nextPageToken: ?[]const u8 = null };

/// Represents a single Gemini model returned by the API.
pub const GeminiModel = struct {
    name: []const u8,
    version: []const u8,
    displayName: []const u8,
    description: []const u8,
    inputTokenLimit: i32,
    outputTokenLimit: i32,
    supportedGenerationMethods: ?[]const []const u8 = null,
    temperature: ?f32 = null,
    topP: ?f32 = null,
    topK: ?i32 = null,
    maxTemperature: ?f32 = null,
    thinking: ?bool = null,
};

/// Represents the Google Search tool configuration in the Gemini API.
pub const GoogleSearch = struct {
    pub fn jsonStringify(_: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("google_search");
        try jw.endObject();
    }
};

/// Represents a function tool that the LLM can call.
pub const Function = struct {
    pub const Parameters = struct {
        pub const StandardProperty = struct {
            name: []const u8,
            description: []const u8,
            enum_values: ?[]const []const u8 = null,

            pub fn jsonStringify(self: StandardProperty, jw: anytype) !void {
                try jw.objectField("description");
                try jw.write(self.description);
                if (self.enum_values) |values| {
                    try jw.objectField("enum");
                    try jw.write(values);
                }
            }
        };

        pub const ArrayProperty = struct {
            name: []const u8,
            description: []const u8,
            item_type: []const u8,

            pub fn jsonStringify(self: ArrayProperty, jw: anytype) !void {
                try jw.objectField("description");
                try jw.write(self.description);
                try jw.objectField("items");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write(self.item_type);
                try jw.endObject();
            }
        };

        pub const Property = union(enum) {
            string: StandardProperty,
            integer: StandardProperty,
            number: StandardProperty,
            boolean: StandardProperty,
            array: ArrayProperty,

            pub fn jsonStringify(self: Property, jw: anytype) !void {
                switch (self) {
                    inline else => |payload| {
                        try jw.objectField(payload.name);
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write(@tagName(self));
                        try jw.write(payload);
                        try jw.endObject();
                    },
                }
            }
        };

        properties: ?[]const Property,
        required: ?[]const []const u8 = null,

        pub fn jsonStringify(self: Parameters, jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("object");

            if (self.properties) |properties| {
                try jw.objectField("properties");

                try jw.beginObject();
                for (properties) |prop| {
                    try jw.write(prop);
                }
                try jw.endObject();
            }

            if (self.required) |required| {
                try jw.objectField("required");
                try jw.write(required);
            }

            try jw.endObject();
        }
    };

    name: []const u8,
    description: []const u8,
    parameters: Parameters,

    pub fn jsonStringify(self: Function, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("function");

        try jsonStringifyFields(self, jw);

        try jw.endObject();
    }
};

/// A tool that can be provided to the Gemini API.
pub const Tool = union(enum) {
    function: Function,
    google_search: GoogleSearch,

    pub fn jsonStringify(self: Tool, jw: anytype) !void {
        switch (self) {
            inline else => |payload| {
                try jw.write(payload);
            },
        }
    }
};

/// Controls how thoughts (reasoning) are summarized by the model.
pub const ThinkingSummaries = enum {
    auto,
    none,
};

/// Configuration options for model generation.
pub const GenerationConfig = struct {
    thinking_summaries: ThinkingSummaries = .auto,
};

/// The request payload for creating an interaction with the Gemini API.
pub const CreateInteractionRequest = struct {
    pub const Step = union(enum) {
        pub const UserInput = struct {
            content: []const Content,
        };

        pub const FunctionResult = struct {
            name: []const u8,
            call_id: []const u8,
            result: []const u8,
        };

        user_input: UserInput,
        function_result: FunctionResult,

        pub fn jsonStringify(self: CreateInteractionRequest.Step, jw: anytype) !void {
            switch (self) {
                inline else => |payload| {
                    try jw.beginObject();
                    try jw.objectField("type");
                    try jw.write(@tagName(self));
                    try jsonStringifyFields(payload, jw);
                    try jw.endObject();
                },
            }
        }
    };

    model: []const u8,
    input: []const CreateInteractionRequest.Step,
    previous_interaction_id: ?[]const u8 = null,
    generation_config: GenerationConfig = .{},
    tools: []const Tool,
    stream: ?bool = null,
};

/// Represents a piece of content (like text) in an interaction step.
pub const Content = struct {
    pub const Type = enum {
        text,
    };

    type: Type,
    text: ?[]const u8 = null,
};

fn jsonValueToArgumentValue(val: std.json.Value) !?llm.types.Argument.Value {
    return switch (val) {
        .string => |s| .{ .string = s },
        .number_string => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .boolean = b },
        .null => null,
        else => return error.UnexpectedToken,
    };
}

/// Represents an argument to a function call.
pub const FunctionArgument = struct {
    name: []const u8,
    value: llm.types.Argument.Value,

    pub fn parseFromJsonObject(allocator: std.mem.Allocator, source: std.json.Value) ![]FunctionArgument {
        var arguments: std.ArrayList(FunctionArgument) = .empty;
        defer arguments.deinit(allocator);
        var argument_iterator = source.object.iterator();
        while (argument_iterator.next()) |arg| {
            const key = arg.key_ptr.*;
            const value = try jsonValueToArgumentValue(arg.value_ptr.*);
            if (value) |v| {
                try arguments.append(allocator, FunctionArgument{
                    .name = key,
                    .value = v,
                });
            }
        }
        return try arguments.toOwnedSlice(allocator);
    }
};

/// Represents a request from the model to execute a function.
pub const FunctionCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []FunctionArgument,

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !FunctionCall {
        const id = try std.json.innerParseFromValue([]const u8, allocator, source.object.get("id") orelse return error.MissingField, options);
        const name = try std.json.innerParseFromValue([]const u8, allocator, source.object.get("name") orelse return error.MissingField, options);
        const arguments_value = source.object.get("arguments") orelse return error.MissingField;
        var arguments: std.ArrayList(FunctionArgument) = .empty;
        errdefer arguments.deinit(allocator);
        var argument_iterator = arguments_value.object.iterator();
        while (argument_iterator.next()) |arg| {
            const key = arg.key_ptr.*;
            if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "id")) {
                continue;
            }
            const value = try jsonValueToArgumentValue(arg.value_ptr.*);
            if (value) |v| {
                try arguments.append(allocator, FunctionArgument{
                    .name = key,
                    .value = v,
                });
            }
        }
        return FunctionCall{
            .id = id,
            .name = name,
            .arguments = arguments.items,
        };
    }
};

/// The type of step in a Gemini interaction.
pub const StepType = enum {
    thought,
    model_output,
    function_call,
};

/// Represents a single step in a Gemini interaction, such as a thought, output, or function call.
pub const Step = union(StepType) {
    thought: []Content,
    model_output: []Content,
    function_call: FunctionCall,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Step {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !Step {
        if (source != .object) return error.UnexpectedToken;
        const step_type = try std.json.innerParseFromValue(StepType, allocator, source.object.get("type") orelse return error.MissingField, options);
        return switch (step_type) {
            .thought => {
                if (source.object.get("summary")) |summary| {
                    return Step{
                        .thought = try std.json.innerParseFromValue([]Content, allocator, summary, options),
                    };
                } else {
                    return Step{ .thought = &.{} };
                }
            },
            .model_output => {
                if (source.object.get("content")) |content| {
                    return Step{
                        .model_output = try std.json.innerParseFromValue([]Content, allocator, content, options),
                    };
                } else {
                    return Step{ .model_output = &.{} };
                }
            },
            .function_call => Step{
                .function_call = try std.json.innerParseFromValue(FunctionCall, allocator, source, options),
            },
        };
    }
};

/// The full response from the Gemini API representing an interaction.
pub const Interaction = struct {
    id: []const u8,
    steps: []Step,
};

pub const StreamingInteraction = struct {
    id: []const u8,
};

pub const InteractionCreatedEvent = struct {
    interaction: StreamingInteraction,
};

pub const InteractionStatusUpdate = struct {
    interaction_id: []const u8,
};

pub const InteractionStepStartEvent = struct {
    index: u32,
    step: Step,
};

pub const TextDelta = Content;

pub const ThoughtSummaryDelta = struct {
    content: Content,
};

pub const ArgumentsDelta = struct {
    arguments: []const u8,
};

pub const InteractionStepDelta = union(enum) {
    text_delta: TextDelta,
    thought_summary: ThoughtSummaryDelta,
    arguments_delta: ArgumentsDelta,

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !InteractionStepDelta {
        if (source != .object) return error.UnexpectedToken;
        const delta_type = source.object.get("type") orelse return error.MissingField;
        if (delta_type != .string) return error.UnexpectedToken;
        const type_str = delta_type.string;
        if (std.mem.eql(u8, type_str, "text")) {
            return InteractionStepDelta{
                .text_delta = try std.json.innerParseFromValue(TextDelta, allocator, source, options),
            };
        } else if (std.mem.eql(u8, type_str, "thought_summary")) {
            return InteractionStepDelta{
                .thought_summary = try std.json.innerParseFromValue(ThoughtSummaryDelta, allocator, source, options),
            };
        } else if (std.mem.eql(u8, type_str, "arguments_delta")) {
            return InteractionStepDelta{
                .arguments_delta = try std.json.innerParseFromValue(ArgumentsDelta, allocator, source, options),
            };
        } else {
            return error.InvalidEnumTag;
        }
    }
};

pub const InteractionStepDeltaEvent = struct {
    index: u32,
    delta: InteractionStepDelta,
};

pub const InteractionStepStopEvent = struct {
    index: u32,
};

pub const InteractionCompletedEvent = struct {
    interaction: StreamingInteraction,
};

pub const InteractionStreamEvent = union(enum) {
    interaction_created: InteractionCreatedEvent,
    interaction_status_update: InteractionStatusUpdate,
    step_start: InteractionStepStartEvent,
    step_delta: InteractionStepDeltaEvent,
    step_stop: InteractionStepStopEvent,
    interaction_completed: InteractionCompletedEvent,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !InteractionStreamEvent {
        const json_value: std.json.Value = try std.json.innerParse(std.json.Value, allocator, source, options);
        const event_type_value = json_value.object.get("event_type") orelse return error.MissingField;
        const event_type = event_type_value.string;
        if (std.mem.eql(u8, event_type, "interaction.created")) {
            return InteractionStreamEvent{
                .interaction_created = try std.json.innerParseFromValue(InteractionCreatedEvent, allocator, json_value, options),
            };
        } else if (std.mem.eql(u8, event_type, "interaction.status_update")) {
            return InteractionStreamEvent{
                .interaction_status_update = try std.json.innerParseFromValue(InteractionStatusUpdate, allocator, json_value, options),
            };
        } else if (std.mem.eql(u8, event_type, "step.start")) {
            return InteractionStreamEvent{
                .step_start = try std.json.innerParseFromValue(InteractionStepStartEvent, allocator, json_value, options),
            };
        } else if (std.mem.eql(u8, event_type, "step.delta")) {
            return InteractionStreamEvent{
                .step_delta = try std.json.innerParseFromValue(InteractionStepDeltaEvent, allocator, json_value, options),
            };
        } else if (std.mem.eql(u8, event_type, "step.stop")) {
            return InteractionStreamEvent{
                .step_stop = try std.json.innerParseFromValue(InteractionStepStopEvent, allocator, json_value, options),
            };
        } else if (std.mem.eql(u8, event_type, "interaction.completed")) {
            return InteractionStreamEvent{
                .interaction_completed = try std.json.innerParseFromValue(InteractionCompletedEvent, allocator, json_value, options),
            };
        } else {
            return error.UnexpectedToken;
        }
    }
};

test "InteractionStreamEvent jsonParse interaction.created" {
    const allocator = std.testing.allocator;
    const payload = "{ \"event_type\": \"interaction.created\", \"interaction\": { \"id\": \"test-interaction-id\" } }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .interaction_created);
    try std.testing.expectEqualStrings("test-interaction-id", interaction_event.interaction_created.interaction.id);
}

test "InteractionStreamEvent jsonParse interaction.status_update" {
    const allocator = std.testing.allocator;
    const payload = "{ \"event_type\": \"interaction.status_update\", \"interaction_id\": \"test-interaction-id\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .interaction_status_update);
    try std.testing.expectEqualStrings("test-interaction-id", interaction_event.interaction_status_update.interaction_id);
}

test "InteractionStreamEvent jsonParse step.start model_output" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\": 0, \"step\": {\"type\": \"model_output\"}, \"event_type\": \"step.start\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_start);
    try std.testing.expectEqual(0, interaction_event.step_start.index);
    try std.testing.expect(interaction_event.step_start.step == .model_output);
}

test "InteractionStreamEvent jsonParse step.start function_call" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\": 0, \"step\": {\"type\": \"function_call\", \"id\":\"un6k8t18\", \"name\": \"get_weather\", \"arguments\":{}}, \"event_type\": \"step.start\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_start);
    try std.testing.expectEqual(0, interaction_event.step_start.index);
    try std.testing.expect(interaction_event.step_start.step == .function_call);
    const function_call_step = interaction_event.step_start.step.function_call;
    try std.testing.expectEqualStrings("un6k8t18", function_call_step.id);
    try std.testing.expectEqualStrings("get_weather", function_call_step.name);
    try std.testing.expectEqual(0, function_call_step.arguments.len);
}

test "InteractionStreamEvent jsonParse step.start thought" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\":0, \"step\":{\"type\":\"thought\"}, \"event_type\":\"step.start\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_start);
    try std.testing.expectEqual(0, interaction_event.step_start.index);
    try std.testing.expect(interaction_event.step_start.step == .thought);
}

test "InteractionStreamEvent jsonParse step.delta model_output" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\": 0, \"delta\": {\"type\": \"text\", \"text\": \"Hello, my name is Phil\"}, \"event_type\": \"step.delta\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_delta);
    const step_delta = interaction_event.step_delta;
    try std.testing.expectEqual(0, step_delta.index);
    try std.testing.expect(step_delta.delta == .text_delta);
    try std.testing.expectEqualStrings("Hello, my name is Phil", step_delta.delta.text_delta.text.?);
}

test "InteractionStreamEvent jsonParse step.delta function_call" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\": 0, \"delta\": {\"type\": \"arguments_delta\", \"arguments\": \"{\\\"location\\\": \\\"San Francisco, CA\\\"}\"}, \"event_type\": \"step.delta\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_delta);
    const step_delta = interaction_event.step_delta;
    try std.testing.expectEqual(0, step_delta.index);
    try std.testing.expect(step_delta.delta == .arguments_delta);
    try std.testing.expectEqualStrings("{\"location\": \"San Francisco, CA\"}", step_delta.delta.arguments_delta.arguments);
}

test "InteractionStreamEvent jsonParse step.delta thought" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\": 0, \"delta\": {\"type\": \"thought_summary\", \"content\": {\"type\": \"text\", \"text\": \"I need to find the GCD...\"}}, \"event_type\": \"step.delta\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_delta);
    const step_delta = interaction_event.step_delta;
    try std.testing.expectEqual(0, step_delta.index);
    try std.testing.expect(step_delta.delta == .thought_summary);
    try std.testing.expectEqualStrings("I need to find the GCD...", step_delta.delta.thought_summary.content.text.?);
}

test "InteractionStreamEvent jsonParse step.stop" {
    const allocator = std.testing.allocator;
    const payload = "{\"index\": 0, \"event_type\": \"step.stop\"}";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_stop);
    try std.testing.expectEqual(0, interaction_event.step_stop.index);
}

test "InteractionStreamEvent jsonParse interaction.completed" {
    const allocator = std.testing.allocator;
    const payload = "{\"interaction\": {\"id\": \"v1_abc123\", \"status\": \"completed\", \"usage\": {\"total_input_tokens\": 7, \"total_output_tokens\": 12, \"total_tokens\": 19}}, \"event_type\": \"interaction.completed\"}";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .interaction_completed);
    try std.testing.expectEqualStrings("v1_abc123", interaction_event.interaction_completed.interaction.id);
}

test "FunctionArgument parseFromJsonObject" {
    const allocator = std.testing.allocator;
    const payload = "{\"location\": \"San Francisco, CA\", \"date\": \"2026-06-28\"}";
    const json_value = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{ .ignore_unknown_fields = true });
    defer json_value.deinit();
    const function_arguments = try FunctionArgument.parseFromJsonObject(allocator, json_value.value);
    defer allocator.free(function_arguments);
    try std.testing.expectEqualStrings("location", function_arguments[0].name);
    try std.testing.expectEqualStrings("San Francisco, CA", function_arguments[0].value.string);
    try std.testing.expectEqualStrings("date", function_arguments[1].name);
    try std.testing.expectEqualStrings("2026-06-28", function_arguments[1].value.string);
}

test "FunctionArgument parseFromJsonObject with non-string values" {
    const allocator = std.testing.allocator;
    const payload = "{\"zip_code\": 7302, \"active\": true, \"null_val\": null}";
    const json_value = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{ .ignore_unknown_fields = true });
    defer json_value.deinit();
    const function_arguments = try FunctionArgument.parseFromJsonObject(allocator, json_value.value);
    defer allocator.free(function_arguments);

    var found_zip = false;
    var found_active = false;
    for (function_arguments) |arg| {
        if (std.mem.eql(u8, arg.name, "zip_code")) {
            try std.testing.expectEqual(@as(i64, 7302), arg.value.integer);
            found_zip = true;
        } else if (std.mem.eql(u8, arg.name, "active")) {
            try std.testing.expectEqual(true, arg.value.boolean);
            found_active = true;
        }
    }
    try std.testing.expectEqual(2, function_arguments.len);
    try std.testing.expect(found_zip);
    try std.testing.expect(found_active);
}

test "GoogleSearch jsonStringify" {
    const allocator = std.testing.allocator;
    const gs = GoogleSearch{};
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var stringifier = std.json.Stringify{
        .writer = &list.writer,
        .options = .{},
    };
    try stringifier.write(gs);
    try std.testing.expectEqualStrings("{\"type\":\"google_search\"}", list.written());
}

test "StandardProperty jsonStringify" {
    const allocator = std.testing.allocator;
    const enum_vals = &[_][]const u8{ "VAL1", "VAL2" };
    const prop = Function.Parameters.StandardProperty{
        .name = "my_enum",
        .description = "Some enum",
        .enum_values = enum_vals,
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"description\":\"Some enum\",\"enum\":[\"VAL1\",\"VAL2\"]}", list.written());
}

test "ArrayProperty jsonStringify" {
    const allocator = std.testing.allocator;
    const prop = Function.Parameters.ArrayProperty{
        .name = "my_arr",
        .description = "Some array",
        .item_type = "string",
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"description\":\"Some array\",\"items\":{\"type\":\"string\"}}", list.written());
}

test "Property string jsonStringify" {
    const allocator = std.testing.allocator;
    const prop = Function.Parameters.Property{
        .string = .{
            .name = "str_prop",
            .description = "String property",
            .enum_values = null,
        },
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"str_prop\":{\"type\":\"string\",\"description\":\"String property\"}}", list.written());
}

test "Property string with enum values jsonStringify" {
    const allocator = std.testing.allocator;
    const enum_vals = &[_][]const u8{ "VAL1", "VAL2" };
    const prop = Function.Parameters.Property{
        .string = .{
            .name = "enum_prop",
            .description = "Enum property",
            .enum_values = enum_vals,
        },
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"enum_prop\":{\"type\":\"string\",\"description\":\"Enum property\",\"enum\":[\"VAL1\",\"VAL2\"]}}", list.written());
}

test "Property integer jsonStringify" {
    const allocator = std.testing.allocator;
    const prop = Function.Parameters.Property{
        .integer = .{
            .name = "int_prop",
            .description = "Integer property",
            .enum_values = null,
        },
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"int_prop\":{\"type\":\"integer\",\"description\":\"Integer property\"}}", list.written());
}

test "Property number jsonStringify" {
    const allocator = std.testing.allocator;
    const prop = Function.Parameters.Property{
        .number = .{
            .name = "num_prop",
            .description = "Number property",
            .enum_values = null,
        },
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"num_prop\":{\"type\":\"number\",\"description\":\"Number property\"}}", list.written());
}

test "Property boolean jsonStringify" {
    const allocator = std.testing.allocator;
    const prop = Function.Parameters.Property{
        .boolean = .{
            .name = "bool_prop",
            .description = "Boolean property",
            .enum_values = null,
        },
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"bool_prop\":{\"type\":\"boolean\",\"description\":\"Boolean property\"}}", list.written());
}

test "Property array jsonStringify" {
    const allocator = std.testing.allocator;
    const prop = Function.Parameters.Property{
        .array = .{
            .name = "arr_prop",
            .description = "Array property",
            .item_type = "string",
        },
    };
    var list: std.Io.Writer.Allocating = .init(allocator);
    defer list.deinit();
    var jw = std.json.Stringify{ .writer = &list.writer, .options = .{} };
    try jw.beginObject();
    try prop.jsonStringify(&jw);
    try jw.endObject();
    try std.testing.expectEqualStrings("{\"arr_prop\":{\"type\":\"array\",\"description\":\"Array property\",\"items\":{\"type\":\"string\"}}}", list.written());
}

test "InteractionStreamEvent jsonParse step.start function_call with arguments and skip key" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\": 0, \"step\": {\"type\": \"function_call\", \"id\":\"un6k8t18\", \"name\": \"get_weather\", \"arguments\":{\"location\":\"Chicago\",\"name\":\"ignored_name\",\"id\":\"ignored_id\"}}, \"event_type\": \"step.start\" }";
    const event = try std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true });
    defer event.deinit();
    const interaction_event = event.value;
    try std.testing.expect(interaction_event == .step_start);
    try std.testing.expectEqual(0, interaction_event.step_start.index);
    try std.testing.expect(interaction_event.step_start.step == .function_call);
    const function_call_step = interaction_event.step_start.step.function_call;
    try std.testing.expectEqualStrings("un6k8t18", function_call_step.id);
    try std.testing.expectEqualStrings("get_weather", function_call_step.name);
    try std.testing.expectEqual(1, function_call_step.arguments.len);
    try std.testing.expectEqualStrings("location", function_call_step.arguments[0].name);
    try std.testing.expectEqualStrings("Chicago", function_call_step.arguments[0].value.string);
}

test "InteractionStreamEvent jsonParse missing event_type" {
    const allocator = std.testing.allocator;
    const payload = "{ \"index\": 0 }";
    try std.testing.expectError(error.MissingField, std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true }));
}

test "InteractionStreamEvent jsonParse unexpected event_type" {
    const allocator = std.testing.allocator;
    const payload = "{ \"event_type\": \"invalid.event\" }";
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(InteractionStreamEvent, allocator, payload, .{ .ignore_unknown_fields = true }));
}
