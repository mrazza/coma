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
