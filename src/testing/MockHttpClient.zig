const std = @import("std");

/// A mock HTTP client used for testing.
const MockHttpClient = @This();

/// Represents an expected HTTP request and its corresponding mock response.
pub const RequestExpectation = struct {
    /// The expected URI scheme (e.g., "https").
    expected_scheme: []const u8,
    /// The expected host name.
    expected_host: []const u8,
    /// The expected URI path.
    expected_path: []const u8,
    /// The expected URI query string, if any.
    expected_query: ?[]const u8 = null,
    /// The expected HTTP method.
    expected_method: std.http.Method,
    /// The expected request payload, if any.
    expected_payload: ?[]const u8 = null,
    /// The HTTP status code to return.
    response_status: std.http.Status,
    /// The response body to write to the response writer.
    response_body: []const u8,
};

/// The allocator used for mocking/testing allocations.
allocator: std.mem.Allocator,
/// The list of expected requests and their corresponding mock responses.
expectations: []const RequestExpectation,
/// If true, the client enforces that requests match `expectations` sequentially.
/// If false, the client searches `expectations` for any matching request.
sequential: bool = false,
/// Optional array to track the number of times each expectation was matched.
call_counts: ?[]usize = null,
/// Tracks the current index when `sequential` is true.
call_index: usize = 0,

/// Verifies that the provided request options strictly match the expectation.
/// Used when `sequential` is true.
fn verifyExpectation(options: anytype, expectation: RequestExpectation) !void {
    // 1. Verify URI
    try std.testing.expectEqualStrings(expectation.expected_scheme, options.location.uri.scheme);
    if (options.location.uri.host) |host| {
        try std.testing.expectEqualStrings(expectation.expected_host, host.percent_encoded);
    } else {
        return error.ExpectedHost;
    }
    try std.testing.expectEqualStrings(expectation.expected_path, options.location.uri.path.percent_encoded);

    if (options.location.uri.query) |query| {
        if (expectation.expected_query) |expected| {
            try std.testing.expectEqualStrings(expected, query.percent_encoded);
        } else {
            return error.UnexpectedQuery;
        }
    } else {
        try std.testing.expect(expectation.expected_query == null);
    }

    // 2. Verify Method
    const method = if (@hasField(@TypeOf(options), "method")) options.method else std.http.Method.GET;
    try std.testing.expectEqual(expectation.expected_method, method);

    // 3. Verify Payload
    if (expectation.expected_payload) |expected| {
        if (@hasField(@TypeOf(options), "payload")) {
            try std.testing.expectEqualStrings(expected, options.payload);
        } else {
            if (@hasField(@TypeOf(options), "response_writer")) {
                return error.ExpectedPayloadButGotNone;
            }
        }
    } else {
        if (@hasField(@TypeOf(options), "payload")) {
            if (options.payload.len > 0) {
                return error.UnexpectedPayload;
            }
        }
    }
}

/// Checks if the provided request options match the given expectation.
/// Returns true if it matches, false otherwise.
fn matchExpectation(options: anytype, expectation: RequestExpectation) bool {
    if (!std.mem.eql(u8, expectation.expected_scheme, options.location.uri.scheme)) return false;

    if (options.location.uri.host) |host| {
        if (!std.mem.eql(u8, expectation.expected_host, host.percent_encoded)) return false;
    } else {
        return false;
    }

    if (!std.mem.eql(u8, expectation.expected_path, options.location.uri.path.percent_encoded)) return false;

    if (options.location.uri.query) |query| {
        if (expectation.expected_query) |expected| {
            if (!std.mem.eql(u8, expected, query.percent_encoded)) return false;
        } else {
            return false;
        }
    } else {
        if (expectation.expected_query != null) return false;
    }

    const method = if (@hasField(@TypeOf(options), "method")) options.method else std.http.Method.GET;
    if (expectation.expected_method != method) return false;

    if (expectation.expected_payload) |expected| {
        if (@hasField(@TypeOf(options), "payload")) {
            if (!std.mem.eql(u8, expected, options.payload)) return false;
        } else {
            return false;
        }
    } else {
        if (@hasField(@TypeOf(options), "payload")) {
            if (options.payload.len > 0) return false;
        }
    }

    return true;
}

/// Simulates an HTTP fetch operation based on the configured expectations.
pub fn fetch(self: *MockHttpClient, options: anytype) !struct { status: std.http.Status } {
    if (self.sequential) {
        const idx = self.call_index;
        self.call_index += 1;
        if (idx >= self.expectations.len) {
            return error.TooManyCalls;
        }
        const expectation = self.expectations[idx];
        try verifyExpectation(options, expectation);
        if (self.call_counts) |counts| {
            counts[idx] += 1;
        }
        _ = try options.response_writer.write(expectation.response_body);
        return .{ .status = expectation.response_status };
    } else {
        for (self.expectations, 0..) |expectation, i| {
            if (matchExpectation(options, expectation)) {
                if (self.call_counts) |counts| {
                    counts[i] += 1;
                }
                _ = try options.response_writer.write(expectation.response_body);
                return .{ .status = expectation.response_status };
            }
        }
        return error.NoMatchingExpectation;
    }
}

pub const Request = MockRequest;
pub const Response = MockResponse;

pub const MockRequest = struct {
    client: *MockHttpClient,
    expectation: RequestExpectation,
    expectation_index: usize,
    transfer_encoding: union(enum) {
        chunked,
        content_length: usize,
        none,
    } = .none,

    pub fn sendBodyComplete(self: *MockRequest, payload: []const u8) !void {
        if (self.expectation.expected_payload) |expected| {
            try std.testing.expectEqualStrings(expected, payload);
        } else {
            try std.testing.expect(payload.len == 0);
        }
    }

    pub fn receiveHead(self: *MockRequest, redirect_buffer: []const u8) !MockResponse {
        _ = redirect_buffer;
        if (self.client.call_counts) |counts| {
            counts[self.expectation_index] += 1;
        }
        return MockResponse{
            .head = .{
                .status = self.expectation.response_status,
            },
            .r = std.Io.Reader.fixed(self.expectation.response_body),
        };
    }

    pub fn deinit(self: *MockRequest) void {
        _ = self;
    }
};

pub const MockResponse = struct {
    head: struct {
        status: std.http.Status,
    },
    r: std.Io.Reader,

    pub fn reader(self: *MockResponse, transfer_buffer: []u8) *std.Io.Reader {
        _ = transfer_buffer;
        return &self.r;
    }
};

fn matchExpectationWithoutPayload(options: anytype, expectation: RequestExpectation) bool {
    if (!std.mem.eql(u8, expectation.expected_scheme, options.location.uri.scheme)) return false;

    if (options.location.uri.host) |host| {
        if (!std.mem.eql(u8, expectation.expected_host, host.percent_encoded)) return false;
    } else {
        return false;
    }

    if (!std.mem.eql(u8, expectation.expected_path, options.location.uri.path.percent_encoded)) return false;

    if (options.location.uri.query) |query| {
        if (expectation.expected_query) |expected| {
            if (!std.mem.eql(u8, expected, query.percent_encoded)) return false;
        } else {
            return false;
        }
    } else {
        if (expectation.expected_query != null) return false;
    }

    const method = if (@hasField(@TypeOf(options), "method")) options.method else std.http.Method.GET;
    if (expectation.expected_method != method) return false;

    return true;
}

pub fn request(self: *MockHttpClient, method: std.http.Method, uri: std.Uri, options: anytype) !MockRequest {
    _ = options;
    const dummy_options = .{
        .location = .{ .uri = uri },
        .method = method,
    };

    if (self.sequential) {
        const idx = self.call_index;
        self.call_index += 1;
        if (idx >= self.expectations.len) {
            return error.TooManyCalls;
        }
        const expectation = self.expectations[idx];
        try verifyExpectation(dummy_options, expectation);
        return MockRequest{
            .client = self,
            .expectation = expectation,
            .expectation_index = idx,
        };
    } else {
        for (self.expectations, 0..) |expectation, i| {
            if (matchExpectationWithoutPayload(dummy_options, expectation)) {
                return MockRequest{
                    .client = self,
                    .expectation = expectation,
                    .expectation_index = i,
                };
            }
        }
        return error.NoMatchingExpectation;
    }
}

test "MockHttpClient - non-sequential success & mismatch" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/path?a=b");
    const uri_bad = try std.Uri.parse("https://wrong.com/path");

    var call_counts = [_]usize{0};
    var client = MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/path",
                .expected_query = "a=b",
                .expected_method = .GET,
                .response_status = .ok,
                .response_body = "response_ok",
            },
        },
        .sequential = false,
        .call_counts = &call_counts,
    };

    // Test request method (non-sequential success)
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodyComplete("");
    var resp = try req.receiveHead("");
    const reader = resp.reader(&[_]u8{});
    var buf: [100]u8 = undefined;
    const n = try reader.readSliceShort(&buf);
    try std.testing.expectEqualStrings("response_ok", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 1), call_counts[0]);

    // Test non-sequential mismatch
    _ = client.request(.GET, uri_bad, .{}) catch |err| {
        try std.testing.expectEqual(error.NoMatchingExpectation, err);
    };
}

test "MockHttpClient - sequential success, verification errors, and too many calls" {
    const allocator = std.testing.allocator;
    const uri = try std.Uri.parse("https://example.com/path?a=b");
    const uri_no_query = try std.Uri.parse("https://example.com/path");

    var call_counts = [_]usize{ 0, 0 };
    var client = MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/path",
                .expected_query = "a=b",
                .expected_method = .POST,
                .expected_payload = "payload_data",
                .response_status = .ok,
                .response_body = "seq1",
            },
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/path",
                .expected_query = null,
                .expected_method = .GET,
                .response_status = .ok,
                .response_body = "seq2",
            },
        },
        .sequential = true,
        .call_counts = &call_counts,
    };

    // 1. Match first sequential (POST with payload)
    var response_buf = std.Io.Writer.Allocating.init(allocator);
    defer response_buf.deinit();
    const res1 = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &response_buf.writer,
        .method = .POST,
        .payload = "payload_data",
    });
    try std.testing.expectEqual(std.http.Status.ok, res1.status);
    try std.testing.expectEqualStrings("seq1", response_buf.written());
    try std.testing.expectEqual(@as(usize, 1), call_counts[0]);

    // 2. Match second sequential (GET, no query, no payload)
    var response_buf2 = std.Io.Writer.Allocating.init(allocator);
    defer response_buf2.deinit();
    const res2 = try client.fetch(.{
        .location = .{ .uri = uri_no_query },
        .response_writer = &response_buf2.writer,
        .method = .GET,
    });
    try std.testing.expectEqual(std.http.Status.ok, res2.status);
    try std.testing.expectEqualStrings("seq2", response_buf2.written());
    try std.testing.expectEqual(@as(usize, 1), call_counts[1]);

    // 3. Too many calls error
    _ = client.fetch(.{
        .location = .{ .uri = uri_no_query },
        .response_writer = &response_buf2.writer,
    }) catch |err| {
        try std.testing.expectEqual(error.TooManyCalls, err);
    };
}

test "MockHttpClient - verification errors unexpected query" {
    const allocator = std.testing.allocator;
    const uri_with_query = try std.Uri.parse("https://example.com/path?a=b");

    var client = MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/path",
                .expected_query = null,
                .expected_method = .GET,
                .response_status = .ok,
                .response_body = "",
            },
        },
        .sequential = true,
    };
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.UnexpectedQuery, client.fetch(.{
        .location = .{ .uri = uri_with_query },
        .response_writer = &w.writer,
    }));
}

test "MockHttpClient - verification errors expected payload but got none" {
    const allocator = std.testing.allocator;
    const uri_no_query = try std.Uri.parse("https://example.com/path");

    var client = MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/path",
                .expected_query = null,
                .expected_method = .POST,
                .expected_payload = "some_payload",
                .response_status = .ok,
                .response_body = "",
            },
        },
        .sequential = true,
    };
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.ExpectedPayloadButGotNone, client.fetch(.{
        .location = .{ .uri = uri_no_query },
        .response_writer = &w.writer,
        .method = .POST,
    }));
}

test "MockHttpClient - verification errors unexpected payload" {
    const allocator = std.testing.allocator;
    const uri_no_query = try std.Uri.parse("https://example.com/path");

    var client = MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/path",
                .expected_query = null,
                .expected_method = .POST,
                .expected_payload = null,
                .response_status = .ok,
                .response_body = "",
            },
        },
        .sequential = true,
    };
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try std.testing.expectError(error.UnexpectedPayload, client.fetch(.{
        .location = .{ .uri = uri_no_query },
        .response_writer = &w.writer,
        .method = .POST,
        .payload = "unexpected_payload_data",
    }));
}

test "MockHttpClient - sequential request flow" {
    const allocator = std.testing.allocator;
    const uri_post = try std.Uri.parse("https://example.com/post");
    const uri_get = try std.Uri.parse("https://example.com/get");

    var call_counts = [_]usize{ 0, 0 };
    var client = MockHttpClient{
        .allocator = allocator,
        .expectations = &.{
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/post",
                .expected_query = null,
                .expected_method = .POST,
                .expected_payload = "payload123",
                .response_status = .ok,
                .response_body = "response_post",
            },
            .{
                .expected_scheme = "https",
                .expected_host = "example.com",
                .expected_path = "/get",
                .expected_query = null,
                .expected_method = .GET,
                .expected_payload = null,
                .response_status = .ok,
                .response_body = "response_get",
            },
        },
        .sequential = true,
        .call_counts = &call_counts,
    };

    // 1. POST request
    {
        var req = try client.request(.POST, uri_post, .{});
        defer req.deinit();
        try req.sendBodyComplete("payload123");
        var resp = try req.receiveHead("");
        const reader = resp.reader(&[_]u8{});
        var buf: [100]u8 = undefined;
        const n = try reader.readSliceShort(&buf);
        try std.testing.expectEqualStrings("response_post", buf[0..n]);
        try std.testing.expectEqual(@as(usize, 1), call_counts[0]);
    }

    // 2. GET request
    {
        var req = try client.request(.GET, uri_get, .{});
        defer req.deinit();
        try req.sendBodyComplete("");
        var resp = try req.receiveHead("");
        const reader = resp.reader(&[_]u8{});
        var buf: [100]u8 = undefined;
        const n = try reader.readSliceShort(&buf);
        try std.testing.expectEqualStrings("response_get", buf[0..n]);
        try std.testing.expectEqual(@as(usize, 1), call_counts[1]);
    }

    // 3. Too many calls error
    try std.testing.expectError(error.TooManyCalls, client.request(.GET, uri_get, .{}));
}
