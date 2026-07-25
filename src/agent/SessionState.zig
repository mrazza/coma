//! Manages typed, session-scoped state objects. Within a given session there is one instance
//! of each `type`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const SessionState = @This();

allocator: Allocator,
arena_allocator: ArenaAllocator,
state_store: std.AutoHashMapUnmanaged(usize, *anyopaque),

/// Initializes a new `SessionState` instance.
///
/// `allocator` to be used to store session state objects and internal memory.
pub fn init(allocator: Allocator) SessionState {
    return .{
        .allocator = allocator,
        .arena_allocator = .init(allocator),
        .state_store = .{},
    };
}

/// Deinitializes the `SessionState`, releasing the state store map and all stored state
/// objects allocated in the internal arena allocator.
pub fn deinit(self: *SessionState) void {
    self.state_store.deinit(self.allocator);
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
pub fn getOrInit(self: *SessionState, comptime T: type, comptime constructor: ?fn (*T, Allocator) anyerror!void) !*T {
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
pub fn get(self: *const SessionState, comptime T: type) ?*T {
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

test getOrInit {
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
    const ptr1 = try state.getOrInit(DummyState, DummyState.initFn);
    try std.testing.expectEqual(100, ptr1.count);
    try std.testing.expectEqual(16, ptr1.buffer.len);
    try std.testing.expectEqual(0xAB, ptr1.buffer[0]);

    // Second call returns cached pointer
    const ptr2 = try state.getOrInit(DummyState, DummyState.initFn);
    try std.testing.expectEqual(ptr1, ptr2);
}

test "getOrInit without constructor" {
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const Config = struct {
        value: i32 = 42,
    };

    const ptr1 = try state.getOrInit(Config, null);
    ptr1.value = 123;

    const ptr2 = try state.getOrInit(Config, null);
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

    try std.testing.expectError(error.InitializationFailed, state.getOrInit(FailingState, FailingState.initFail));
    try std.testing.expectEqual(null, state.get(FailingState));
}

test get {
    var state = SessionState.init(std.testing.allocator);
    defer state.deinit();

    const Config = struct {
        value: i32 = 42,
    };

    try std.testing.expectEqual(null, state.get(Config));

    const ptr1 = try state.getOrInit(Config, null);
    ptr1.value = 100;

    const ptr2 = state.get(Config);
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
