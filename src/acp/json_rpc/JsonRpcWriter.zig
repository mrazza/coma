//! Takes a `*std.Io.Writer` and supports writing objects to that stream via the JSON-RPC format.
//!
//! This is NOT threadsafe.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const JsonRpcWriter = @This();

allocator: Allocator,
writer: *Io.Writer,
write_buffer: std.Io.Writer.Allocating,

/// Options for writing JSON-RPC messages.
pub const Options = struct {
    /// Whether to prefix the message with a "Content-Length" header.
    ///
    /// Defaults to `false`.
    use_headers: bool = false,
};

/// Initializes a new `JsonRpcWriter`.
///
/// The returned `JsonRpcWriter` must be deinitialized when no longer needed by calling `deinit()`.
pub fn init(allocator: Allocator, writer: *Io.Writer) JsonRpcWriter {
    return .{
        .allocator = allocator,
        .writer = writer,
        .write_buffer = .init(allocator),
    };
}

/// Frees the resources associated with the `JsonRpcWriter`.
pub fn deinit(self: *JsonRpcWriter) void {
    self.write_buffer.deinit();
}

/// Writes a JSON-RPC raw message (payload) directly to the stream.
pub fn writeRawMessage(self: *JsonRpcWriter, payload: []const u8, options: Options) !void {
    if (options.use_headers) {
        var header_buf: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{payload.len});
        _ = try self.writer.write(header);
        _ = try self.writer.write(payload);
    } else {
        _ = try self.writer.write(payload);
        _ = try self.writer.write("\n");
    }
    _ = try self.writer.flush();
}

/// Serializes the given value to JSON and writes it to the stream.
pub fn writeJsonObject(self: *JsonRpcWriter, value: anytype, options: Options) !void {
    self.write_buffer.clearRetainingCapacity();
    var stringifier = std.json.Stringify{
        .writer = &self.write_buffer.writer,
        .options = .{},
    };
    try stringifier.write(value);

    try self.writeRawMessage(self.write_buffer.written(), options);
}

test writeJsonObject {
    const TestObject = struct {
        jsonrpc: []const u8,
        method: []const u8,
        id: u64,
    };

    const allocator = std.testing.allocator;

    // Test writing with headers
    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();

        var writer = JsonRpcWriter.init(allocator, &buffer.writer);
        defer writer.deinit();

        const msg = TestObject{
            .jsonrpc = "2.0",
            .method = "initialize",
            .id = 1,
        };

        try writer.writeJsonObject(msg, .{ .use_headers = true });

        const expected = "Content-Length: 46\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}";
        try std.testing.expectEqualStrings(expected, buffer.written());
    }

    // Test writing without headers
    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();

        var writer = JsonRpcWriter.init(allocator, &buffer.writer);
        defer writer.deinit();

        const msg = TestObject{
            .jsonrpc = "2.0",
            .method = "initialize",
            .id = 2,
        };

        try writer.writeJsonObject(msg, .{ .use_headers = false });

        const expected = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":2}\n";
        try std.testing.expectEqualStrings(expected, buffer.written());
    }
}

test writeRawMessage {
    const allocator = std.testing.allocator;

    // Test writing raw message with headers
    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();

        var writer = JsonRpcWriter.init(allocator, &buffer.writer);
        defer writer.deinit();

        const payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
        try writer.writeRawMessage(payload, .{ .use_headers = true });

        const expected = "Content-Length: 46\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}";
        try std.testing.expectEqualStrings(expected, buffer.written());
    }

    // Test writing raw message without headers
    {
        var buffer = std.Io.Writer.Allocating.init(allocator);
        defer buffer.deinit();

        var writer = JsonRpcWriter.init(allocator, &buffer.writer);
        defer writer.deinit();

        const payload = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}";
        try writer.writeRawMessage(payload, .{ .use_headers = false });

        const expected = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}\n";
        try std.testing.expectEqualStrings(expected, buffer.written());
    }
}

test "writeJsonObject - consecutive calls with headers" {
    const TestObject = struct {
        jsonrpc: []const u8,
        method: []const u8,
        id: u64,
    };

    const allocator = std.testing.allocator;

    var buffer = std.Io.Writer.Allocating.init(allocator);
    defer buffer.deinit();

    var writer = JsonRpcWriter.init(allocator, &buffer.writer);
    defer writer.deinit();

    const msg1 = TestObject{
        .jsonrpc = "2.0",
        .method = "initialize",
        .id = 1,
    };
    try writer.writeJsonObject(msg1, .{ .use_headers = true });

    const msg2 = TestObject{
        .jsonrpc = "2.0",
        .method = "initialized",
        .id = 2,
    };
    try writer.writeJsonObject(msg2, .{ .use_headers = true });

    const expected =
        "Content-Length: 46\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}" ++
        "Content-Length: 47\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"id\":2}";
    try std.testing.expectEqualStrings(expected, buffer.written());
}
