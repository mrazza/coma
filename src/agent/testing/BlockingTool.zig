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

const vtable: Tool.VTable = .{
    .execute = Tool.wrapExecute(descriptor, execute),
};

pub const State = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn isStarted(self: *const State) bool {
        return self.started.load(.monotonic);
    }

    pub fn waitUntilStarted(self: *const State) void {
        var attempts: usize = 0;
        while (!self.isStarted() and attempts < 1_000_000) : (attempts += 1) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn stop(self: *State) void {
        self.should_stop.store(true, .monotonic);
    }
};

tool: Tool,
state: *State,
io: Io,

pub fn init(state: *State, io: Io) BlockingTool {
    return .{
        .tool = .{
            .descriptor = descriptor,
            .vtable = &vtable,
        },
        .state = state,
        .io = io,
    };
}

/// Execution function using @fieldParentPtr.
pub fn execute(tool_ptr: *const Tool, alloc: std.mem.Allocator) error{ ArgumentMismatch, ArgumentTypeMismatch, OutOfMemory, RequiredArgumentMissing }![]const u8 {
    const self: *const BlockingTool = @fieldParentPtr("tool", tool_ptr);
    self.state.started.store(true, .monotonic);
    while (!self.state.should_stop.load(.monotonic)) {
        self.io.checkCancel() catch return error.OutOfMemory;
    }
    return alloc.dupe(u8, "blocking tool done") catch return error.OutOfMemory;
}

/// Returns true if the tool execution function has been entered.
pub fn isStarted(self: *const BlockingTool) bool {
    return self.state.isStarted();
}

/// Blocks until the tool execution function is entered.
pub fn waitUntilStarted(self: *const BlockingTool) void {
    self.state.waitUntilStarted();
}

/// Signals the tool execution to stop blocking and exit.
pub fn stop(self: *const BlockingTool) void {
    self.state.stop();
}
