const std = @import("std");

pub const Server = @import("Server.zig");

test {
    std.testing.refAllDecls(@This());
}
