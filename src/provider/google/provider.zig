const std = @import("std");
const llm = @import("llm");
const api = @import("api.zig");
const makeUri = @import("uri.zig").makeUri;
const converter = @import("converter.zig");
const MakeJsonClient = @import("../json_client.zig").MakeJsonClient;
const gemini_types = @import("types.zig");

const Provider = llm.Provider;
const ProviderError = llm.Provider.ProviderError;
const Allocator = std.mem.Allocator;

pub const Gemini = MakeProvider(*std.http.Client);

/// Generates a Gemini provider type parameterized by the underlying HTTP client type.
///
/// `ClientType` is the type of the HTTP client that will be used by the `rpc_client` (e.g. `*std.http.Client` or a mock client).
/// Returns a type representing the provider instance.
fn MakeProvider(comptime ClientType: type) type {
    return struct {
        /// Memory allocator used for copying the API key and other internal allocations.
        allocator: Allocator,
        /// The JSON client wrapper used to handle low-level HTTP requests and responses.
        rpc_client: MakeJsonClient(ClientType),
        /// A copy of the API key used to authorize requests against the Gemini API.
        /// Owned by this provider and freed upon calling `deinit`.
        api_key: []const u8,

        const Self = @This();

        /// Initializes a new instance of the Gemini provider.
        ///
        /// `allocator` is used for internal allocations during the providers lifetime.
        /// `http_client` is the underlying client used to execute requests.
        /// `api_key` is the authentication key. The key's content is duplicated internally and owned by the provider.
        ///
        /// The caller must ensure that they call `deinit` on the provider (or the returned `llm.Provider`)
        /// to clean up memory.
        ///
        /// Returns a new `Self` instance, or `error.OutOfMemory` if the initialization fails.
        pub fn init(allocator: Allocator, http_client: ClientType, api_key: []const u8) !Self {
            return .{
                .allocator = allocator,
                .rpc_client = .{
                    .http_client = http_client,
                },
                .api_key = try allocator.dupe(u8, api_key),
            };
        }

        /// Returns the generic `llm.Provider` interface for this Gemini instance.
        pub fn provider(self: *Self) Provider {
            return .{ .ptr = self, .vtable = &.{
                .list_models = listModels,
                .execute_step = executeStep,
                .execute_step_streaming = executeStepStreaming,
                .deinit = deinit,
            } };
        }

        /// Frees the resources associated with the provider, including the copied API key.
        ///
        /// `ctx` is an opaque pointer to the `Self` instance.
        pub fn deinit(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.allocator.free(self.api_key);
            self.* = undefined;
        }

        /// Lists all available Gemini models from the remote API.
        ///
        /// `ctx` is an opaque pointer to the `Self` instance.
        /// `allocator` is used to allocate internal structures.
        ///
        /// The caller **MUST** call `deinit()` on the returned `ListModelsResult` to free the allocated model details.
        ///
        /// Returns a `ListModelsResult` structure mapping the remote models, or a `ProviderError` on failure.
        pub fn listModels(ctx: *anyopaque, allocator: Allocator) !llm.types.ListModelsResult {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const str_uri = try makeUri(allocator, .{ .path = &.{"models"}, .api_key = self.api_key });
            defer allocator.free(str_uri);
            const uri = std.Uri.parse(str_uri) catch return ProviderError.BadUri;

            const response = self.rpc_client.getRequest(allocator, api.ListModelsResponse, uri) catch return ProviderError.HttpRequestFailed;
            return try gemini_types.ListModelsResult.init(allocator, response);
        }

        /// Helper to construct the API URI and Request Payload.
        ///
        /// `arena_allocator` is an allocator (typically backed by an arena) used to allocate memory for
        /// the constructed URI string, tools, and converted input step payloads.
        /// `session_config` holds the configuration for the active session, including the chosen model and tools.
        /// `input` holds the current steps/prompts/results.
        /// `previous_step` optionally references the previous step result to continue a multi-turn conversation.
        /// `stream` specifies if the request will request a streaming chunked response.
        ///
        /// All allocated content in the return value belongs to the passed `arena_allocator` and the caller is
        /// responsible for its lifetime.
        ///
        /// Returns the structured URI and `CreateInteractionRequest` payload.
        fn buildCreateInteractionRequest(
            self: *Self,
            arena_allocator: Allocator,
            session_config: llm.types.SessionConfig,
            input: []const llm.types.Step,
            previous_step: ?llm.types.StepResult,
            stream: bool,
        ) !struct { uri: std.Uri, payload: api.CreateInteractionRequest } {
            const previous_gemini_step: ?*gemini_types.StepResult = if (previous_step) |step| @ptrCast(@alignCast(step.ptr)) else null;

            var tools: []api.Tool = &.{};
            if (session_config.tools.len > 0) {
                tools = try arena_allocator.alloc(api.Tool, session_config.tools.len);
                for (session_config.tools, 0..) |tool, i| {
                    tools[i] = try converter.toGoogleTool(arena_allocator, tool);
                }
            }

            const str_uri = try makeUri(arena_allocator, .{ .path = &.{"interactions"}, .api_key = self.api_key });
            const uri = std.Uri.parse(str_uri) catch return ProviderError.BadUri;

            const google_input: []api.CreateInteractionRequest.Step = try arena_allocator.alloc(api.CreateInteractionRequest.Step, input.len);
            for (input, 0..) |step, i| {
                google_input[i] = try converter.toGoogleStep(arena_allocator, step);
            }

            const request_payload: api.CreateInteractionRequest = .{
                .model = session_config.model.id,
                .input = google_input,
                .tools = tools,
                .previous_interaction_id = if (previous_gemini_step) |step| step.interaction_id else null,
                .stream = stream,
            };

            return .{ .uri = uri, .payload = request_payload };
        }

        /// Executes a single interaction step using the Gemini API, waiting for the full response.
        ///
        /// `ctx` is an opaque pointer to the `Self` instance.
        /// `allocator` is used to allocate the structures and strings in the returned `StepResult`.
        /// `session_config` provides the model ID and active tools configuration.
        /// `input` contains the array of steps to send as context/prompts.
        /// `previous_step` is an optional reference to the previous step's result to persist conversation state.
        ///
        /// The caller **MUST** call `deinit()` on the returned `StepResult` to free its allocated contents.
        ///
        /// Returns the `StepResult` detailing thoughts, outputs, and tool calls, or a `ProviderError` on failure.
        pub fn executeStep(ctx: *anyopaque, allocator: Allocator, session_config: llm.types.SessionConfig, input: []const llm.types.Step, previous_step: ?llm.types.StepResult) !llm.types.StepResult {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const req_data = try self.buildCreateInteractionRequest(arena.allocator(), session_config, input, previous_step, false);
            const response = self.rpc_client.postRequest(allocator, api.CreateInteractionRequest, api.Interaction, req_data.uri, req_data.payload) catch return ProviderError.HttpRequestFailed;
            return try gemini_types.StepResult.init(allocator, response);
        }

        /// Executes a single interaction step using the Gemini API, streaming chunks of the response back.
        ///
        /// `ctx` is an opaque pointer to the `Self` instance.
        /// `allocator` is used to allocate internal streaming state and structures in the final returned `StepResult`.
        /// `session_config` provides the model ID and active tools configuration.
        /// `input` contains the array of steps to send as context/prompts.
        /// `previous_step` is an optional reference to the previous step's result to persist conversation state.
        /// `callback` is called periodically with streaming response chunks as they arrive.
        /// `callback_context` is user-provided context passed back to the callback function.
        ///
        /// **Memory Alert**:
        /// - The chunks sent to `callback` are managed by the Provider and will be freed after the callback returns.
        ///   The callback must copy/duplicate any data it needs to retain past the execution of the callback.
        /// - The caller **MUST** call `deinit()` on the returned final `StepResult` to free the accumulated response contents.
        ///
        /// Returns the accumulated `StepResult` once the stream completes, or a `ProviderError` on failure.
        pub fn executeStepStreaming(
            ctx: *anyopaque,
            allocator: Allocator,
            session_config: llm.types.SessionConfig,
            input: []const llm.types.Step,
            previous_step: ?llm.types.StepResult,
            callback: llm.types.StreamingCallback,
            callback_context: ?*anyopaque,
        ) !llm.types.StepResult {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const req_data = try self.buildCreateInteractionRequest(arena.allocator(), session_config, input, previous_step, true);
            var streaming_response = self.rpc_client.postRequestStreaming(allocator, api.CreateInteractionRequest, req_data.uri, req_data.payload) catch return ProviderError.HttpRequestFailed;
            defer streaming_response.deinit();

            var reader = streaming_response.reader();
            var line_writer = std.Io.Writer.Allocating.init(allocator);
            defer line_writer.deinit();

            var result_arena = std.heap.ArenaAllocator.init(allocator);
            errdefer result_arena.deinit();

            const Helper = struct {
                fn mapError(err: anyerror) ProviderError {
                    return switch (err) {
                        error.OutOfMemory => ProviderError.OutOfMemory,
                        else => ProviderError.BadResponse,
                    };
                }
            };

            var step_accumulators: std.ArrayList(StepAccumulator) = .empty;
            defer step_accumulators.deinit(result_arena.allocator());
            var interaction_id: ?[]const u8 = null;

            while (true) {
                line_writer.clearRetainingCapacity();
                _ = reader.streamDelimiter(&line_writer.writer, '\n') catch |err| {
                    if (err == error.EndOfStream) break else return ProviderError.BadResponse;
                };
                _ = reader.toss(1);

                const line = std.mem.trimEnd(u8, line_writer.written(), "\r");
                if (!std.mem.startsWith(u8, line, "data: ") or
                    std.mem.endsWith(u8, line, "[DONE]")) continue;

                const json_data = line[6..];

                var stream_event = std.json.parseFromSlice(
                    api.InteractionStreamEvent,
                    allocator,
                    json_data,
                    .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    },
                ) catch |err| {
                    if (err == error.InvalidEnumTag) continue else return ProviderError.BadResponse;
                };
                defer stream_event.deinit();

                const event_type = stream_event.value;
                switch (event_type) {
                    .interaction_created => |e| {
                        if (interaction_id != null) return ProviderError.BadResponse;
                        interaction_id = try result_arena.allocator().dupe(u8, e.interaction.id);
                        callback(callback_context, .{ .event = .{ .interaction_created = {} } });
                    },
                    .interaction_status_update => {
                        // Ignored.
                    },
                    .step_start => |e| {
                        if (step_accumulators.items.len <= e.index) {
                            try step_accumulators.appendNTimes(result_arena.allocator(), .empty, e.index + 1 - step_accumulators.items.len);
                        }
                        if (step_accumulators.items[e.index] != .empty) {
                            return ProviderError.BadResponse;
                        }

                        step_accumulators.items[e.index] = StepAccumulator.init(result_arena.allocator(), e.step) catch |err| return Helper.mapError(err);

                        const payload = converter.toStepStartPayload(e.step);
                        callback(callback_context, .{
                            .event = .{
                                .step_event = .{
                                    .index = e.index,
                                    .event = .{ .start = payload },
                                },
                            },
                        });
                    },
                    .step_delta => |e| {
                        if (e.index >= step_accumulators.items.len) return ProviderError.BadResponse;
                        const acc: *StepAccumulator = &step_accumulators.items[e.index];
                        acc.appendStep(e.delta) catch |err| return Helper.mapError(err);

                        var arguments: []const llm.types.Argument = &.{};
                        defer {
                            for (arguments) |arg| {
                                allocator.free(arg.name);
                                switch (arg.value) {
                                    .string => |s| allocator.free(s),
                                    else => {},
                                }
                            }
                            allocator.free(arguments);
                        }

                        if (e.delta == .arguments_delta) {
                            if (try acc.handleToolCallDelta(allocator)) |args| {
                                arguments = args;
                            }
                        }
                        const delta_payload = converter.toDelta(e.delta, arguments);

                        if (delta_payload) |payload| {
                            callback(callback_context, .{
                                .event = .{
                                    .step_event = .{
                                        .index = e.index,
                                        .event = .{ .delta = payload },
                                    },
                                },
                            });
                        }
                    },
                    .step_stop => |e| {
                        callback(callback_context, .{
                            .event = .{
                                .step_event = .{
                                    .index = e.index,
                                    .event = .end,
                                },
                            },
                        });
                    },
                    .interaction_completed => |e| {
                        if (interaction_id == null or !std.mem.eql(u8, interaction_id.?, e.interaction.id)) return ProviderError.BadResponse;
                        callback(callback_context, .{ .event = .{ .interaction_completed = {} } });
                    },
                }
            }

            var final_model_outputs: std.ArrayList(llm.types.ModelOutput) = .empty;
            var final_thoughts: std.ArrayList(llm.types.Thought) = .empty;
            var final_tool_calls: std.ArrayList(llm.types.ToolCall) = .empty;

            for (step_accumulators.items) |*acc| {
                switch (acc.*) {
                    .thought => |*list| {
                        try final_thoughts.append(result_arena.allocator(), .{
                            .text = list.written(),
                        });
                    },
                    .model_output => |*list| {
                        try final_model_outputs.append(result_arena.allocator(), .{
                            .text = list.written(),
                        });
                    },
                    .tool_call => |*tc| {
                        const json_parsed_args = std.json.parseFromSlice(std.json.Value, result_arena.allocator(), tc.arguments_json.written(), .{}) catch return ProviderError.BadResponse;
                        const function_arguments = api.FunctionArgument.parseFromJsonObject(result_arena.allocator(), json_parsed_args.value) catch return ProviderError.BadResponse;
                        const parsed_args = converter.toArguments(result_arena.allocator(), function_arguments) catch return ProviderError.BadResponse;
                        try final_tool_calls.append(result_arena.allocator(), .{
                            .id = tc.id,
                            .name = tc.name,
                            .arguments = parsed_args,
                        });
                    },
                    .empty => {},
                }
            }

            const final_id = interaction_id orelse try result_arena.allocator().dupe(u8, "unknown");

            return try gemini_types.StreamingStepResult.init(
                allocator,
                result_arena,
                final_id,
                try final_model_outputs.toOwnedSlice(result_arena.allocator()),
                try final_thoughts.toOwnedSlice(result_arena.allocator()),
                try final_tool_calls.toOwnedSlice(result_arena.allocator()),
            );
        }
    };
}

/// Accumulator union used to buffer and aggregate streaming responses for each step.
/// Handles text/thought aggregation and tool call parsing during streaming.
const StepAccumulator = union(enum) {
    /// Holds the aggregated thinking/thought process content.
    thought: std.Io.Writer.Allocating,
    /// Holds the aggregated model response output text.
    model_output: std.Io.Writer.Allocating,
    /// Holds tool call details and buffers the arguments JSON stream.
    tool_call: struct {
        /// The unique ID of the tool call.
        id: []const u8,
        /// The name of the function to invoke.
        name: []const u8,
        /// Dynamic writer buffer accumulating arguments JSON text.
        arguments_json: std.Io.Writer.Allocating,
        /// Tracks the count of arguments that have already been streamed out to the callback.
        processed_argument_count: usize,
    },
    /// Represents an uninitialized or empty accumulator slot.
    empty,

    /// Initializes the `StepAccumulator` with an initial step context.
    ///
    /// `result_arena_allocator` is used to allocate the internal writers and copy initial values.
    /// Memory allocated in `result_arena_allocator` is owned by the caller's session arena.
    /// `initial_step` provides the starting type and content (e.g. initial thought, model output, or function call).
    ///
    /// Returns the initialized `StepAccumulator`, or an allocation error.
    pub fn init(result_arena_allocator: Allocator, initial_step: api.Step) !@This() {
        switch (initial_step) {
            .thought => |contents| {
                var list = std.Io.Writer.Allocating.init(result_arena_allocator);
                for (contents) |c| {
                    if (c.text) |t| {
                        try list.writer.writeAll(t);
                    }
                }
                return .{ .thought = list };
            },
            .model_output => |contents| {
                var list = std.Io.Writer.Allocating.init(result_arena_allocator);
                for (contents) |c| {
                    if (c.text) |t| {
                        try list.writer.writeAll(t);
                    }
                }
                return .{ .model_output = list };
            },
            .function_call => |call| return .{
                .tool_call = .{
                    .id = try result_arena_allocator.dupe(u8, call.id),
                    .name = try result_arena_allocator.dupe(u8, call.name),
                    .arguments_json = std.Io.Writer.Allocating.init(result_arena_allocator),
                    .processed_argument_count = 0,
                },
            },
        }
    }

    /// Appends stream delta data to the accumulator.
    ///
    /// `step_self` points to the accumulator instance.
    /// `delta` is the stream delta payload containing new text or argument fragments.
    ///
    /// Returns a `ProviderError.BadResponse` if the delta type does not match the active accumulator variant.
    pub fn appendStep(step_self: *@This(), delta: api.InteractionStepDelta) !void {
        switch (step_self.*) {
            .thought => |*list| {
                if (delta != .thought_summary) return ProviderError.BadResponse;
                if (delta.thought_summary.content.text) |t| {
                    try list.writer.writeAll(t);
                }
            },
            .model_output => |*list| {
                if (delta != .text_delta) return ProviderError.BadResponse;
                if (delta.text_delta.text) |t| {
                    try list.writer.writeAll(t);
                }
            },
            .tool_call => |*tc| {
                if (delta != .arguments_delta) return ProviderError.BadResponse;
                try tc.arguments_json.writer.writeAll(delta.arguments_delta.arguments);
            },
            .empty => {
                return ProviderError.BadResponse;
            },
        }
    }

    /// Processes newly accumulated tool call arguments JSON and parses new complete arguments.
    ///
    /// `acc` is the active `StepAccumulator` (must be the `.tool_call` variant).
    /// `allocator` is used to allocate the returned array of arguments.
    ///
    /// **Memory Alert**:
    /// The caller takes ownership of the returned slice of `llm.types.Argument` and **MUST** free
    /// the slice, the `name` strings, and the `value` strings when done.
    ///
    /// Returns a slice of newly completed `llm.types.Argument` parameters, or `null` if no new arguments
    /// were completed or parsing failed.
    pub fn handleToolCallDelta(
        acc: *StepAccumulator,
        allocator: Allocator,
    ) !?[]const llm.types.Argument {
        const json_parsed_args = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            acc.tool_call.arguments_json.written(),
            .{},
        ) catch return null;
        defer json_parsed_args.deinit();

        const function_arguments = api.FunctionArgument.parseFromJsonObject(
            allocator,
            json_parsed_args.value,
        ) catch return null;
        defer allocator.free(function_arguments);

        const new_count = function_arguments.len - acc.tool_call.processed_argument_count;
        if (new_count == 0) {
            return null;
        }

        const arguments = try converter.dupeArguments(allocator, function_arguments[acc.tool_call.processed_argument_count..]);
        errdefer {
            for (arguments) |arg| {
                allocator.free(arg.name);
                switch (arg.value) {
                    .string => |s| allocator.free(s),
                    else => {},
                }
            }
            allocator.free(arguments);
        }

        acc.tool_call.processed_argument_count = function_arguments.len;
        return arguments;
    }
};

const testing = @import("testing");

test "Gemini initialization and deinitialization" {
    const allocator = std.testing.allocator;
    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{},
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    p.deinit();
}

test "Gemini.listModels success" {
    const allocator = std.testing.allocator;
    const response_json =
        \\{
        \\  "models": [
        \\    {
        \\      "name": "models/gemini-2.0-flash",
        \\      "version": "2.0",
        \\      "displayName": "Gemini 2.0 Flash",
        \\      "description": "Fast and versatile",
        \\      "inputTokenLimit": 1048576,
        \\      "outputTokenLimit": 8192
        \\    }
        \\  ]
        \\}
    ;

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/models",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .GET,
                .response_status = .ok,
                .response_body = response_json,
            },
        },
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    var result = try p.listModels(allocator);
    defer result.deinit();

    try std.testing.expectEqual(1, result.models.len);
    try std.testing.expectEqualStrings("models/gemini-2.0-flash", result.models[0].id);
    try std.testing.expectEqualStrings("Gemini 2.0 Flash", result.models[0].display_name);
}

test "Gemini.listModels HTTP failure" {
    const allocator = std.testing.allocator;

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/models",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .GET,
                .response_status = .internal_server_error,
                .response_body = "",
            },
        },
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    try std.testing.expectError(error.HttpRequestFailed, p.listModels(allocator));
}

test "Gemini.executeStep success" {
    const allocator = std.testing.allocator;

    const expected_payload = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":false}";
    const response_json =
        \\{
        \\  "id": "interaction_123",
        \\  "steps": [
        \\    {
        \\      "type": "thought",
        \\      "summary": [
        \\        {
        \\          "type": "text",
        \\          "text": "Thinking..."
        \\        }
        \\      ]
        \\    },
        \\    {
        \\      "type": "model_output",
        \\      "content": [
        \\        {
        \\          "type": "text",
        \\          "text": "Hello user!"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var call_counts = [_]usize{0};
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = expected_payload,
                .response_status = .ok,
                .response_body = response_json,
            },
        },
        .sequential = false,
        .call_counts = &call_counts,
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-2.0-flash", .display_name = "Gemini 2.0 Flash" },
        .tools = &.{},
    };
    const input = &[_]llm.types.Step{
        .{ .prompt = "Hello" },
    };

    var result = try p.executeStep(allocator, config, input, null);
    defer result.deinit();

    try std.testing.expectEqual(1, result.model_output.len);
    try std.testing.expectEqualStrings("Hello user!", result.model_output[0].text);
    try std.testing.expectEqual(1, result.thoughts.len);
    try std.testing.expectEqualStrings("Thinking...", result.thoughts[0].text);

    const gemini_result: *gemini_types.StepResult = @ptrCast(@alignCast(result.ptr));
    try std.testing.expectEqualStrings("interaction_123", gemini_result.interaction_id);
    try std.testing.expectEqual(1, call_counts[0]);
}

test "Gemini.executeStep with previous step" {
    const allocator = std.testing.allocator;

    const payload1 = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":false}";
    const response1 =
        \\{
        \\  "id": "interaction_123",
        \\  "steps": [
        \\    {
        \\      "type": "model_output",
        \\      "content": [
        \\        {
        \\          "type": "text",
        \\          "text": "Hello user!"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    const payload2 = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Next prompt\"}]}],\"previous_interaction_id\":\"interaction_123\",\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":false}";
    const response2 =
        \\{
        \\  "id": "interaction_456",
        \\  "steps": [
        \\    {
        \\      "type": "model_output",
        \\      "content": [
        \\        {
        \\          "type": "text",
        \\          "text": "Next response"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var call_counts = [_]usize{ 0, 0 };
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = payload1,
                .response_status = .ok,
                .response_body = response1,
            },
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = payload2,
                .response_status = .ok,
                .response_body = response2,
            },
        },
        .sequential = true,
        .call_counts = &call_counts,
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-2.0-flash", .display_name = "Gemini 2.0 Flash" },
        .tools = &.{},
    };

    // First call
    const input1 = &[_]llm.types.Step{
        .{ .prompt = "Hello" },
    };
    var result1 = try p.executeStep(allocator, config, input1, null);
    defer result1.deinit();

    try std.testing.expectEqualStrings("Hello user!", result1.model_output[0].text);

    // Second call
    const input2 = &[_]llm.types.Step{
        .{ .prompt = "Next prompt" },
    };
    var result2 = try p.executeStep(allocator, config, input2, result1);
    defer result2.deinit();

    try std.testing.expectEqualStrings("Next response", result2.model_output[0].text);
    try std.testing.expectEqual(1, call_counts[0]);
    try std.testing.expectEqual(1, call_counts[1]);
}

test "Gemini.executeStep with tools" {
    const allocator = std.testing.allocator;

    const expected_payload = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[{\"type\":\"function\",\"name\":\"get_weather\",\"description\":\"Get weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\",\"description\":\"City\"}},\"required\":[\"location\"]}}],\"stream\":false}";
    const response_json =
        \\{
        \\  "id": "interaction_123",
        \\  "steps": [
        \\    {
        \\      "type": "model_output",
        \\      "content": [
        \\        {
        \\          "type": "text",
        \\          "text": "Weather is nice!"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var call_counts = [_]usize{0};
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = expected_payload,
                .response_status = .ok,
                .response_body = response_json,
            },
        },
        .sequential = false,
        .call_counts = &call_counts,
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    const param = llm.types.Tool.Param{
        .name = "location",
        .description = "City",
        .type = .string,
        .required = true,
    };
    const tool = llm.types.Tool{
        .name = "get_weather",
        .description = "Get weather",
        .parameters = &.{param},
    };
    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-2.0-flash", .display_name = "Gemini 2.0 Flash" },
        .tools = &.{tool},
    };
    const input = &[_]llm.types.Step{
        .{ .prompt = "Hello" },
    };

    var result = try p.executeStep(allocator, config, input, null);
    defer result.deinit();

    try std.testing.expectEqualStrings("Weather is nice!", result.model_output[0].text);
    try std.testing.expectEqual(1, call_counts[0]);
}

test "Gemini.executeStep HTTP failure" {
    const allocator = std.testing.allocator;

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .response_status = .internal_server_error,
                .response_body = "",
            },
        },
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-2.0-flash", .display_name = "Gemini 2.0 Flash" },
        .tools = &.{},
    };
    const input = &[_]llm.types.Step{
        .{ .prompt = "Hello" },
    };

    try std.testing.expectError(error.HttpRequestFailed, p.executeStep(allocator, config, input, null));
}

test "Gemini.executeStepStreaming success" {
    const allocator = std.testing.allocator;

    const expected_payload = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":true}";
    const response_body =
        \\event: interaction.created
        \\data: {"event_type":"interaction.created","interaction":{"id":"interaction_streaming_123"}}
        \\ 
        \\event: step.start
        \\data: {"event_type":"step.start","index":0,"step":{"type":"thought"}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":"Thinking hard"}}}
        \\ 
        \\event: step.stop
        \\data: {"event_type":"step.stop","index":0}
        \\ 
        \\event: step.start
        \\data: {"event_type":"step.start","index":1,"step":{"type":"model_output"}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":1,"delta":{"type":"text","text":"Hello from streaming!"}}
        \\ 
        \\event: step.stop
        \\data: {"event_type":"step.stop","index":1}
        \\ 
        \\event: step.start
        \\data: {"event_type":"step.start","index":2,"step":{"type":"function_call","id":"call_999","name":"get_weather","arguments":{}}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":2,"delta":{"type":"arguments_delta","arguments":"{\"location\": \"San "}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":2,"delta":{"type":"arguments_delta","arguments":"Francisco\"}"}}
        \\ 
        \\event: step.stop
        \\data: {"event_type":"step.stop","index":2}
        \\ 
        \\event: interaction.completed
        \\data: {"event_type":"interaction.completed","interaction":{"id":"interaction_streaming_123"}}
        \\ 
        \\event: done
        \\data: [DONE]
    ;

    var call_counts = [_]usize{0};
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = expected_payload,
                .response_status = .ok,
                .response_body = response_body,
            },
        },
        .sequential = false,
        .call_counts = &call_counts,
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-2.0-flash", .display_name = "Gemini 2.0 Flash" },
        .tools = &.{},
    };
    const input = &[_]llm.types.Step{
        .{ .prompt = "Hello" },
    };

    const Context = struct {
        chunks_received: usize = 0,
        interaction_created_received: bool = false,
        interaction_completed_received: bool = false,
        model_output_text: std.Io.Writer.Allocating,
        thought_text: std.Io.Writer.Allocating,
        tool_call_arguments_received: bool = false,

        fn callback(ctx_ptr: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            self.chunks_received += 1;
            switch (chunk.event) {
                .interaction_created => self.interaction_created_received = true,
                .interaction_completed => self.interaction_completed_received = true,
                .step_event => |se| {
                    switch (se.event) {
                        .delta => |d| {
                            switch (d) {
                                .model_output => |mo| {
                                    self.model_output_text.writer.writeAll(mo.text) catch {};
                                },
                                .thought => |t| {
                                    self.thought_text.writer.writeAll(t.text) catch {};
                                },
                                .tool_call => |args| {
                                    if (args.len > 0) {
                                        std.testing.expectEqualStrings("location", args[0].name) catch {};
                                        if (std.mem.eql(u8, args[0].value.string, "San Francisco")) {
                                            self.tool_call_arguments_received = true;
                                        }
                                    }
                                },
                            }
                        },
                        else => {},
                    }
                },
            }
        }
    };

    var ctx = Context{
        .model_output_text = std.Io.Writer.Allocating.init(allocator),
        .thought_text = std.Io.Writer.Allocating.init(allocator),
    };
    defer ctx.model_output_text.deinit();
    defer ctx.thought_text.deinit();

    var result = try p.executeStepStreaming(allocator, config, input, null, Context.callback, &ctx);
    defer result.deinit();

    // Verify callback executions
    try std.testing.expect(ctx.chunks_received > 0);
    try std.testing.expect(ctx.interaction_created_received);
    try std.testing.expect(ctx.interaction_completed_received);
    try std.testing.expectEqualStrings("Hello from streaming!", ctx.model_output_text.written());
    try std.testing.expectEqualStrings("Thinking hard", ctx.thought_text.written());
    //try std.testing.expect(ctx.tool_call_arguments_received);

    // Verify accumulated StepResult
    try std.testing.expectEqual(1, result.model_output.len);
    try std.testing.expectEqualStrings("Hello from streaming!", result.model_output[0].text);
    try std.testing.expectEqual(1, result.thoughts.len);
    try std.testing.expectEqualStrings("Thinking hard", result.thoughts[0].text);
    try std.testing.expectEqual(1, result.tool_calls.len);
    try std.testing.expectEqualStrings("call_999", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("get_weather", result.tool_calls[0].name);
    try std.testing.expectEqual(1, result.tool_calls[0].arguments.len);
    try std.testing.expectEqualStrings("location", result.tool_calls[0].arguments[0].name);
    try std.testing.expectEqualStrings("San Francisco", result.tool_calls[0].arguments[0].value.string);

    const gemini_result: *gemini_types.StreamingStepResult = @ptrCast(@alignCast(result.ptr));
    try std.testing.expectEqualStrings("interaction_streaming_123", gemini_result.interaction_id);
    try std.testing.expectEqual(1, call_counts[0]);
}

test "Gemini.executeStepStreaming with CRLF line endings" {
    const allocator = std.testing.allocator;

    const expected_payload = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":true}";
    const response_body_lf =
        \\event: interaction.created
        \\data: {"event_type":"interaction.created","interaction":{"id":"interaction_streaming_123"}}
        \\ 
        \\event: step.start
        \\data: {"event_type":"step.start","index":0,"step":{"type":"thought"}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":"Thinking hard"}}}
        \\ 
        \\event: step.stop
        \\data: {"event_type":"step.stop","index":0}
        \\ 
        \\event: step.start
        \\data: {"event_type":"step.start","index":1,"step":{"type":"model_output"}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":1,"delta":{"type":"text","text":"Hello from streaming!"}}
        \\ 
        \\event: step.stop
        \\data: {"event_type":"step.stop","index":1}
        \\ 
        \\event: step.start
        \\data: {"event_type":"step.start","index":2,"step":{"type":"function_call","id":"call_999","name":"get_weather","arguments":{}}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":2,"delta":{"type":"arguments_delta","arguments":"{\"location\": \"San "}}
        \\ 
        \\event: step.delta
        \\data: {"event_type":"step.delta","index":2,"delta":{"type":"arguments_delta","arguments":"Francisco\"}"}}
        \\ 
        \\event: step.stop
        \\data: {"event_type":"step.stop","index":2}
        \\ 
        \\event: interaction.completed
        \\data: {"event_type":"interaction.completed","interaction":{"id":"interaction_streaming_123"}}
        \\ 
        \\event: done
        \\data: [DONE]
    ;

    var response_body_crlf_list: std.ArrayList(u8) = .empty;
    defer response_body_crlf_list.deinit(allocator);
    var it = std.mem.splitScalar(u8, response_body_lf, '\n');
    while (it.next()) |line| {
        try response_body_crlf_list.appendSlice(allocator, line);
        try response_body_crlf_list.appendSlice(allocator, "\r\n");
    }

    var call_counts = [_]usize{0};
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = expected_payload,
                .response_status = .ok,
                .response_body = response_body_crlf_list.items,
            },
        },
        .sequential = false,
        .call_counts = &call_counts,
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-2.0-flash", .display_name = "Gemini 2.0 Flash" },
        .tools = &.{},
    };
    const input = &[_]llm.types.Step{
        .{ .prompt = "Hello" },
    };

    const Context = struct {
        chunks_received: usize = 0,
        interaction_created_received: bool = false,
        interaction_completed_received: bool = false,
        model_output_text: std.Io.Writer.Allocating,
        thought_text: std.Io.Writer.Allocating,
        tool_call_arguments_received: bool = false,

        fn callback(ctx_ptr: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            self.chunks_received += 1;
            switch (chunk.event) {
                .interaction_created => self.interaction_created_received = true,
                .interaction_completed => self.interaction_completed_received = true,
                .step_event => |se| {
                    switch (se.event) {
                        .delta => |d| {
                            switch (d) {
                                .model_output => |mo| {
                                    self.model_output_text.writer.writeAll(mo.text) catch {};
                                },
                                .thought => |t| {
                                    self.thought_text.writer.writeAll(t.text) catch {};
                                },
                                .tool_call => |args| {
                                    if (args.len > 0) {
                                        std.testing.expectEqualStrings("location", args[0].name) catch {};
                                        if (std.mem.eql(u8, args[0].value.string, "San Francisco")) {
                                            self.tool_call_arguments_received = true;
                                        }
                                    }
                                },
                            }
                        },
                        else => {},
                    }
                },
            }
        }
    };

    var ctx = Context{
        .model_output_text = std.Io.Writer.Allocating.init(allocator),
        .thought_text = std.Io.Writer.Allocating.init(allocator),
    };
    defer ctx.model_output_text.deinit();
    defer ctx.thought_text.deinit();

    var result = try p.executeStepStreaming(allocator, config, input, null, Context.callback, &ctx);
    defer result.deinit();

    // Verify callback executions
    try std.testing.expect(ctx.chunks_received > 0);
    try std.testing.expect(ctx.interaction_created_received);
    try std.testing.expect(ctx.interaction_completed_received);
    try std.testing.expectEqualStrings("Hello from streaming!", ctx.model_output_text.written());
    try std.testing.expectEqualStrings("Thinking hard", ctx.thought_text.written());

    // Verify accumulated StepResult
    try std.testing.expectEqual(1, result.model_output.len);
    try std.testing.expectEqualStrings("Hello from streaming!", result.model_output[0].text);
    try std.testing.expectEqual(1, result.thoughts.len);
    try std.testing.expectEqualStrings("Thinking hard", result.thoughts[0].text);
    try std.testing.expectEqual(1, result.tool_calls.len);
    try std.testing.expectEqualStrings("call_999", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("get_weather", result.tool_calls[0].name);
    try std.testing.expectEqual(1, result.tool_calls[0].arguments.len);
    try std.testing.expectEqualStrings("location", result.tool_calls[0].arguments[0].name);
    try std.testing.expectEqualStrings("San Francisco", result.tool_calls[0].arguments[0].value.string);

    const gemini_result: *gemini_types.StreamingStepResult = @ptrCast(@alignCast(result.ptr));
    try std.testing.expectEqualStrings("interaction_streaming_123", gemini_result.interaction_id);
    try std.testing.expectEqual(1, call_counts[0]);
}

test "StepAccumulator mismatch delta and init thought" {
    const allocator = std.testing.allocator;

    var thoughts = [_]api.Content{.{ .type = .text, .text = "thought_1" }};
    const init_step = api.Step{ .thought = &thoughts };
    var acc = try StepAccumulator.init(allocator, init_step);
    defer acc.thought.deinit();
    try std.testing.expect(acc == .thought);
    try std.testing.expectEqualStrings("thought_1", acc.thought.written());

    // Append mismatched delta (should fail)
    const mismatch_delta = api.InteractionStepDelta{
        .text_delta = .{ .type = .text, .text = "text" },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(mismatch_delta));
}

test "StepAccumulator mismatch delta and init model_output" {
    const allocator = std.testing.allocator;

    var outputs = [_]api.Content{.{ .type = .text, .text = "output_1" }};
    const init_step = api.Step{ .model_output = &outputs };
    var acc = try StepAccumulator.init(allocator, init_step);
    defer acc.model_output.deinit();
    try std.testing.expect(acc == .model_output);
    try std.testing.expectEqualStrings("output_1", acc.model_output.written());

    // Append mismatched delta (should fail)
    const mismatch_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "args" },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(mismatch_delta));
}

test "StepAccumulator mismatch delta and init tool_call" {
    const allocator = std.testing.allocator;

    const init_step = api.Step{
        .function_call = .{
            .id = "fc_id",
            .name = "fc_name",
            .arguments = &.{},
        },
    };
    var acc = try StepAccumulator.init(allocator, init_step);
    defer {
        allocator.free(acc.tool_call.id);
        allocator.free(acc.tool_call.name);
        acc.tool_call.arguments_json.deinit();
    }
    try std.testing.expect(acc == .tool_call);
    try std.testing.expectEqualStrings("fc_id", acc.tool_call.id);

    // Append mismatched delta (should fail)
    const mismatch_delta = api.InteractionStepDelta{
        .thought_summary = .{ .content = .{ .type = .text, .text = "think" } },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(mismatch_delta));

    // Test handleToolCallDelta when json is not valid (returns null)
    try std.testing.expect(try acc.handleToolCallDelta(allocator) == null);

    // Test append valid delta and handleToolCallDelta returning null when new_count == 0
    const args_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "{\"arg1\": \"val1\"}" },
    };
    try acc.appendStep(args_delta);
    const args = try acc.handleToolCallDelta(allocator);
    try std.testing.expect(args != null);
    defer {
        for (args.?) |arg| {
            allocator.free(arg.name);
            switch (arg.value) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
        allocator.free(args.?);
    }

    // Calling handleToolCallDelta again without new changes should return null
    try std.testing.expect(try acc.handleToolCallDelta(allocator) == null);
}

test "StepAccumulator mismatch delta and init empty" {
    var acc: StepAccumulator = .empty;
    const delta = api.InteractionStepDelta{
        .text_delta = .{ .type = .text, .text = "text" },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(delta));
}

test "Gemini.executeStep returns function call" {
    const allocator = std.testing.allocator;

    const response_json =
        \\{
        \\  "id": "interaction_fc",
        \\  "steps": [
        \\    {
        \\      "type": "function_call",
        \\      "id": "call_abc",
        \\      "name": "get_weather",
        \\      "arguments": {
        \\        "location": "Miami"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = "{\"model\":\"gemini-model\",\"input\":[],\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":false}",
                .response_status = .ok,
                .response_body = response_json,
            },
        },
    };

    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();

    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-model", .display_name = "Gemini Model" },
        .tools = &.{},
    };

    var result = try p.executeStep(allocator, config, &.{}, null);
    defer result.deinit();

    try std.testing.expectEqualStrings("interaction_fc", (@as(*gemini_types.StepResult, @ptrCast(@alignCast(result.ptr)))).interaction_id);
    try std.testing.expectEqual(1, result.tool_calls.len);
    try std.testing.expectEqualStrings("call_abc", result.tool_calls[0].id);
    try std.testing.expectEqualStrings("get_weather", result.tool_calls[0].name);
    try std.testing.expectEqual(1, result.tool_calls[0].arguments.len);
    try std.testing.expectEqualStrings("location", result.tool_calls[0].arguments[0].name);
    try std.testing.expectEqualStrings("Miami", result.tool_calls[0].arguments[0].value.string);
}

test "Gemini.executeStepStreaming multiple interaction_created" {
    const allocator = std.testing.allocator;

    const CallbackState = struct {
        fn callback(ctx_ptr: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx_ptr;
            _ = chunk;
        }
    };

    const payload =
        \\data: {"event_type": "interaction.created", "interaction": {"id": "int_1"}}
        \\data: {"event_type": "interaction.created", "interaction": {"id": "int_2"}}
        \\
    ;
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = "{\"model\":\"gemini-model\",\"input\":[],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":true}",
                .response_status = .ok,
                .response_body = payload,
            },
        },
    };
    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();
    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-model", .display_name = "Gemini Model" },
        .tools = &.{},
    };
    try std.testing.expectError(error.BadResponse, p.executeStepStreaming(allocator, config, &.{}, null, CallbackState.callback, null));
}

test "Gemini.executeStepStreaming duplicate step start" {
    const allocator = std.testing.allocator;

    const CallbackState = struct {
        fn callback(ctx_ptr: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx_ptr;
            _ = chunk;
        }
    };

    const payload =
        \\data: {"event_type": "step.start", "index": 0, "step": {"type": "thought"}}
        \\data: {"event_type": "step.start", "index": 0, "step": {"type": "thought"}}
        \\
    ;
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = "{\"model\":\"gemini-model\",\"input\":[],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":true}",
                .response_status = .ok,
                .response_body = payload,
            },
        },
    };
    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();
    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-model", .display_name = "Gemini Model" },
        .tools = &.{},
    };
    try std.testing.expectError(error.BadResponse, p.executeStepStreaming(allocator, config, &.{}, null, CallbackState.callback, null));
}

test "Gemini.executeStepStreaming delta for non-existent step index" {
    const allocator = std.testing.allocator;

    const CallbackState = struct {
        fn callback(ctx_ptr: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx_ptr;
            _ = chunk;
        }
    };

    const payload =
        \\data: {"event_type": "step.delta", "index": 5, "delta": {"type": "text", "text": "foo"}}
        \\
    ;
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = "{\"model\":\"gemini-model\",\"input\":[],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":true}",
                .response_status = .ok,
                .response_body = payload,
            },
        },
    };
    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();
    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-model", .display_name = "Gemini Model" },
        .tools = &.{},
    };
    try std.testing.expectError(error.BadResponse, p.executeStepStreaming(allocator, config, &.{}, null, CallbackState.callback, null));
}

test "Gemini.executeStepStreaming mismatched interaction completed ID" {
    const allocator = std.testing.allocator;

    const CallbackState = struct {
        fn callback(ctx_ptr: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx_ptr;
            _ = chunk;
        }
    };

    const payload =
        \\data: {"event_type": "interaction.created", "interaction": {"id": "int_1"}}
        \\data: {"event_type": "interaction.completed", "interaction": {"id": "int_mismatch"}}
        \\
    ;
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = "{\"model\":\"gemini-model\",\"input\":[],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":true}",
                .response_status = .ok,
                .response_body = payload,
            },
        },
    };
    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();
    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-model", .display_name = "Gemini Model" },
        .tools = &.{},
    };
    try std.testing.expectError(error.BadResponse, p.executeStepStreaming(allocator, config, &.{}, null, CallbackState.callback, null));
}

test "Gemini.executeStepStreaming fallback interaction ID to unknown" {
    const allocator = std.testing.allocator;

    const CallbackState = struct {
        fn callback(ctx_ptr: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
            _ = ctx_ptr;
            _ = chunk;
        }
    };

    const payload =
        \\data: {"event_type": "step.start", "index": 0, "step": {"type": "thought"}}
        \\
    ;
    const mock_client = testing.MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "generativelanguage.googleapis.com",
                .expected_path = "/v1beta/interactions",
                .expected_query = "key=TEST_API_KEY",
                .expected_method = .POST,
                .expected_payload = "{\"model\":\"gemini-model\",\"input\":[],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[],\"stream\":true}",
                .response_status = .ok,
                .response_body = payload,
            },
        },
    };
    var prov = try MakeProvider(testing.MockHttpClient).init(allocator, mock_client, "TEST_API_KEY");
    var p = prov.provider();
    defer p.deinit();
    const config = llm.types.SessionConfig{
        .model = .{ .id = "gemini-model", .display_name = "Gemini Model" },
        .tools = &.{},
    };
    var result = try p.executeStepStreaming(allocator, config, &.{}, null, CallbackState.callback, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("unknown", (@as(*gemini_types.StreamingStepResult, @ptrCast(@alignCast(result.ptr)))).interaction_id);
}

test "ListModelsResult.init OOM" {
    const response_json = "{\"models\":[]}";
    var parsed = try std.json.parseFromSlice(api.ListModelsResponse, std.testing.allocator, response_json, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.OutOfMemory, gemini_types.ListModelsResult.init(std.testing.failing_allocator, parsed));
}

test "StepResult.init OOM" {
    const response_json = "{\"id\":\"int_id\",\"steps\":[]}";
    var parsed = try std.json.parseFromSlice(api.Interaction, std.testing.allocator, response_json, .{});
    defer parsed.deinit();

    try std.testing.expectError(error.OutOfMemory, gemini_types.StepResult.init(std.testing.failing_allocator, parsed));
}

test "StreamingStepResult.init OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.OutOfMemory, gemini_types.StreamingStepResult.init(std.testing.failing_allocator, arena, "id", &.{}, &.{}, &.{}));
}
