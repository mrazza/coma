const std = @import("std");
const provider = @import("provider");
const llm = @import("llm");

const coma = @import("coma");

const color_reset = "\x1b[0m";
const color_bold = "\x1b[1m";
const color_gray = "\x1b[90m";
const color_blue = "\x1b[34m";
const color_cyan = "\x1b[36m";
const color_green = "\x1b[32m";
const color_yellow = "\x1b[33m";

const StreamContext = struct {
    allocator: std.mem.Allocator,
    current_type: ?llm.types.StepType = null,
};

fn streamCallback(ctx: ?*anyopaque, chunk: llm.types.StreamingChunk) void {
    const stream_ctx: *StreamContext = @ptrCast(@alignCast(ctx));
    switch (chunk.event) {
        .interaction_created => {},
        .step_event => |step_ev| {
            switch (step_ev.event) {
                .start => |start_payload| {
                    switch (start_payload) {
                        .thought => {
                            if (stream_ctx.current_type != .thought) {
                                std.debug.print("{s}Thinking...{s}\n", .{ color_gray, color_reset });
                                stream_ctx.current_type = .thought;
                            }
                        },
                        .model_output => {
                            if (stream_ctx.current_type != .model_output) {
                                std.debug.print("\n{s}Agent >{s} ", .{ color_cyan ++ color_bold, color_reset });
                                stream_ctx.current_type = .model_output;
                            }
                        },
                        .tool_call => |tc| {
                            if (stream_ctx.current_type != .tool_call) {
                                std.debug.print("\n{s}[Tool Call: {s}]{s}\n", .{ color_yellow, tc.name, color_reset });
                                stream_ctx.current_type = .tool_call;
                            }
                        },
                    }
                },
                .delta => |delta| {
                    switch (delta) {
                        .thought => |thought| {
                            if (stream_ctx.current_type != .thought) {
                                std.debug.print("{s}Thinking...{s}\n", .{ color_gray, color_reset });
                                stream_ctx.current_type = .thought;
                            }
                            std.debug.print("{s}{s}{s}", .{ color_gray, thought.text, color_reset });
                        },
                        .model_output => |mo| {
                            if (stream_ctx.current_type != .model_output) {
                                std.debug.print("\n{s}Agent >{s} ", .{ color_cyan ++ color_bold, color_reset });
                                stream_ctx.current_type = .model_output;
                            }
                            switch (mo) {
                                .text => |text| {
                                    std.debug.print("{s}", .{text});
                                },
                            }
                        },
                        .tool_call => |args| {
                            _ = args;
                        },
                    }
                },
                .end => {},
            }
        },
        .interaction_completed => {},
    }
}

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

    std.debug.print(
        \\{s}============================================================================
        \\                    COMA Agent Chat Interface
        \\============================================================================
        \\Model: {s} ({s})
        \\Type a prompt and press Enter.
        \\Press Ctrl+D or leave empty and press Enter to exit.
        \\============================================================================{s}
        \\
    , .{ color_cyan, selected_model.?.display_name, selected_model.?.id, color_reset });

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
            std.debug.print("\n{s}User > {s}", .{ color_green ++ color_bold, color_reset });
            const user_input = try stdin_reader.interface.takeDelimiter('\n') orelse break;
            if (user_input.len == 0) break;
            try new_steps.append(allocator, .{ .prompt = user_input });
        } else {
            for (last_step.?.tool_calls) |tool_call| {
                if (std.mem.eql(u8, tool_call.name, "execute_typescript")) {
                    const code = tool_call.arguments[0].value;
                    std.debug.print("\n{s}Executing TypeScript code...{s}\n", .{ color_yellow, color_reset });
                    std.debug.print("{s}--- CODE ---{s}\n{s}\n{s}------------{s}\n", .{ color_gray, color_reset, code, color_gray, color_reset });
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
                        std.debug.print("{s}Output:{s}\n{s}", .{ color_green, color_reset, result.stdout });
                        try last_tool_results.append(allocator, tool_result);
                        try new_steps.append(allocator, .{ .tool_result = tool_result });
                        allocator.free(result.stderr);
                    }
                }
            }
        }

        var stream_ctx = StreamContext{ .allocator = allocator };
        const step_result = try client.executeStepStreaming(allocator, session_config, new_steps.items, last_step, streamCallback, &stream_ctx);
        errdefer step_result.deinit();

        for (last_tool_results.items) |tool_call| {
            allocator.free(tool_call.result);
        }
        last_tool_results.clearRetainingCapacity();

        if (stream_ctx.current_type != null) {
            std.debug.print("\n", .{});
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
