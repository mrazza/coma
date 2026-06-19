const std = @import("std");

const MockHttpClient = @This();

expected_path: []const u8,
expected_query: ?[]const u8 = null,
expected_method: std.http.Method,
expected_payload: ?[]const u8 = null,
response_status: std.http.Status,
response_body: []const u8,

pub fn fetch(self: *MockHttpClient, options: anytype) !struct { status: std.http.Status } {
    // 1. Verify URI
    try std.testing.expectEqualStrings("https", options.location.uri.scheme);
    if (options.location.uri.host) |host| {
        try std.testing.expectEqualStrings("example.com", host.percent_encoded);
    } else {
        return error.ExpectedHost;
    }
    try std.testing.expectEqualStrings(self.expected_path, options.location.uri.path.percent_encoded);

    if (options.location.uri.query) |query| {
        if (self.expected_query) |expected| {
            try std.testing.expectEqualStrings(expected, query.percent_encoded);
        } else {
            return error.UnexpectedQuery;
        }
    } else {
        try std.testing.expect(self.expected_query == null);
    }

    // 2. Verify Method
    const method = if (@hasField(@TypeOf(options), "method")) options.method else std.http.Method.GET;
    try std.testing.expectEqual(self.expected_method, method);

    // 3. Verify Payload
    if (self.expected_payload) |expected| {
        if (@hasField(@TypeOf(options), "payload")) {
            try std.testing.expectEqualStrings(expected, options.payload);
        } else {
            return error.ExpectedPayloadButGotNone;
        }
    } else {
        if (@hasField(@TypeOf(options), "payload")) {
            if (options.payload.len > 0) {
                return error.UnexpectedPayload;
            }
        }
    }

    // 4. Write response body
    _ = try options.response_writer.write(self.response_body);

    return .{ .status = self.response_status };
}
