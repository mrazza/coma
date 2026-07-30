//! An I/O reader implementation for testing that blocks until `should_stop` is set to true
//! or the underlying I/O context is canceled.

const std = @import("std");
const Io = std.Io;

const BlockingReader = @This();

reader: Io.Reader,
io: Io,
buf: [128]u8 = undefined,
started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

pub fn init(io: Io) BlockingReader {
    var self: BlockingReader = .{
        .reader = .{
            .vtable = &vtable,
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        },
        .io = io,
    };
    self.reader.buffer = &self.buf;
    return self;
}

/// Returns true if the reader stream callback has been entered.
pub fn isStarted(self: *const BlockingReader) bool {
    return self.started.load(.monotonic);
}

/// Blocks until the stream callback is entered.
pub fn waitUntilStarted(self: *const BlockingReader) void {
    var attempts: usize = 0;
    while (!self.isStarted() and attempts < 1_000_000) : (attempts += 1) {
        std.atomic.spinLoopHint();
    }
}

/// Signals the reader stream to stop blocking and exit.
pub fn stop(self: *BlockingReader) void {
    self.should_stop.store(true, .monotonic);
}

const vtable: Io.Reader.VTable = .{
    .stream = stream,
};

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    _ = w;
    _ = limit;
    const self: *BlockingReader = @fieldParentPtr("reader", r);
    self.started.store(true, .monotonic);
    while (!self.should_stop.load(.monotonic)) {
        self.io.checkCancel() catch return error.ReadFailed;
    }
    return error.EndOfStream;
}
