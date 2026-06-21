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

fn MakeProvider(comptime ClientType: type) type {
    return struct {
        allocator: Allocator,
        rpc_client: MakeJsonClient(ClientType),
        api_key: []const u8,

        const Self = @This();

        pub fn init(allocator: Allocator, http_client: ClientType, api_key: []const u8) !Self {
            return .{
                .allocator = allocator,
                .rpc_client = .{
                    .http_client = http_client,
                },
                .api_key = try allocator.dupe(u8, api_key),
            };
        }

        pub fn provider(self: *Self) Provider {
            return .{ .ptr = self, .vtable = &.{ .list_models = listModels, .execute_step = executeStep, .deinit = deinit } };
        }

        pub fn deinit(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.allocator.free(self.api_key);
            self.* = undefined;
        }

        /// Lists all available Gemini models.
        pub fn listModels(ctx: *anyopaque, allocator: Allocator) !llm.types.ListModelsResult {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const str_uri = try makeUri(allocator, .{ .path = &.{"models"}, .api_key = self.api_key });
            defer allocator.free(str_uri);
            const uri = std.Uri.parse(str_uri) catch return ProviderError.BadUri;

            const response = self.rpc_client.getRequest(allocator, api.ListModelsResponse, uri) catch return ProviderError.HttpRequestFailed;
            return try gemini_types.ListModelsResult.init(allocator, response);
        }

        pub fn executeStep(ctx: *anyopaque, allocator: Allocator, session_config: llm.types.SessionConfig, input: []const llm.types.Step, previous_step: ?llm.types.StepResult) !llm.types.StepResult {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const previous_gemini_step: ?*gemini_types.StepResult = if (previous_step) |step| @ptrCast(@alignCast(step.ptr)) else null;

            var tools: []api.Tool = &.{};
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();
            if (session_config.tools.len > 0) {
                tools = try arena_allocator.alloc(api.Tool, session_config.tools.len);
                for (session_config.tools, 0..) |tool, i| {
                    tools[i] = try converter.toGoogleTool(arena_allocator, tool);
                }
            }

            const str_uri = try makeUri(allocator, .{ .path = &.{"interactions"}, .api_key = self.api_key });
            defer allocator.free(str_uri);
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
            };

            const response = self.rpc_client.postRequest(allocator, api.CreateInteractionRequest, api.Interaction, uri, request_payload) catch return ProviderError.HttpRequestFailed;
            return try gemini_types.StepResult.init(allocator, response);
        }
    };
}

const testing = @import("testing");

test "Gemini initialization and deinitialization" {
    const allocator = std.testing.allocator;
    const mock_client: testing.MockHttpClient = .{
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

    const expected_payload = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[]}";
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

    const payload1 = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[]}";
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

    const payload2 = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Next prompt\"}]}],\"previous_interaction_id\":\"interaction_123\",\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[]}";
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

    const expected_payload = "{\"model\":\"gemini-2.0-flash\",\"input\":[{\"type\":\"user_input\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}],\"previous_interaction_id\":null,\"generation_config\":{\"thinking_summaries\":\"auto\"},\"tools\":[{\"type\":\"function\",\"name\":\"get_weather\",\"description\":\"Get weather\",\"parameters\":{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\",\"description\":\"City\"}},\"required\":[\"location\"]}}]}";
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
