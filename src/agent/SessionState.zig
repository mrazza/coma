//! Manages typed, session-scoped state objects. Within a given session there is one instance
//! of each `type`.

const std = @import("std");
const Tool = @import("Tool.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const SessionState = @This();

allocator: Allocator,
arena_allocator: ArenaAllocator,
state_store: std.AutoHashMapUnmanaged(usize, *anyopaque),
context_injections: std.AutoHashMapUnmanaged(*const Tool, []const u8),

/// Initializes a new `SessionState` instance.
///
/// `allocator` to be used to store session state objects and internal memory.
pub fn init(allocator: Allocator) SessionState {
    return .{
        .allocator = allocator,
        .arena_allocator = .init(allocator),
        .state_store = .{},
        .context_injections = .{},
    };
}

/// Deinitializes the `SessionState`, releasing the state store map and all stored state
/// objects allocated in the internal arena allocator.
pub fn deinit(self: *SessionState) void {
    self.state_store.deinit(self.allocator);
    var it = self.context_injections.valueIterator();
    while (it.next()) |v| {
        self.allocator.free(v.*);
    }
    self.context_injections.deinit(self.allocator);
    self.arena_allocator.deinit();
    self.* = undefined;
}

/// Retrieves a pointer to the state object of type `T`, initializing it first if it does not already exist.
///
/// If an instance of `T` does not exist in the store, memory for `T` is allocated using an internal allocator.
/// This memory is managed by this struct. It need not be freed by the caller.
/// If `constructor` is provided, it is invoked with the pointer to the newly allocated `T` and an `Allocator`
/// (from the session's internal arena) to initialize its fields.
///
/// Returns a pointer to the existing or newly initialized instance of `T`.
pub fn getOrInitState(self: *SessionState, comptime T: type, comptime constructor: ?fn (*T, Allocator) anyerror!void) !*T {
    const obj_allocator = self.arena_allocator.allocator();
    const type_id = typeId(T);
    const store_result = try self.state_store.getOrPut(self.allocator, type_id);

    if (store_result.found_existing) {
        return @ptrCast(@alignCast(store_result.value_ptr.*));
    }

    const alloc_ptr = try obj_allocator.create(T);
    errdefer {
        obj_allocator.destroy(alloc_ptr);
        _ = self.state_store.remove(type_id);
    }

    if (constructor) |c| {
        try c(alloc_ptr, obj_allocator);
    }

    store_result.value_ptr.* = alloc_ptr;
    return alloc_ptr;
}

/// Returns a pointer to the state object of type `T` if it exists in the store, or `null` if it has not been initialized.
pub fn getState(self: *const SessionState, comptime T: type) ?*T {
    const ptr = self.state_store.get(typeId(T)) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Generates a unique numeric identifier for a given type `T` using the memory address of a static variable.
fn typeId(comptime T: type) usize {
    const Container = struct {
        comptime {
            _ = T;
        }
        var id: u8 = 0;
    };
    return @intFromPtr(&Container.id);
}

/// Associates additional prompt context string with a specific `Tool`.
///
/// This context will be injected ahead of the user prompt or tool result each turn.
/// This call copies the context-slice internally and so it has no lifetime requirements
/// beyond this call.
///
/// If a context association already exists for `tool`, it is overwritten.
pub fn setInjectedContext(self: *SessionState, tool: *const Tool, context: []const u8) !void {
    const context_copy = try self.allocator.dupe(u8, context);
    errdefer self.allocator.free(context_copy);
    self.clearInjectedContext(tool);
    try self.context_injections.put(self.allocator, tool, context_copy);
}

/// Removes any injected context string associated with `tool`.
///
/// If no context association exists for `tool`, this function is a no-op.
pub fn clearInjectedContext(self: *SessionState, tool: *const Tool) void {
    const existing = self.context_injections.fetchRemove(tool);
    if (existing) |entry| {
        self.allocator.free(entry.value);
    }
}

/// Returns the injected context string associated with `tool`, or `null` if none has been set.
pub fn getInjectedContext(self: *const SessionState, tool: *const Tool) ?[]const u8 {
    return self.context_injections.get(tool);
}

/// Formats and combines all registered tool context injections into a single string to be prepended
/// to the LLM system prompt, or `null` if no context injections are present.
///
/// The resulting string is dynamically allocated using `allocator`. The caller owns the returned memory.
pub fn getInjectedContextString(self: *const SessionState, allocator: Allocator) !?[]const u8 {
    if (self.context_injections.count() == 0) return null;

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var iterator = self.context_injections.iterator();
    while (iterator.next()) |entry| {
        const tool = entry.key_ptr.*;
        const context = entry.value_ptr.*;
        try list.appendSlice(allocator, "[TOOL_CONTEXT: ");
        try list.appendSlice(allocator, tool.descriptor.name);
        try list.appendSlice(allocator, "]\n");
        try list.appendSlice(allocator, context);
        try list.appendSlice(allocator, "\n[/TOOL_CONTEXT]\n\n");
    }

    return try list.toOwnedSlice(allocator);
}

test getOrInitState {
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const DummyState = struct {
        count: u32,
        buffer: []u8,

        fn initFn(self: *@This(), allocator: Allocator) !void {
            self.count = 100;
            self.buffer = try allocator.alloc(u8, 16);
            @memset(self.buffer, 0xAB);
        }
    };

    // First call initializes
    const ptr1 = try state.getOrInitState(DummyState, DummyState.initFn);
    try std.testing.expectEqual(100, ptr1.count);
    try std.testing.expectEqual(16, ptr1.buffer.len);
    try std.testing.expectEqual(0xAB, ptr1.buffer[0]);

    // Second call returns cached pointer
    const ptr2 = try state.getOrInitState(DummyState, DummyState.initFn);
    try std.testing.expectEqual(ptr1, ptr2);
}

test "getOrInit without constructor" {
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const Config = struct {
        value: i32 = 42,
    };

    const ptr1 = try state.getOrInitState(Config, null);
    ptr1.value = 123;

    const ptr2 = try state.getOrInitState(Config, null);
    try std.testing.expectEqual(123, ptr2.value);
    try std.testing.expectEqual(ptr1, ptr2);
}

test "getOrInit constructor error cleanup" {
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const FailingState = struct {
        fn initFail(_: *@This(), _: Allocator) !void {
            return error.InitializationFailed;
        }
    };

    try std.testing.expectError(error.InitializationFailed, state.getOrInitState(FailingState, FailingState.initFail));
    try std.testing.expectEqual(null, state.getState(FailingState));
}

test getState {
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const Config = struct {
        value: i32 = 42,
    };

    try std.testing.expectEqual(null, state.getState(Config));

    const ptr1 = try state.getOrInitState(Config, null);
    ptr1.value = 100;

    const ptr2 = state.getState(Config);
    try std.testing.expect(ptr2 != null);
    try std.testing.expectEqual(ptr1, ptr2.?);
    try std.testing.expectEqual(100, ptr2.?.value);
}

test typeId {
    const id_u32_1 = typeId(u32);
    const id_u32_2 = typeId(u32);
    const id_u64 = typeId(u64);
    const id_str = typeId([]const u8);

    try std.testing.expectEqual(id_u32_1, id_u32_2);
    try std.testing.expect(id_u32_1 != id_u64);
    try std.testing.expect(id_u32_1 != id_str);
    try std.testing.expect(id_u64 != id_str);
}

test setInjectedContext {
    const llm = @import("llm");
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const tool_desc: llm.types.Tool = .{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    };
    const tool_impl = struct {
        pub fn run() ![]const u8 {
            return "";
        }
    };
    const tool = Tool.init(tool_desc, tool_impl.run);

    try state.setInjectedContext(&tool, "System context info");
    try std.testing.expectEqualStrings("System context info", state.getInjectedContext(&tool).?);

    // Overwrite existing context
    try state.setInjectedContext(&tool, "Updated context info");
    try std.testing.expectEqualStrings("Updated context info", state.getInjectedContext(&tool).?);
}

test getInjectedContext {
    const llm = @import("llm");
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const tool_desc: llm.types.Tool = .{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    };
    const tool_impl = struct {
        pub fn run() ![]const u8 {
            return "";
        }
    };
    const tool = Tool.init(tool_desc, tool_impl.run);

    try std.testing.expectEqual(null, state.getInjectedContext(&tool));

    try state.setInjectedContext(&tool, "System context info");
    try std.testing.expectEqualStrings("System context info", state.getInjectedContext(&tool).?);
}

test clearInjectedContext {
    const llm = @import("llm");
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const tool_desc: llm.types.Tool = .{
        .name = "dummy_tool",
        .description = "A dummy tool",
        .parameters = &.{},
    };
    const tool_impl = struct {
        pub fn run() ![]const u8 {
            return "";
        }
    };
    const tool = Tool.init(tool_desc, tool_impl.run);

    // Clearing non-existent entry is a safe no-op
    state.clearInjectedContext(&tool);
    try std.testing.expectEqual(null, state.getInjectedContext(&tool));

    try state.setInjectedContext(&tool, "Some context");
    try std.testing.expectEqualStrings("Some context", state.getInjectedContext(&tool).?);

    state.clearInjectedContext(&tool);
    try std.testing.expectEqual(null, state.getInjectedContext(&tool));
}

test getInjectedContextString {
    const llm = @import("llm");
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    // Empty state returns null
    const empty_str = try state.getInjectedContextString(std.testing.allocator);
    try std.testing.expectEqual(null, empty_str);

    // Single tool context injection
    const tool_desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "Test tool description",
        .parameters = &.{},
    };
    const tool_impl = struct {
        pub fn run() ![]const u8 {
            return "";
        }
    };
    const tool = Tool.init(tool_desc, tool_impl.run);

    try state.setInjectedContext(&tool, "Use carefully.");
    const single_str = (try state.getInjectedContextString(std.testing.allocator)).?;
    defer std.testing.allocator.free(single_str);
    const expected_single = "[TOOL_CONTEXT: test_tool]\nUse carefully.\n[/TOOL_CONTEXT]\n\n";
    try std.testing.expectEqualStrings(expected_single, single_str);
}
