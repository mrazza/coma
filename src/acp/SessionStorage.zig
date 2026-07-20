//! Manages the storage and tracking of sessions in an ACP server.

const std = @import("std");
const agent = @import("agent");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const SessionStorage = @This();

allocator: Allocator,
sessions: std.StringHashMap(*SessionState),
session_counter: u64,

const SessionState = struct {
    id: []const u8,
    session: agent.Session,
};

pub fn init(allocator: Allocator) SessionStorage {
    return .{ .allocator = allocator, .sessions = .init(allocator), .session_counter = 0 };
}

pub fn deinit(self: *SessionStorage) void {
    var it = self.sessions.valueIterator();
    while (it.next()) |state_ptr| {
        const state = state_ptr.*;
        state.session.deinit();
        self.allocator.free(state.id);
        self.allocator.destroy(state);
    }
    self.sessions.deinit();
}

pub const SessionInitArgs = std.meta.ArgsTuple(@TypeOf(agent.Session.init));
pub fn createSession(self: *SessionStorage, args: SessionInitArgs) !*SessionState {
    const session_id = try std.fmt.allocPrint(self.allocator, "session_{}", .{self.session_counter});
    errdefer self.allocator.free(session_id);
    self.session_counter += 1;
    const session_state = try self.allocator.create(SessionState);
    session_state.* = .{ .id = session_id, .session = try @call(.auto, agent.Session.init, args) };
    self.sessions.put(session_id, session_state) catch |err| {
        session_state.session.deinit();
        self.allocator.destroy(session_state);
        return err;
    };
    return session_state;
}

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
