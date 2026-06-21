const std = @import("std");

const MockHttpClient = @This();

pub const RequestExpectation = struct {
    expected_scheme: []const u8,
    expected_host: []const u8,
    expected_path: []const u8,
    expected_query: ?[]const u8 = null,
    expected_method: std.http.Method,
    expected_payload: ?[]const u8 = null,
    response_status: std.http.Status,
    response_body: []const u8,
};

expectations: []const RequestExpectation,
sequential: bool = false,
call_counts: ?[]usize = null,
call_index: usize = 0,

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
            return error.ExpectedPayloadButGotNone;
        }
    } else {
        if (@hasField(@TypeOf(options), "payload")) {
            if (options.payload.len > 0) {
                return error.UnexpectedPayload;
            }
        }
    }
}

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
