const std = @import("std");
const provider = @import("provider");
const llm = @import("llm");

const coma = @import("coma");

/// Loads the GEMINI_API_KEY from the environment variables.
/// If not found, it attempts to read it from a `.env` file in the current working directory.
/// Returns an allocated string containing the API key, or `error.ApiKeyMissing` if not found.
fn loadApiKey(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("GEMINI_API_KEY")) |env_val| {
        return try allocator.dupe(u8, env_val);
    }

    var file = std.Io.Dir.openFile(.cwd(), io, ".env", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Error: GEMINI_API_KEY environment variable is not set, and no .env file was found.\n", .{});
            return error.ApiKeyMissing;
        },
        else => |e| return e,
    };
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    while (try file_reader.interface.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var it = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, it.first(), " \t");
        if (std.mem.eql(u8, key, "GEMINI_API_KEY")) {
            const val = std.mem.trim(u8, it.rest(), " \t");
            const cleaned = std.mem.trim(u8, val, "\"'");
            return try allocator.dupe(u8, cleaned);
        }
    }

    std.debug.print("Error: GEMINI_API_KEY environment variable is not set, and was not found in the .env file.\n", .{});
    return error.ApiKeyMissing;
}

/// The main entry point of the application.
/// Currently used for testing.
pub fn main(init: std.process.Init) !void {
    // 1. Initialize an allocator for memory management
    var allocator = init.gpa;
    const io = init.io;

    const api_key = loadApiKey(allocator, io, init.environ_map) catch |err| {
        if (err == error.ApiKeyMissing) {
            std.process.exit(1);
        }
        return err;
    };
    defer allocator.free(api_key);

    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();
    var gemini_client: provider.Gemini = try .init(allocator, &http_client, api_key);
    var client = gemini_client.provider();
    defer client.deinit();

    var models_list = try client.listModels(allocator);
    defer models_list.deinit();
    const models = models_list.models;
    var selected_model: ?llm.types.Model = null;

    selected_model = for (models) |model| {
        std.debug.print("Model: {s}\n", .{model.display_name});
        if (std.mem.containsAtLeast(u8, model.display_name, 1, "3 Flash")) {
            break model;
        }
    } else unreachable;

    const session_config: llm.types.SessionConfig = .{
        .model = selected_model.?,
        .tools = &.{
            .{
                .name = "execute_typescript",
                .description = "Executes typescript code and returns the output printed to stdout. Takes a single string argument.",
                .parameters = &.{
                    .{
                        .name = "code",
                        .type = .string,
                        .required = true,
                        .description = "The typescript code to execute.",
                    },
                },
            },
        },
    };

    std.debug.print("Selected: {s}\n", .{selected_model.?.id});

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);

    // 2. Read until the user hits Enter ('\n')
    // This returns a slice of the buffer containing the raw string
    var last_step: ?llm.types.StepResult = null;
    var last_tool_results: std.ArrayList(llm.types.ToolResult) = .empty;
    defer last_tool_results.deinit(allocator);
    while (true) {
        var new_steps: std.ArrayList(llm.types.Step) = .empty;
        defer new_steps.deinit(allocator);

        if (last_step == null or last_step.?.tool_calls.len == 0) {
            const user_input = try stdin_reader.interface.takeDelimiter('\n') orelse break;
            if (user_input.len == 0) break;
            try new_steps.append(allocator, .{ .prompt = user_input });
        } else {
            for (last_step.?.tool_calls) |tool_call| {
                if (std.mem.eql(u8, tool_call.name, "execute_typescript")) {
                    const code = tool_call.arguments[0].value;
                    std.debug.print("Executing: {s}\n", .{code});
                    const argv = [_][]const u8{
                        "npx", "tsx", "-e", code,
                    };
                    const result = try std.process.run(allocator, io, .{
                        .argv = &argv,
                    });

                    if (result.term == .exited) {
                        const tool_result: llm.types.ToolResult = .{
                            .tool_name = tool_call.name,
                            .id = tool_call.id,
                            .result = result.stdout,
                        };
                        try last_tool_results.append(allocator, tool_result);
                        try new_steps.append(allocator, .{ .tool_result = tool_result });
                        allocator.free(result.stderr);
                    }
                }
            }
        }

        const step_result = try client.executeStepStreaming(allocator, session_config, new_steps.items, last_step, struct {
            pub fn lambda(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
                const alloc: *std.mem.Allocator = @ptrCast(@alignCast(ctx));
                var payload_buffer: std.Io.Writer.Allocating = .init(alloc.*);
                defer payload_buffer.deinit();
                var stringifier = std.json.Stringify{
                    .writer = &payload_buffer.writer,
                    .options = .{},
                };
                stringifier.write(chunk.event) catch return;
                std.debug.print("Chunk: {s}\n", .{payload_buffer.written()});
            }
        }.lambda, &allocator);
        errdefer step_result.deinit();

        for (last_tool_results.items) |tool_call| {
            allocator.free(tool_call.result);
        }
        last_tool_results.clearRetainingCapacity();

        for (step_result.thoughts) |thought| {
            std.debug.print("Thinking: {s}\n", .{thought.text});
        }

        for (step_result.model_output) |content| {
            switch (content) {
                .text => |text| std.debug.print("Response: {s}\n", .{text}),
            }
        }

        if (last_step) |*last| {
            last.deinit();
        }
        last_step = step_result;
    }

    if (last_step) |*last| {
        last.deinit();
    }
}

test {
    std.testing.refAllDecls(@This());
}
