const std = @import("std");
const llm = @import("llm");
const agent = @import("agent");
const types = agent.types;

pub const color_reset = "\x1b[0m";
pub const color_bold = "\x1b[1m";
pub const color_gray = "\x1b[90m";
pub const color_blue = "\x1b[34m";
pub const color_cyan = "\x1b[36m";
pub const color_green = "\x1b[32m";
pub const color_yellow = "\x1b[33m";

pub const StreamContext = struct {
    allocator: std.mem.Allocator,
    current_type: ?llm.types.StepType = null,
    in_code_block: bool = false,
    in_inline_code: bool = false,
    in_bold: bool = false,
    in_italic: bool = false,
    backtick_count: u8 = 0,
    asterisk_count: u8 = 0,
};

pub fn restoreStyle(stream_ctx: *StreamContext) void {
    if (stream_ctx.in_code_block) {
        std.debug.print("{s}", .{color_yellow});
    } else if (stream_ctx.in_inline_code) {
        std.debug.print("{s}", .{color_yellow});
    } else {
        if (stream_ctx.current_type) |t| {
            switch (t) {
                .thought => std.debug.print("{s}", .{color_gray}),
                .model_output => std.debug.print("{s}", .{color_reset}),
                .tool_call => std.debug.print("{s}", .{color_yellow}),
            }
        }
    }
}

pub fn flushBackticks(stream_ctx: *StreamContext) void {
    const count = stream_ctx.backtick_count;
    if (count == 0) return;
    stream_ctx.backtick_count = 0;
    if (count == 3) {
        stream_ctx.in_code_block = !stream_ctx.in_code_block;
        if (stream_ctx.in_code_block) {
            std.debug.print("{s}", .{color_yellow});
        } else {
            std.debug.print("{s}", .{color_reset});
            restoreStyle(stream_ctx);
        }
    } else if (count == 1) {
        stream_ctx.in_inline_code = !stream_ctx.in_inline_code;
        if (stream_ctx.in_inline_code) {
            std.debug.print("{s}", .{color_yellow});
        } else {
            std.debug.print("{s}", .{color_reset});
            restoreStyle(stream_ctx);
        }
    } else {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            std.debug.print("`", .{});
        }
    }
}

pub fn flushAsterisks(stream_ctx: *StreamContext) void {
    const count = stream_ctx.asterisk_count;
    if (count == 0) return;
    stream_ctx.asterisk_count = 0;
    if (count == 2) {
        stream_ctx.in_bold = !stream_ctx.in_bold;
        if (stream_ctx.in_bold) {
            std.debug.print("{s}", .{color_bold});
        } else {
            std.debug.print("{s}", .{color_reset});
            restoreStyle(stream_ctx);
        }
    } else if (count == 1) {
        stream_ctx.in_italic = !stream_ctx.in_italic;
        if (stream_ctx.in_italic) {
            std.debug.print("\x1b[3m", .{});
        } else {
            std.debug.print("\x1b[23m", .{});
        }
    } else {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            std.debug.print("*", .{});
        }
    }
}

pub fn printMarkdown(stream_ctx: *StreamContext, text: []const u8) void {
    restoreStyle(stream_ctx);
    for (text) |char| {
        if (char == '`') {
            flushAsterisks(stream_ctx);
            stream_ctx.backtick_count += 1;
            continue;
        }
        if (char == '*') {
            flushBackticks(stream_ctx);
            stream_ctx.asterisk_count += 1;
            continue;
        }

        flushBackticks(stream_ctx);
        flushAsterisks(stream_ctx);
        std.debug.print("{c}", .{char});
    }
}

pub fn streamCallback(ctx: ?*anyopaque, agent_chunk: types.StreamingChunk) void {
    const stream_ctx: *StreamContext = @ptrCast(@alignCast(ctx));
    switch (agent_chunk) {
        .model_chunk => |chunk| {
            switch (chunk.event) {
                .interaction_created => {},
                .step_event => |step_ev| {
                    switch (step_ev.event) {
                        .start => |start_payload| {
                            switch (start_payload) {
                                .thought => {
                                    if (stream_ctx.current_type != .thought) {
                                        std.debug.print("{s}Thinking...{s}\n", .{ color_gray, color_reset });
                                        stream_ctx.current_type = .thought;
                                    }
                                },
                                .model_output => {
                                    if (stream_ctx.current_type != .model_output) {
                                        std.debug.print("\n{s}Agent >{s} ", .{ color_cyan ++ color_bold, color_reset });
                                        stream_ctx.current_type = .model_output;
                                    }
                                },
                                .tool_call => |tc| {
                                    std.debug.print("\n{s}[Tool Call ({s}): {s}]{s}\n", .{ color_yellow, tc.id, tc.name, color_reset });
                                    stream_ctx.current_type = .tool_call;
                                },
                            }
                        },
                        .delta => |delta| {
                            switch (delta) {
                                .thought => |thought| {
                                    if (stream_ctx.current_type != .thought) {
                                        std.debug.print("{s}Thinking...{s}\n", .{ color_gray, color_reset });
                                        stream_ctx.current_type = .thought;
                                    }
                                    printMarkdown(stream_ctx, thought.text);
                                },
                                .model_output => |mo| {
                                    if (stream_ctx.current_type != .model_output) {
                                        std.debug.print("\n{s}Agent >{s} ", .{ color_cyan ++ color_bold, color_reset });
                                        stream_ctx.current_type = .model_output;
                                    }
                                    switch (mo) {
                                        .text => |text| {
                                            printMarkdown(stream_ctx, text);
                                        },
                                    }
                                },
                                .tool_call => |dt| {
                                    for (dt.arguments) |arg| {
                                        switch (arg.value) {
                                            .string => |s| std.debug.print("  {s}({s}): \"{s}\"\n", .{ dt.id, arg.name, s }),
                                            .integer => |i| std.debug.print("  {s}({s}): {}\n", .{ dt.id, arg.name, i }),
                                            .float => |f| std.debug.print("  {s}({s}): {d}\n", .{ dt.id, arg.name, f }),
                                            .boolean => |b| std.debug.print("  {s}({s}): {}\n", .{ dt.id, arg.name, b }),
                                        }
                                    }
                                },
                            }
                        },
                        .end => {},
                    }
                },
                .interaction_completed => {
                    flushBackticks(stream_ctx);
                    flushAsterisks(stream_ctx);
                },
            }
        },
        .tool_result => |tr| {
            std.debug.print("{s}Output ({s}):{s}\n{s}\n", .{ color_green, tr.id, color_reset, tr.result });
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
