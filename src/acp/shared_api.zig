const std = @import("std");

const Allocator = std.mem.Allocator;

/// Parses a JSON string value into an enum tag, dynamically mapping enum tag names
/// containing underscores to wire names containing slashes (e.g. mapping `session_new`
/// to `"session/new"`).
///
/// Unrecognized or invalid tags will return the specified `fallback` enum value.
/// String mapping is resolved entirely at compile-time and has zero runtime allocation cost.
pub fn parseEnumWithMappedFallback(
    comptime T: type,
    comptime fallback: T,
    source: std.json.Value,
) !T {
    if (source != .string) return error.UnexpectedToken;
    const s = source.string;

    inline for (std.meta.fields(T)) |f| {
        if (!std.mem.eql(u8, f.name, @tagName(fallback))) {
            const wire_name = comptime blk: {
                var buf: [f.name.len]u8 = undefined;
                for (f.name, 0..) |char, i| {
                    buf[i] = if (char == '_') '/' else char;
                }
                const final_buf = buf;
                break :blk &final_buf;
            };

            if (std.mem.eql(u8, s, wire_name)) {
                return @field(T, f.name);
            }
        }
    }
    return fallback;
}

/// JSON RPC Request ID
///
/// An identifier established by the Client that MUST contain a string, an integer, or null.
/// If it is not included, the request is assumed to be a notification.
///
/// See the [JSON RPC spec](https://www.jsonrpc.org/specification).
pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    null,

    pub fn jsonStringify(self: RequestId, jw: anytype) !void {
        switch (self) {
            .null => try jw.write(null),
            inline else => |payload| {
                try jw.write(payload);
            },
        }
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !RequestId {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(_: Allocator, source: std.json.Value, _: std.json.ParseOptions) !RequestId {
        switch (source) {
            .integer => |i| return .{ .integer = i },
            .string => |s| return .{ .string = s },
            .null => return .{ .null = {} },
            else => return error.InvalidEnumTag,
        }
    }
};

/// Metadata about the implementation of the client or agent.
///
/// Describes the name and version of an ACP implementation, with an optional
/// title for display to the user.
pub const Implementation = struct {
    /// Name identifying the ACP implementation intended for programmatic or
    /// logical use, but can be used as a display name if `title` is not present.
    name: []const u8,
    /// Intended for UI and end-user contexts — optimized to be human-readable
    /// and easily understood.
    ///
    /// If not provided, the `name` should be used for display.
    title: ?[]const u8 = null,
    /// Version of the implementation. Can be displayed to the user or used
    /// for debugging or metrics purposes. (e.g. "1.0.0").
    version: []const u8,
};

/// Protocol version identifier.
///
/// In JSON this is a Number but it is unlikely to be fractional so using u32 here.
///
/// This version is only bumped for breaking changes.
/// Non-breaking changes should be introduced via capabilities.
pub const ProtocolVersion = u32;

test "RequestId json parsing - integer" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(RequestId, allocator, "42", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(RequestId{ .integer = 42 }, parsed.value);
}

test "RequestId json parsing - string" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(RequestId, allocator, "\"abc\"", .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .string);
    try std.testing.expectEqualStrings("abc", parsed.value.string);
}

test "RequestId json parsing - null" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(RequestId, allocator, "null", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(RequestId.null, parsed.value);
}

test "Implementation json parsing - without title" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Implementation, allocator,
        \\{"name": "test", "version": "1.0.0"}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("test", parsed.value.name);
    try std.testing.expect(parsed.value.title == null);
    try std.testing.expectEqualStrings("1.0.0", parsed.value.version);
}

test "Implementation json parsing - with title" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Implementation, allocator,
        \\{"name": "test", "title": "My Title", "version": "1.0.0"}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("test", parsed.value.name);
    try std.testing.expectEqualStrings("My Title", parsed.value.title.?);
    try std.testing.expectEqualStrings("1.0.0", parsed.value.version);
}

test "ProtocolVersion json parsing" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(ProtocolVersion, allocator, "1", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(ProtocolVersion, 1), parsed.value);
}

test parseEnumWithMappedFallback {
    const TestEnum = enum {
        simple,
        under_score,
        other_long_name,
        unknown,
    };

    // Test simple tag
    {
        const val = std.json.Value{ .string = "simple" };
        const result = try parseEnumWithMappedFallback(TestEnum, .unknown, val);
        try std.testing.expectEqual(TestEnum.simple, result);
    }

    // Test tag containing underscore (mapped to slash)
    {
        const val = std.json.Value{ .string = "under/score" };
        const result = try parseEnumWithMappedFallback(TestEnum, .unknown, val);
        try std.testing.expectEqual(TestEnum.under_score, result);
    }

    // Test tag containing multiple underscores (mapped to multiple slashes)
    {
        const val = std.json.Value{ .string = "other/long/name" };
        const result = try parseEnumWithMappedFallback(TestEnum, .unknown, val);
        try std.testing.expectEqual(TestEnum.other_long_name, result);
    }

    // Test unknown fallback
    {
        const val = std.json.Value{ .string = "nonexistent/name" };
        const result = try parseEnumWithMappedFallback(TestEnum, .unknown, val);
        try std.testing.expectEqual(TestEnum.unknown, result);
    }

    // Test non-string value error
    {
        const val = std.json.Value{ .integer = 42 };
        try std.testing.expectError(error.UnexpectedToken, parseEnumWithMappedFallback(TestEnum, .unknown, val));
    }
}
