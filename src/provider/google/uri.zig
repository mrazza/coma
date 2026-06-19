const std = @import("std");

const Allocator = std.mem.Allocator;

const base_uri = "https://generativelanguage.googleapis.com";
const api_version = "v1beta";

/// Helper struct to hold the parts of a Gemini API URI.
pub const UriParts = struct {
    base_uri: []const u8 = base_uri,
    api_version: []const u8 = api_version,
    path: []const []const u8,
    query_params: ?[]const []const u8 = null,
    api_key: []const u8,
};

/// Creates a string representing a URI from the given parts.
/// Allocates space for the URI, so the caller must free the returned string.
pub fn makeUri(allocator: Allocator, uri_parts: UriParts) ![]const u8 {
    const path_str = try std.mem.join(allocator, "/", uri_parts.path);
    defer allocator.free(path_str);

    const query_str = if (uri_parts.query_params) |q| try std.mem.join(allocator, "&", q) else null;
    defer if (query_str) |q| allocator.free(q);

    if (query_str) |q| {
        const parts = [_][]const u8{ uri_parts.base_uri, "/", uri_parts.api_version, "/", path_str, "?key=", uri_parts.api_key, "&", q };
        return try std.mem.concat(allocator, u8, &parts);
    } else {
        const parts = [_][]const u8{ uri_parts.base_uri, "/", uri_parts.api_version, "/", path_str, "?key=", uri_parts.api_key };
        return try std.mem.concat(allocator, u8, &parts);
    }
}

const testing = @import("testing");

test makeUri {
    const singlePathUri = try makeUri(std.testing.allocator, .{ .path = &.{"models"}, .api_key = "TEST_API_KEY" });
    defer std.testing.allocator.free(singlePathUri);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models?key=TEST_API_KEY", singlePathUri);

    const multiPathUri = try makeUri(std.testing.allocator, .{ .path = &.{ "models", "gemini-2.0-flash" }, .api_key = "TEST_API_KEY" });
    defer std.testing.allocator.free(multiPathUri);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash?key=TEST_API_KEY", multiPathUri);

    const queryParamsUri = try makeUri(std.testing.allocator, .{ .path = &.{"models"}, .query_params = &.{ "maxOutputTokens=100", "topP=0.7" }, .api_key = "TEST_API_KEY" });
    defer std.testing.allocator.free(queryParamsUri);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models?key=TEST_API_KEY&maxOutputTokens=100&topP=0.7", queryParamsUri);
}
