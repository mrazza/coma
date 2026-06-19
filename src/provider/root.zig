pub const Gemini = @import("google/provider.zig").Gemini;

test {
    _ = @import("google/converter.zig");
    _ = @import("google/uri.zig");
    _ = @import("google/provider.zig");
    _ = @import("json_client.zig");
}
