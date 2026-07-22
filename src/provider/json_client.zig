const std = @import("std");
const testing = @import("testing");
const llm = @import("llm");

const Allocator = std.mem.Allocator;

pub const JsonHttpClient = MakeJsonClient(*std.http.Client);
pub const MockJsonClient = MakeJsonClient(testing.MockHttpClient);

/// Generates a JSON HTTP client wrapper parameterized by the underlying HTTP client type.
///
/// The resulting type is as thread-safe as the underlying client type. Therefore, for JsonClients
/// created against `std.http.Client` individual connects and requests are created in a thread-safe
/// manner but each request, itself, is not thread-safe.
pub fn MakeJsonClient(comptime ClientType: type) type {
    return struct {
        http_client: ClientType,

        const Self = @This();

        pub const StreamingResponse = struct {
            const ClientStructType = if (@typeInfo(ClientType) == .pointer) std.meta.Child(ClientType) else ClientType;

            request: ClientStructType.Request,
            response: ClientStructType.Response,
            transfer_buffer: [1024]u8 = undefined,

            pub fn deinit(self: *StreamingResponse) void {
                self.request.deinit();
            }

            pub fn reader(self: *StreamingResponse) *std.Io.Reader {
                if (@hasField(ClientStructType.Response, "request")) {
                    self.response.request = &self.request;
                }
                return self.response.reader(&self.transfer_buffer);
            }
        };

        /// Sends an HTTP GET request to the specified URI and parses the JSON response.
        pub fn getRequest(self: *Self, allocator: Allocator, comptime ResponseType: type, uri: std.Uri) !std.json.Parsed(ResponseType) {
            var response_buffer = std.Io.Writer.Allocating.init(allocator);
            defer response_buffer.deinit();

            const result = try self.http_client.fetch(.{ .location = .{ .uri = uri }, .response_writer = &response_buffer.writer });

            if (result.status.class() == .success) {
                return try std.json.parseFromSlice(
                    ResponseType,
                    allocator,
                    response_buffer.written(),
                    .{ .ignore_unknown_fields = true, .allocate = std.json.AllocWhen.alloc_always },
                );
            } else {
                return error.HttpRequestFailed;
            }
        }

        /// Sends an HTTP POST request to the specified URI with a JSON-serialized payload
        /// and parses the JSON response.
        pub fn postRequest(
            self: *Self,
            allocator: Allocator,
            comptime RequestType: type,
            comptime ResponseType: type,
            uri: std.Uri,
            request: RequestType,
        ) !std.json.Parsed(ResponseType) {
            var payload_buffer: std.Io.Writer.Allocating = .init(allocator);
            defer payload_buffer.deinit();
            var stringifier = std.json.Stringify{
                .writer = &payload_buffer.writer,
                .options = .{ .emit_null_optional_fields = false },
            };
            try stringifier.write(request);
            var response_buffer: std.Io.Writer.Allocating = .init(allocator);
            defer response_buffer.deinit();

            const result = try self.http_client.fetch(.{
                .location = .{ .uri = uri },
                .response_writer = &response_buffer.writer,
                .method = std.http.Method.POST,
                .payload = payload_buffer.written(),
            });

            if (result.status.class() == .success) {
                return try std.json.parseFromSlice(
                    ResponseType,
                    allocator,
                    response_buffer.written(),
                    .{ .ignore_unknown_fields = true, .allocate = std.json.AllocWhen.alloc_always },
                );
            } else {
                std.log.warn("HTTP Call Failed: {any}\n{s}\n", .{ result.status, response_buffer.written() });
                return error.HttpRequestFailed;
            }
        }

        /// Sends an HTTP POST request to the specified URI with a JSON-serialized payload
        /// and returns a StreamingResponseReader to incrementally read the response.
        ///
        /// Note, given the incrementality the response is streamed raw and the caller must JSON
        /// deserialize it.
        pub fn postRequestStreaming(
            self: *Self,
            allocator: Allocator,
            comptime RequestType: type,
            uri: std.Uri,
            request: RequestType,
        ) !StreamingResponse {
            var payload_buffer: std.Io.Writer.Allocating = .init(allocator);
            defer payload_buffer.deinit();
            var stringifier = std.json.Stringify{
                .writer = &payload_buffer.writer,
                .options = .{},
            };
            try stringifier.write(request);

            var req = try self.http_client.request(.POST, uri, .{
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                    .accept_encoding = .{ .override = "identity" },
                },
            });
            errdefer req.deinit();

            req.transfer_encoding = .{ .content_length = payload_buffer.written().len };
            try req.sendBodyComplete(payload_buffer.written());

            var redirect_buffer: [8000]u8 = undefined;
            var response = try req.receiveHead(&redirect_buffer);

            if (response.head.status.class() != .success) {
                return error.HttpRequestFailed;
            }

            return .{
                .request = req,
                .response = response,
            };
        }
    };
}

test "getRequest success" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/test");

    const Response = struct {
        model: []const u8,
        nextPageToken: ?[]const u8,
    };

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/test",
                .expected_method = .GET,
                .expected_payload = null,
                .response_status = .ok,
                .response_body = "{\"model\": \"model\", \"nextPageToken\": null}",
            },
        },
    };

    var rpc_client: MockJsonClient = .{ .http_client = mock_client };

    const result = try rpc_client.getRequest(allocator, Response, uri);
    defer result.deinit();

    try std.testing.expectEqualStrings("model", result.value.model);
    try std.testing.expectEqual(null, result.value.nextPageToken);
}

test "getRequest failure" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/test");

    const Response = struct {
        model: []const u8,
        nextPageToken: []const u8,
    };

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/test",
                .expected_method = .GET,
                .expected_payload = null,
                .response_status = .not_found,
                .response_body = "",
            },
        },
    };

    var rpc_client: MockJsonClient = .{ .http_client = mock_client };
    try std.testing.expectError(error.HttpRequestFailed, rpc_client.getRequest(allocator, Response, uri));
}

test "postRequest success" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/post");

    const RequestPayload = struct {
        input: []const u8,
    };

    const Response = struct {
        id: []const u8,
    };

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/post",
                .expected_method = .POST,
                .expected_payload = "{\"input\":\"hello\"}",
                .response_status = .ok,
                .response_body = "{\"id\":\"123\"}",
            },
        },
    };

    var rpc_client: MockJsonClient = .{ .http_client = mock_client };

    const request = RequestPayload{ .input = "hello" };

    const result = try rpc_client.postRequest(allocator, RequestPayload, Response, uri, request);
    defer result.deinit();

    try std.testing.expectEqualStrings("123", result.value.id);
}

test "postRequest failure" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/post");

    const RequestPayload = struct {
        input: []const u8,
    };

    const Response = struct {
        id: []const u8,
    };

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/post",
                .expected_method = .POST,
                .expected_payload = "{\"input\":\"hello\"}",
                .response_status = .internal_server_error,
                .response_body = "",
            },
        },
    };

    var rpc_client: MockJsonClient = .{ .http_client = mock_client };

    const request = RequestPayload{ .input = "hello" };

    try std.testing.expectError(error.HttpRequestFailed, rpc_client.postRequest(allocator, RequestPayload, Response, uri, request));
}

test "postRequestStreaming success" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/stream");

    const RequestPayload = struct {
        input: []const u8,
    };

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/stream",
                .expected_method = .POST,
                .expected_payload = "{\"input\":\"stream-test\"}",
                .response_status = .ok,
                .response_body = "chunk1\nchunk2\n",
            },
        },
    };

    var rpc_client: MockJsonClient = .{ .http_client = mock_client };

    const request = RequestPayload{ .input = "stream-test" };

    var response_reader = try rpc_client.postRequestStreaming(allocator, RequestPayload, uri, request);
    defer response_reader.deinit();

    var buf: [100]u8 = undefined;
    const reader = response_reader.reader();
    const bytes_read = try reader.readSliceShort(&buf);
    try std.testing.expectEqualStrings("chunk1\nchunk2\n", buf[0..bytes_read]);
}

test "postRequestStreaming failure" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/stream");

    const RequestPayload = struct {
        input: []const u8,
    };

    const mock_client: testing.MockHttpClient = .{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/stream",
                .expected_method = .POST,
                .expected_payload = "{\"input\":\"stream-test\"}",
                .response_status = .internal_server_error,
                .response_body = "",
            },
        },
    };

    var rpc_client: MockJsonClient = .{ .http_client = mock_client };

    const request = RequestPayload{ .input = "stream-test" };

    try std.testing.expectError(error.HttpRequestFailed, rpc_client.postRequestStreaming(allocator, RequestPayload, uri, request));
}
