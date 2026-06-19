const std = @import("std");
const llm = @import("llm");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;

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

test "toGoogleTool conversion" {
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
