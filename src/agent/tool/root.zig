const std = @import("std");

/// A simple todo list tool for managing tasks.
pub const Todo = @import("todo.zig").Tool;

test {
    std.testing.refAllDecls(@This());
}

