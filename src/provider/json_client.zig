const std = @import("std");
const testing = @import("testing");
const llm = @import("llm");

const Allocator = std.mem.Allocator;

pub const JsonHttpClient = MakeJsonClient(*std.http.Client);
pub const MockJsonClient = MakeJsonClient(testing.MockHttpClient);

pub fn MakeJsonClient(comptime ClientType: type) type {
    return struct {
        http_client: ClientType,

        const Self = @This();

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
                .options = .{},
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
    };
}

test "getRequest success" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/test");

    const Response = struct {
        model: []const u8,
        nextPageToken: ?[]const u8,
    };

    const expectations = [_]testing.MockHttpClient.RequestExpectation{
        .{
            .expected_scheme = "https",
            .expected_host = "example.com",
            .expected_path = "/test",
            .expected_method = .GET,
            .expected_payload = null,
            .response_status = .ok,
            .response_body = "{\"model\": \"model\", \"nextPageToken\": null}",
        },
    };

    const mock_client: testing.MockHttpClient = .{
        .expectations = &expectations,
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

    const expectations = [_]testing.MockHttpClient.RequestExpectation{
        .{
            .expected_scheme = "https",
            .expected_host = "example.com",
            .expected_path = "/test",
            .expected_method = .GET,
            .expected_payload = null,
            .response_status = .not_found,
            .response_body = "",
        },
    };

    const mock_client: testing.MockHttpClient = .{
        .expectations = &expectations,
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

    const expectations = [_]testing.MockHttpClient.RequestExpectation{
        .{
            .expected_scheme = "https",
            .expected_host = "example.com",
            .expected_path = "/post",
            .expected_method = .POST,
            .expected_payload = "{\"input\":\"hello\"}",
            .response_status = .ok,
            .response_body = "{\"id\":\"123\"}",
        },
    };

    const mock_client: testing.MockHttpClient = .{
        .expectations = &expectations,
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

    const expectations = [_]testing.MockHttpClient.RequestExpectation{
        .{
            .expected_scheme = "https",
            .expected_host = "example.com",
            .expected_path = "/post",
            .expected_method = .POST,
            .expected_payload = "{\"input\":\"hello\"}",
            .response_status = .internal_server_error,
            .response_body = "",
        },
    };

    const mock_client: testing.MockHttpClient = .{
        .expectations = &expectations,
    };

    var rpc_client: MockJsonClient = .{ .http_client = mock_client };

    const request = RequestPayload{ .input = "hello" };

    try std.testing.expectError(error.HttpRequestFailed, rpc_client.postRequest(allocator, RequestPayload, Response, uri, request));
}
