//! Contains structs and functionality shared by both ACP client (requests) and
//! ACP servers (responses).

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

/// Converts an enum tag value into a string slice, dynamically mapping enum tag names
/// containing underscores to wire names containing slashes (e.g. mapping `.session_new`
/// to `"session/new"`).
///
/// String mapping is resolved entirely at compile-time and has zero runtime allocation cost.
pub fn stringifyEnum(value: anytype) []const u8 {
    comptime {
        const T = @TypeOf(value);
        if (@typeInfo(T) != .@"enum") {
            @compileError("stringifyEnum expects an enum value, found " ++ @typeName(T));
        }
    }

    switch (value) {
        inline else => |tag| {
            return comptime blk: {
                const name = @tagName(tag);
                var buf: [name.len]u8 = undefined;
                for (name, 0..) |char, i| {
                    buf[i] = if (char == '_') '/' else char;
                }
                const final_buf = buf;
                break :blk &final_buf;
            };
        },
    }
}

/// A generic JSON stringifier that iterates over the fields of a struct.
/// It skips fields that are optional and have a null value.
///
/// Useful when implementing a custom json stringifier that writes additional fields before the object fields.
/// But still needs the object fields.
/// TODO(razza): Move to a general location? This is re-used in provider/google/api.
pub fn jsonStringifyFields(object: anytype, jw: anytype) !void {
    const info = @typeInfo(@TypeOf(object));
    if (info != .@"struct" and info != .@"union") {
        @compileError("jsonStringifyFields only supports struct and union types");
    }

    inline for (std.meta.fields(@TypeOf(object))) |field| {
        const value = @field(object, field.name);
        if (@typeInfo(field.type) != .optional or value != null) {
            try jw.objectField(field.name);
            try jw.write(value);
        }
    }
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

/// A unique identifier for a conversation session between a client and agent.
///
/// Sessions maintain their own context, conversation history, and state,
/// allowing multiple independent interactions with the same agent.
///
/// See protocol docs: [Session ID](https://agentclientprotocol.com/protocol/session-setup#session-id)
pub const SessionId = []const u8;

/// Types of content in a `ContentBlock`.
///
/// See protocol docs: [Content](https://agentclientprotocol.com/protocol/v1/content)
pub const ContentType = enum {
    text,
};

/// Content blocks represent displayable information in the Agent Client Protocol.
///
/// They provide a structured way to handle various types of user-facing content—whether
/// it's text from language models, images for analysis, or embedded resources for context.
///
/// Content blocks appear in:
/// - User prompts sent via `session/prompt`
/// - Language model output streamed through `session/update` notifications
/// - Progress updates and results from tool calls
///
/// This structure is compatible with the Model Context Protocol (MCP), enabling
/// agents to seamlessly forward content from MCP tool outputs without transformation.
///
/// See protocol docs: [Content](https://agentclientprotocol.com/protocol/v1/content)
pub const ContentBlock = union(ContentType) {
    /// Text content.
    text: []const u8,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !ContentBlock {
        const json_value = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, json_value, options);
    }

    pub fn jsonParseFromValue(allocator: Allocator, source: std.json.Value, options: std.json.ParseOptions) !ContentBlock {
        if (source != .object) return error.UnexpectedToken;
        const content_type = try std.json.innerParseFromValue(ContentType, allocator, source.object.get("type") orelse return error.MissingField, options);
        return switch (content_type) {
            .text => .{ .text = try std.json.innerParseFromValue([]const u8, allocator, source.object.get("text") orelse return error.MissingField, options) },
        };
    }

    pub fn jsonStringify(self: ContentBlock, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write(@tagName(self));
        try jsonStringifyFields(self, jw);
        try jw.endObject();
    }
};

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

test "ContentBlock json parsing - text" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"type": "text", "text": "hello world"}
    ;
    const parsed = try std.json.parseFromSlice(ContentBlock, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(ContentType.text, @as(ContentType, parsed.value));
    try std.testing.expectEqualStrings("hello world", parsed.value.text);
}

test "ContentBlock json parsing - invalid" {
    const allocator = std.testing.allocator;

    // Missing text field
    try std.testing.expectError(
        error.MissingField,
        std.json.parseFromSlice(ContentBlock, allocator, "{\"type\": \"text\"}", .{}),
    );

    // Missing type field
    try std.testing.expectError(
        error.MissingField,
        std.json.parseFromSlice(ContentBlock, allocator, "{\"text\": \"hello\"}", .{}),
    );

    // Invalid type tag
    try std.testing.expectError(
        error.InvalidEnumTag,
        std.json.parseFromSlice(ContentBlock, allocator, "{\"type\": \"invalid\", \"text\": \"hello\"}", .{}),
    );

    // Non-object token
    try std.testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(ContentBlock, allocator, "\"not an object\"", .{}),
    );
}

test "ContentBlock json stringify - text" {
    const allocator = std.testing.allocator;
    const block = ContentBlock{ .text = "hello world" };

    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var stringifier = std.json.Stringify{
        .writer = &buffer.writer,
        .options = .{},
    };
    try stringifier.write(block);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer.written(), .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("text", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("hello world", parsed.value.object.get("text").?.string);
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

test stringifyEnum {
    const TestEnum = enum {
        simple,
        under_score,
        other_long_name,
        unknown,
    };

    try std.testing.expectEqualStrings("simple", stringifyEnum(TestEnum.simple));
    try std.testing.expectEqualStrings("under/score", stringifyEnum(TestEnum.under_score));
    try std.testing.expectEqualStrings("other/long/name", stringifyEnum(TestEnum.other_long_name));
    try std.testing.expectEqualStrings("unknown", stringifyEnum(TestEnum.unknown));
}

test jsonStringifyFields {
    const allocator = std.testing.allocator;

    const TestStruct = struct {
        foo: []const u8,
        bar: ?i32 = null,
        baz: ?bool = null,
    };

    const obj = TestStruct{
        .foo = "hello",
        .bar = 42,
        .baz = null,
    };

    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var stringifier = std.json.Stringify{
        .writer = &buffer.writer,
        .options = .{},
    };

    try stringifier.beginObject();
    try stringifier.objectField("extra");
    try stringifier.write("prefix");
    try jsonStringifyFields(obj, &stringifier);
    try stringifier.endObject();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer.written(), .{});
    defer parsed.deinit();

    const map = parsed.value.object;
    try std.testing.expectEqualStrings("prefix", map.get("extra").?.string);
    try std.testing.expectEqualStrings("hello", map.get("foo").?.string);
    try std.testing.expectEqual(@as(i64, 42), map.get("bar").?.integer);
    try std.testing.expect(map.get("baz") == null);
}
