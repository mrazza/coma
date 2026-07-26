const std = @import("std");
const provider = @import("provider");
const llm = @import("llm");
const agent = @import("agent");
const Session = agent.Session;
const Tool = agent.Tool;
const types = agent.types;
const acp_pkg = @import("acp");

const coma = @import("coma");
const MarkdownRendering = @import("MarkdownRendering.zig");

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

fn executeTypescript(allocator: std.mem.Allocator, io: std.Io, code: []const u8) ![]const u8 {
    const argv = [_][]const u8{
        "npx", "tsx", "-e", code,
    };
    const result = std.process.run(allocator, io, .{
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

fn getWeather(allocator: std.mem.Allocator, zip_code: i64, ctx: *WeatherToolCtx) ![]const u8 {
    const result_str = if (zip_code == 7302)
        try allocator.dupe(u8, ctx.weather_str)
    else
        try std.fmt.allocPrint(allocator, "Error: Weather data is only available for zip code 07302. Requested: {}", .{zip_code});

    return result_str;
}

const WeatherToolCtx = struct {
    weather_str: []const u8,
};

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

    var weather_ctx: WeatherToolCtx = .{ .weather_str = "Weather report for 07302: Sunny, 72°F, Humidity 50%, Wind 5 mph" };

    const tools = &[_]Tool{
        Tool.init(.{
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
        }, executeTypescript),
        Tool.initWithContext(.{
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
        }, getWeather, &weather_ctx),
        agent.Tool.BuiltIn.Todo,
    };

    const session_config: types.SessionConfig = .{ .model = selected_model.?, .tools = tools, .system_prompt = "You're a helpful agent. The user can ask you questions and you can use your tools to answer them. When receiving a new request from the user, plan out how you will address the request and document the steps on your Todo list. Keep the todo list updated as you progress." };

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var run_acp = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--acp") or std.mem.eql(u8, arg, "acp")) {
            run_acp = true;
            break;
        }
    }

    if (run_acp) {
        var stdin_buffer: [1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

        const acp_config = acp_pkg.Server.Config{
            .provider = gemini_client.provider(),
            .default_session_config = session_config,
        };
        var server = acp_pkg.Server.init(allocator, io, &stdin_reader.interface, &stdout_writer.interface);
        defer server.deinit();

        std.debug.print("ACP Server: starting standard input/output loop...\n", .{});
        try server.run(acp_config);
        return;
    }

    var session: Session = try .init(allocator, io, client, session_config);
    defer session.deinit();

    std.debug.print(
        \\{s}============================================================================
        \\                    COMA Agent Chat Interface
        \\============================================================================
        \\Model: {s} ({s})
        \\Type a prompt and press Enter.
        \\Press Ctrl+D or leave empty and press Enter to exit.
        \\============================================================================{s}
        \\
    , .{ MarkdownRendering.color_cyan, selected_model.?.display_name, selected_model.?.id, MarkdownRendering.color_reset });

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);

    while (true) {
        std.debug.print("\n{s}User > {s}", .{ MarkdownRendering.color_green ++ MarkdownRendering.color_bold, MarkdownRendering.color_reset });
        const user_input = try stdin_reader.interface.takeDelimiter('\n') orelse break;
        if (user_input.len == 0) break;

        const turn = types.Turn{ .prompt = user_input };
        var stream_ctx = MarkdownRendering.StreamContext{ .allocator = allocator };
        var result = session.executeTurnStreaming(turn, MarkdownRendering.streamCallback, &stream_ctx) catch |err| {
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
