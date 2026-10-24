const std = @import("std");

/// A simple todo list tool for managing tasks.
pub const Todo = @import("todo.zig").Tool;

/// Shell tool utilities and pre-configured shell tools.
pub const Shell = @import("shell.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("shell.zig"));
}
