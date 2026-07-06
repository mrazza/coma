const std = @import("std");

pub const Gemini = @import("google/provider.zig").Gemini;

test {
    std.testing.refAllDecls(@This());
}
