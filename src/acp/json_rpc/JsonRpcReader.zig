//! Takes a `*std.Io.Reader` that contains a [JSON-RPC](https://www.jsonrpc.org/specification) stream.
//!
//! Reads individual JSON-RPC messages from the stream and returns them as byte slices.
//! Supports both streams prefixed with `Content-Length` headers and streams without headers.
//!
//! This is NOT threadsafe.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const JsonRpcReader = @This();

allocator: Allocator,
reader: *Io.Reader,
read_buffer: std.Io.Writer.Allocating,

/// Initializes a new `JsonRpcReader`.
///
/// The returned `JsonRpcReader` must be deinitialized when no longer needed by calling `deinit()`.
pub fn init(allocator: Allocator, reader: *Io.Reader) JsonRpcReader {
    return .{
        .allocator = allocator,
        .reader = reader,
        .read_buffer = .init(allocator),
    };
}

/// Frees the resources associated with the `JsonRpcReader`.
pub fn deinit(self: *JsonRpcReader) void {
    self.read_buffer.deinit();
}

/// Reads the next raw JSON-RPC message from the stream and returns it as a raw byte slice.
///
/// The returned slice must be freed by the caller.
pub fn readRawMessage(self: *JsonRpcReader) ![]const u8 {
    return self.allocator.dupe(u8, try self.readRawMessageInternal());
}

/// Reads the next JSON-RPC message from the stream and parses it as an ObjectType.
///
/// The returned `Parsed(ObjectType)` must be deinitialized when no longer needed by called `deinit()`.
pub fn readJsonObject(self: *JsonRpcReader, ObjectType: type) !std.json.Parsed(ObjectType) {
    const raw = try self.readRawMessageInternal();
    return try std.json.parseFromSlice(ObjectType, self.allocator, raw, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn streamLine(self: *JsonRpcReader) ![]const u8 {
    const line_length = self.reader.streamDelimiter(&self.read_buffer.writer, '\n');
    defer self.read_buffer.clearRetainingCapacity();
    if (line_length) |_| {
        self.reader.toss(1);
    } else |err| switch (err) {
        error.EndOfStream => if (self.read_buffer.written().len == 0) return err, // Expected if there are no more messages in the stream.
        else => return err,
    }
    var line = self.read_buffer.written();
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }
    return line;
}

fn readRawMessageInternal(self: *JsonRpcReader) ![]const u8 {
    const line = try self.streamLine();

    if (line.len == 0) return error.UnexpectedEndOfInput;

    // TODO: We assume that the first header (in LSP-style JSON-RPC) is "Content-Length".
    // This may not always be true. "Content-Type" is another common header and the
    // spec does not specify ordering. Additionally, the headers are not case-sensitive.
    if (std.mem.startsWith(u8, line, "Content-Length:")) {
        const parts = std.mem.trim(u8, line["Content-Length:".len..], " ");
        const content_length = try std.fmt.parseInt(usize, parts, 10);

        // The protocol specifies that all headers are followed by a blank line.
        // Therefore, we consume all content until a blank line.
        while (true) {
            const expected_empty = try self.streamLine();
            if (expected_empty.len == 0) {
                break;
            }
        }

        try self.reader.streamExact(&self.read_buffer.writer, content_length);
        defer self.read_buffer.clearRetainingCapacity();
        return self.read_buffer.written();
    } else {
        return line;
    }
}

test readJsonObject {
    const TestObjectParams = struct {
        version: []const u8,
    };

    const TestObject = struct {
        jsonrpc: []const u8,
        method: []const u8,
        params: TestObjectParams,
        id: u64,
    };

    // test reading newline delimited messages
    {
        const input =
            \\{"jsonrpc":"2.0","method":"initialize","params":{"version":"2.0"},"id":1}
            \\{"jsonrpc":"2.0","method":"initialize","params":{"version":"2.0"},"id":2}
        ;

        const allocator = std.testing.allocator;
        var r = std.Io.Reader.fixed(input);
        var reader: JsonRpcReader = .init(allocator, &r);
        defer reader.deinit();

        const json_msg1 = try reader.readJsonObject(TestObject);
        defer json_msg1.deinit();
        const msg1 = json_msg1.value;

        const json_msg2 = try reader.readJsonObject(TestObject);
        defer json_msg2.deinit();
        const msg2 = json_msg2.value;

        try std.testing.expectEqualStrings("2.0", msg1.jsonrpc);
        try std.testing.expectEqualStrings("initialize", msg1.method);
        try std.testing.expectEqual(1, msg1.id);
        try std.testing.expectEqualStrings("2.0", msg1.params.version);

        try std.testing.expectEqualStrings("2.0", msg2.jsonrpc);
        try std.testing.expectEqualStrings("initialize", msg2.method);
        try std.testing.expectEqual(2, msg2.id);
        try std.testing.expectEqualStrings("2.0", msg2.params.version);

        try std.testing.expectError(error.EndOfStream, reader.readJsonObject(TestObject));
    }

    // test reading messages with headers
    {
        const input =
            \\Content-Length: 73
            \\
            \\{"jsonrpc":"2.0","method":"initialize","params":{"version":"2.0"},"id":1}Content-Length: 73
            \\
            \\{"jsonrpc":"2.0","method":"initialize","params":{"version":"2.0"},"id":2}
        ;

        const allocator = std.testing.allocator;
        var r = std.Io.Reader.fixed(input);
        var reader: JsonRpcReader = .init(allocator, &r);
        defer reader.deinit();

        const json_msg1 = try reader.readJsonObject(TestObject);
        defer json_msg1.deinit();
        const msg1 = json_msg1.value;

        const json_msg2 = try reader.readJsonObject(TestObject);
        defer json_msg2.deinit();
        const msg2 = json_msg2.value;

        try std.testing.expectEqualStrings("2.0", msg1.jsonrpc);
        try std.testing.expectEqualStrings("initialize", msg1.method);
        try std.testing.expectEqual(1, msg1.id);
        try std.testing.expectEqualStrings("2.0", msg1.params.version);

        try std.testing.expectEqualStrings("2.0", msg2.jsonrpc);
        try std.testing.expectEqualStrings("initialize", msg2.method);
        try std.testing.expectEqual(2, msg2.id);
        try std.testing.expectEqualStrings("2.0", msg2.params.version);

        try std.testing.expectError(error.EndOfStream, reader.readJsonObject(TestObject));
    }
}

test readRawMessage {
    const allocator = std.testing.allocator;

    // test reading newline delimited messages
    {
        const input =
            \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
            \\{"jsonrpc":"2.0","id":2,"method":"initialize"}
        ;
        var r = std.Io.Reader.fixed(input);
        var reader: JsonRpcReader = .init(allocator, &r);
        defer reader.deinit();

        const msg1 = try reader.readRawMessage();
        defer allocator.free(msg1);
        const msg2 = try reader.readRawMessage();
        defer allocator.free(msg2);

        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", msg1);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}", msg2);
        try std.testing.expectError(error.EndOfStream, reader.readRawMessage());
    }

    // test reading messages with headers
    {
        const input =
            \\Content-Length: 46
            \\
            \\{"jsonrpc":"2.0","id":1,"method":"initialize"}Content-Length: 46
            \\
            \\{"jsonrpc":"2.0","id":2,"method":"initialize"}
        ;
        var r = std.Io.Reader.fixed(input);
        var reader: JsonRpcReader = .init(allocator, &r);
        defer reader.deinit();

        const msg1 = try reader.readRawMessage();
        defer allocator.free(msg1);
        const msg2 = try reader.readRawMessage();
        defer allocator.free(msg2);

        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", msg1);
        try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}", msg2);
        try std.testing.expectError(error.EndOfStream, reader.readRawMessage());
    }
}

test "readRawMessage - delimiter before EOF" {
    const allocator = std.testing.allocator;

    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
        \\
    ;
    var r = std.Io.Reader.fixed(input);
    var reader: JsonRpcReader = .init(allocator, &r);
    defer reader.deinit();

    const msg1 = try reader.readRawMessage();
    defer allocator.free(msg1);

    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", msg1);
    try std.testing.expectError(error.EndOfStream, reader.readRawMessage());
}

test "readRawMessage - empty line" {
    const allocator = std.testing.allocator;

    const input =
        \\
        \\
    ;
    var r = std.Io.Reader.fixed(input);
    var reader: JsonRpcReader = .init(allocator, &r);
    defer reader.deinit();

    try std.testing.expectError(error.UnexpectedEndOfInput, reader.readRawMessage());
    try std.testing.expectError(error.EndOfStream, reader.readRawMessage());
}
