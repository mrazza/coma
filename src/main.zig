const std = @import("std");
const provider = @import("provider");
const llm = @import("llm");
const agent_pkg = @import("agent");
const Agent = agent_pkg.Agent;
const Tool = agent_pkg.Tool;
const types = agent_pkg.types;

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
    in_code_block: bool = false,
    in_inline_code: bool = false,
    in_bold: bool = false,
    in_italic: bool = false,
    backtick_count: u8 = 0,
    asterisk_count: u8 = 0,
};

fn restoreStyle(stream_ctx: *StreamContext) void {
    if (stream_ctx.in_code_block) {
        std.debug.print("{s}", .{color_yellow});
    } else if (stream_ctx.in_inline_code) {
        std.debug.print("{s}", .{color_yellow});
    } else {
        if (stream_ctx.current_type) |t| {
            switch (t) {
                .thought => std.debug.print("{s}", .{color_gray}),
                .model_output => std.debug.print("{s}", .{color_reset}),
                .tool_call => std.debug.print("{s}", .{color_yellow}),
            }
        }
    }
}

fn flushBackticks(stream_ctx: *StreamContext) void {
    const count = stream_ctx.backtick_count;
    if (count == 0) return;
    stream_ctx.backtick_count = 0;
    if (count == 3) {
        stream_ctx.in_code_block = !stream_ctx.in_code_block;
        if (stream_ctx.in_code_block) {
            std.debug.print("{s}", .{color_yellow});
        } else {
            std.debug.print("{s}", .{color_reset});
            restoreStyle(stream_ctx);
        }
    } else if (count == 1) {
        stream_ctx.in_inline_code = !stream_ctx.in_inline_code;
        if (stream_ctx.in_inline_code) {
            std.debug.print("{s}", .{color_yellow});
        } else {
            std.debug.print("{s}", .{color_reset});
            restoreStyle(stream_ctx);
        }
    } else {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            std.debug.print("`", .{});
        }
    }
}

fn flushAsterisks(stream_ctx: *StreamContext) void {
    const count = stream_ctx.asterisk_count;
    if (count == 0) return;
    stream_ctx.asterisk_count = 0;
    if (count == 2) {
        stream_ctx.in_bold = !stream_ctx.in_bold;
        if (stream_ctx.in_bold) {
            std.debug.print("{s}", .{color_bold});
        } else {
            std.debug.print("{s}", .{color_reset});
            restoreStyle(stream_ctx);
        }
    } else if (count == 1) {
        stream_ctx.in_italic = !stream_ctx.in_italic;
        if (stream_ctx.in_italic) {
            std.debug.print("\x1b[3m", .{});
        } else {
            std.debug.print("\x1b[23m", .{});
        }
    } else {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            std.debug.print("*", .{});
        }
    }
}

fn printMarkdown(stream_ctx: *StreamContext, text: []const u8) void {
    restoreStyle(stream_ctx);
    for (text) |char| {
        if (char == '`') {
            flushAsterisks(stream_ctx);
            stream_ctx.backtick_count += 1;
            continue;
        }
        if (char == '*') {
            flushBackticks(stream_ctx);
            stream_ctx.asterisk_count += 1;
            continue;
        }

        flushBackticks(stream_ctx);
        flushAsterisks(stream_ctx);
        std.debug.print("{c}", .{char});
    }
}

fn streamCallback(ctx: ?*anyopaque, agent_chunk: agent_pkg.types.StreamingChunk) void {
    const stream_ctx: *StreamContext = @ptrCast(@alignCast(ctx));
    switch (agent_chunk) {
        .model_chunk => |chunk| {
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
                                    printMarkdown(stream_ctx, thought.text);
                                },
                                .model_output => |mo| {
                                    if (stream_ctx.current_type != .model_output) {
                                        std.debug.print("\n{s}Agent >{s} ", .{ color_cyan ++ color_bold, color_reset });
                                        stream_ctx.current_type = .model_output;
                                    }
                                    switch (mo) {
                                        .text => |text| {
                                            printMarkdown(stream_ctx, text);
                                        },
                                    }
                                },
                                .tool_call => |args| {
                                    for (args) |arg| {
                                        switch (arg.value) {
                                            .string => |s| std.debug.print("  {s}: \"{s}\"\n", .{ arg.name, s }),
                                            .integer => |i| std.debug.print("  {s}: {}\n", .{ arg.name, i }),
                                            .float => |f| std.debug.print("  {s}: {d}\n", .{ arg.name, f }),
                                            .boolean => |b| std.debug.print("  {s}: {}\n", .{ arg.name, b }),
                                        }
                                    }
                                },
                            }
                        },
                        .end => {},
                    }
                },
                .interaction_completed => {
                    flushBackticks(stream_ctx);
                    flushAsterisks(stream_ctx);
                },
            }
        },
        .tool_result => |tr| {
            std.debug.print("{s}Output:{s}\n{s}\n", .{ color_green, color_reset, tr.result });
        },
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

// TODO(razza): Get rid of global IO and make it an optional argument (like Allocator) to tools.
threadlocal var global_io: std.Io = undefined;

fn executeTypescript(allocator: std.mem.Allocator, code: []const u8) ![]const u8 {
    const argv = [_][]const u8{
        "npx", "tsx", "-e", code,
    };
    const result = std.process.run(allocator, global_io, .{
        .argv = &argv,
    }) catch |err| {
        return try std.fmt.allocPrint(allocator, "Error executing script: {}", .{err});
    };
    errdefer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    allocator.free(result.stderr);

    if (result.term != .exited) {
        allocator.free(result.stdout);
        return try allocator.dupe(u8, "Error: process did not exit cleanly");
    }

    return result.stdout;
}

fn getWeather(allocator: std.mem.Allocator, zip_code: i64) ![]const u8 {
    const result_str = if (zip_code == 7302)
        try allocator.dupe(u8, "Weather report for 07302: Sunny, 72°F, Humidity 50%, Wind 5 mph")
    else
        try std.fmt.allocPrint(allocator, "Error: Weather data is only available for zip code 07302. Requested: {}", .{zip_code});

    return result_str;
}

/// The main entry point of the application.
/// Currently used for testing.
pub fn main(init: std.process.Init) !void {
    // 1. Initialize an allocator for memory management
    var allocator = init.gpa;
    const io = init.io;
    global_io = io;

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

    const execute_typescript_desc = llm.types.Tool{
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
    };

    const get_weather_desc = llm.types.Tool{
        .name = "get_weather",
        .description = "Get the current weather for a given zip code.",
        .parameters = &.{
            .{
                .name = "zip_code",
                .type = .integer,
                .required = true,
                .description = "The 5-digit zip code to get the weather for.",
            },
        },
    };

    const tools = &[_]Tool{
        Tool.init(execute_typescript_desc, executeTypescript),
        Tool.init(get_weather_desc, getWeather),
    };

    const session_config: llm.types.SessionConfig = .{
        .model = selected_model.?,
        .tools = &.{
            tools[0].descriptor,
            tools[1].descriptor,
        },
    };

    var agent = Agent{
        .provider = client,
        .tools = tools,
        .session_config = session_config,
        .prev_continuation = null,
    };
    defer agent.deinit();

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

    while (true) {
        std.debug.print("\n{s}User > {s}", .{ color_green ++ color_bold, color_reset });
        const user_input = try stdin_reader.interface.takeDelimiter('\n') orelse break;
        if (user_input.len == 0) break;

        const turn = types.Turn{ .prompt = user_input };
        var stream_ctx = StreamContext{ .allocator = allocator };
        var result = agent.executeTurnStreaming(allocator, turn, streamCallback, &stream_ctx) catch |err| {
            std.debug.print("Error during execution: {}\n", .{err});
            continue;
        };
        defer result.deinit();

        if (stream_ctx.current_type != null) {
            std.debug.print("\n", .{});
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
