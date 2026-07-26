//! Execution context provided to a `Tool` during call execution.
//! Encapsulates both the specific `Tool` being executed and the `SessionState`.

const std = @import("std");
const SessionState = @import("SessionState.zig");
const Tool = @import("Tool.zig");

const Allocator = std.mem.Allocator;

const ToolCallContext = @This();

tool: *const Tool,
session_state: *SessionState,

/// Associates additional prompt context string with the calling tool.
///
/// This context will be injected ahead of the user prompt or tool result each turn.
/// This call copies the context-slice internally and so it has no lifetime requirements
/// beyond this call.
///
/// If a context association already exists for the calling tool, it is overwritten.
pub fn setInjectedContext(self: ToolCallContext, context: []const u8) !void {
    return self.session_state.setInjectedContext(self.tool, context);
}

/// Removes any injected context string associated with the calling tool.
///
/// If no context association exists for the calling tool, this function is a no-op.
pub fn clearInjectedContext(self: ToolCallContext) void {
    self.session_state.clearInjectedContext(self.tool);
}

/// Returns the injected context string associated with the calling tool, or `null` if none has been set.
pub fn getInjectedContext(self: ToolCallContext) ?[]const u8 {
    return self.session_state.getInjectedContext(self.tool);
}

/// Retrieves a pointer to the state object of type `T`, initializing it first if it does not already exist.
///
/// If an instance of `T` does not exist in the store, memory for `T` is allocated using an internal allocator.
/// Memory is managed by `SessionState`.
pub fn getOrInitState(self: ToolCallContext, comptime T: type, comptime constructor: ?fn (*T, Allocator) anyerror!void) !*T {
    return self.session_state.getOrInitState(T, constructor);
}

/// Returns a pointer to the state object of type `T` if it exists in the store, or `null` if it has not been initialized.
pub fn getState(self: ToolCallContext, comptime T: type) ?*T {
    return self.session_state.getState(T);
}

test setInjectedContext {
    var session_state = SessionState.init(std.testing.allocator);
    defer session_state.deinit();

    const tool = Tool.init(.{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    }, struct {
        fn run() ![]const u8 {
            return "";
        }
    }.run);

    const call_ctx: ToolCallContext = .{
        .tool = &tool,
        .session_state = &session_state,
    };

    try call_ctx.setInjectedContext("System context info");
    try std.testing.expectEqualStrings("System context info", session_state.getInjectedContext(&tool).?);
}

test clearInjectedContext {
    var session_state = SessionState.init(std.testing.allocator);
    defer session_state.deinit();

    const tool = Tool.init(.{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    }, struct {
        fn run() ![]const u8 {
            return "";
        }
    }.run);

    const call_ctx: ToolCallContext = .{
        .tool = &tool,
        .session_state = &session_state,
    };

    try call_ctx.setInjectedContext("System context info");
    try std.testing.expectEqualStrings("System context info", call_ctx.getInjectedContext().?);

    call_ctx.clearInjectedContext();
    try std.testing.expectEqual(null, call_ctx.getInjectedContext());
}

test getInjectedContext {
    var session_state = SessionState.init(std.testing.allocator);
    defer session_state.deinit();

    const tool = Tool.init(.{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    }, struct {
        fn run() ![]const u8 {
            return "";
        }
    }.run);

    const call_ctx: ToolCallContext = .{
        .tool = &tool,
        .session_state = &session_state,
    };

    try std.testing.expectEqual(null, call_ctx.getInjectedContext());

    try call_ctx.setInjectedContext("System context info");
    try std.testing.expectEqualStrings("System context info", call_ctx.getInjectedContext().?);
}

test getOrInitState {
    var session_state = SessionState.init(std.testing.allocator);
    defer session_state.deinit();

    const tool = Tool.init(.{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    }, struct {
        fn run() ![]const u8 {
            return "";
        }
    }.run);

    const call_ctx: ToolCallContext = .{
        .tool = &tool,
        .session_state = &session_state,
    };

    const DummyState = struct {
        count: u32,
        fn initFn(self: *@This(), _: Allocator) !void {
            self.count = 100;
        }
    };

    const ptr = try call_ctx.getOrInitState(DummyState, DummyState.initFn);
    try std.testing.expectEqual(100, ptr.count);
}

test getState {
    var session_state = SessionState.init(std.testing.allocator);
    defer session_state.deinit();

    const tool = Tool.init(.{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    }, struct {
        fn run() ![]const u8 {
            return "";
        }
    }.run);

    const call_ctx: ToolCallContext = .{
        .tool = &tool,
        .session_state = &session_state,
    };

    const Config = struct {
        value: i32 = 42,
    };

    try std.testing.expectEqual(null, call_ctx.getState(Config));

    const ptr1 = try call_ctx.getOrInitState(Config, null);
    ptr1.value = 100;

    const ptr2 = call_ctx.getState(Config);
    try std.testing.expect(ptr2 != null);
    try std.testing.expectEqual(100, ptr2.?.value);
}
