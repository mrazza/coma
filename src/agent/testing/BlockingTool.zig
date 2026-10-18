//! A test tool implementation that blocks until `should_stop` is set to true
//! or the underlying I/O context is canceled.

const std = @import("std");
const Io = std.Io;
const llm = @import("llm");
const Tool = @import("../Tool.zig");

const BlockingTool = @This();

/// Full descriptor for the blocking test tool.
pub const descriptor: llm.types.Tool = .{
    .name = "blocking_tool",
    .description = "A test tool that blocks until signaled to stop",
    .parameters = &.{},
};

tool: Tool,
started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
io: Io,

pub fn init(io: Io) BlockingTool {
    return .{
        .tool = Tool.init(descriptor, execute),
        .io = io,
    };
}

/// Execution function using @fieldParentPtr.
pub fn execute(tool_ptr: *const Tool, alloc: std.mem.Allocator) error{ ArgumentMismatch, ArgumentTypeMismatch, OutOfMemory, RequiredArgumentMissing }![]const u8 {
    const self: *BlockingTool = @constCast(@fieldParentPtr("tool", tool_ptr));
    self.started.store(true, .monotonic);
    while (!self.should_stop.load(.monotonic)) {
        self.io.checkCancel() catch return error.OutOfMemory;
    }
    return alloc.dupe(u8, "blocking tool done") catch return error.OutOfMemory;
}

/// Returns true if the tool execution function has been entered.
pub fn isStarted(self: *const BlockingTool) bool {
    return self.started.load(.monotonic);
}

/// Blocks until the tool execution function is entered.
pub fn waitUntilStarted(self: *const BlockingTool) void {
    var attempts: usize = 0;
    while (!self.isStarted() and attempts < 1_000_000) : (attempts += 1) {
        std.atomic.spinLoopHint();
    }
}

/// Signals the tool execution to stop blocking and exit.
pub fn stop(self: *BlockingTool) void {
    self.should_stop.store(true, .monotonic);
}
