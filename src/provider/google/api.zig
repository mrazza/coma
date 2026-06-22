const std = @import("std");

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
};

/// Represents a piece of content (like text) in an interaction step.
pub const Content = struct {
    pub const Type = enum {
        text,
    };

    type: Type,
    text: ?[]const u8 = null,
};

/// Represents a request from the model to execute a function.
pub const FunctionCall = struct {
    pub const Argument = struct {
        name: []const u8,
        value: []const u8,
    };

    id: []const u8,
    name: []const u8,
    arguments: []Argument,

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !FunctionCall {
        const id = try std.json.innerParseFromValue([]const u8, allocator, source.object.get("id") orelse return error.MissingField, options);
        const name = try std.json.innerParseFromValue([]const u8, allocator, source.object.get("name") orelse return error.MissingField, options);
        const arguments_value = source.object.get("arguments") orelse return error.MissingField;
        var arguments: std.ArrayList(Argument) = .empty;
        errdefer arguments.deinit(allocator);
        var argument_iterator = arguments_value.object.iterator();
        while (argument_iterator.next()) |arg| {
            const key = arg.key_ptr.*;
            const value = arg.value_ptr.string;
            if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "id")) {
                continue;
            }
            try arguments.append(allocator, Argument{
                .name = key,
                .value = value,
            });
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
        const json_value: std.json.Value = try std.json.innerParse(std.json.Value, allocator, source, options);
        const step_type = try std.json.innerParseFromValue(StepType, allocator, json_value.object.get("type") orelse return error.MissingField, options);
        return switch (step_type) {
            .thought => {
                if (json_value.object.get("summary")) |summary| {
                    return Step{
                        .thought = try std.json.innerParseFromValue([]Content, allocator, summary, options),
                    };
                } else {
                    return Step{ .thought = &.{} };
                }
            },
            .model_output => Step{
                .model_output = try std.json.innerParseFromValue([]Content, allocator, json_value.object.get("content") orelse return error.MissingField, options),
            },
            .function_call => Step{
                .function_call = try std.json.innerParseFromValue(FunctionCall, allocator, json_value, options),
            },
        };
    }
};

/// The full response from the Gemini API representing an interaction.
pub const Interaction = struct {
    id: []const u8,
    steps: []Step,
};
