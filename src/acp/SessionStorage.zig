//! Manages the storage and tracking of sessions in an ACP server.

const std = @import("std");
const agent = @import("agent");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// ACP session storage container.
const SessionStorage = @This();

allocator: Allocator,
sessions: std.StringHashMapUnmanaged(*SessionState),
session_counter: u64,

/// Holds state for an active ACP session, including its unique ID and underlying `agent.Session`.
pub const SessionState = struct {
    id: []const u8,
    session: agent.Session,
};

/// Initializes an empty `SessionStorage` instance.
pub fn init(allocator: Allocator) SessionStorage {
    return .{ .allocator = allocator, .sessions = .{}, .session_counter = 0 };
}

/// Frees all stored session states, IDs, and internal map memory.
pub fn deinit(self: *SessionStorage) void {
    var it = self.sessions.valueIterator();
    while (it.next()) |state_ptr| {
        const state = state_ptr.*;
        state.session.deinit();
        self.allocator.free(state.id);
        self.allocator.destroy(state);
    }
    self.sessions.deinit(self.allocator);
}

/// Tuple type representing the argument types required by `agent.Session.init`.
pub const SessionInitArgs = std.meta.ArgsTuple(@TypeOf(agent.Session.init));

/// Creates and stores a new `SessionState` with an auto-generated session ID.
pub fn createSession(self: *SessionStorage, args: SessionInitArgs) !*SessionState {
    const session_id = try std.fmt.allocPrint(self.allocator, "session_{}", .{self.session_counter});
    errdefer self.allocator.free(session_id);

    const session_state = try self.allocator.create(SessionState);
    errdefer self.allocator.destroy(session_state);

    var session = try @call(.auto, agent.Session.init, args);
    errdefer session.deinit();
    session_state.* = .{ .id = session_id, .session = session };

    try self.sessions.put(self.allocator, session_id, session_state);

    self.session_counter += 1;
    return session_state;
}

/// Retrieves a pointer to a `SessionState` by its session ID.
///
/// Returns `error.SessionNotFound` if no session matches `id`.
pub fn getSession(self: *const SessionStorage, id: []const u8) !*SessionState {
    return self.sessions.get(id) orelse return error.SessionNotFound;
}

const testing = @import("testing");

test createSession {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var mock_provider: testing.MockProvider = .{};

    var session_storage = init(allocator);
    defer session_storage.deinit();
    const session_state = try session_storage.createSession(.{
        allocator, io, mock_provider.provider(),
        .{
            .model = .{
                .id = "mock-model",
                .display_name = "Mock Model",
            },
            .tools = &.{},
        },
    });
    const session = session_state.session;
    try std.testing.expectEqualStrings("session_0", session_state.id);
    try std.testing.expectEqual(mock_provider.provider(), session.provider);
}

test getSession {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var mock_provider: testing.MockProvider = .{};

    var session_storage = init(allocator);
    defer session_storage.deinit();

    const session_state = try session_storage.createSession(.{
        allocator, io, mock_provider.provider(),
        .{
            .model = .{
                .id = "mock-model",
                .display_name = "Mock Model",
            },
            .tools = &.{},
        },
    });
    const session = &session_state.session;
    try std.testing.expectEqual(mock_provider.provider(), session.provider);

    const retrieved_session_state = try session_storage.getSession("session_0");
    try std.testing.expectEqual(&retrieved_session_state.session, session);

    const session_not_found = session_storage.getSession("session_1");
    try std.testing.expectError(error.SessionNotFound, session_not_found);
}
