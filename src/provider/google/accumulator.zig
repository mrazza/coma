const std = @import("std");
const llm = @import("llm");
const api = @import("api.zig");
const converter = @import("converter.zig");

const Allocator = std.mem.Allocator;
const ProviderError = llm.Provider.ProviderError;

/// Accumulator union used to buffer and aggregate streaming responses for each step.
/// Handles text/thought aggregation and tool call parsing during streaming.
pub const StepAccumulator = union(enum) {
    /// Holds the aggregated thinking/thought process content.
    thought: std.Io.Writer.Allocating,
    /// Holds the aggregated model response output text.
    model_output: std.Io.Writer.Allocating,
    /// Holds tool call details and buffers the arguments JSON stream.
    tool_call: struct {
        /// The unique ID of the tool call.
        id: []const u8,
        /// The name of the function to invoke.
        name: []const u8,
        /// Dynamic writer buffer accumulating arguments JSON text.
        arguments_json: std.Io.Writer.Allocating,
        /// Tracks the count of arguments that have already been streamed out to the callback.
        processed_argument_count: usize,
    },
    /// Represents an uninitialized or empty accumulator slot.
    empty,

    /// Initializes the `StepAccumulator` with an initial step context.
    ///
    /// `result_arena_allocator` is used to allocate the internal writers and copy initial values.
    /// Memory allocated in `result_arena_allocator` is owned by the caller's session arena.
    /// `initial_step` provides the starting type and content (e.g. initial thought, model output, or function call).
    ///
    /// Returns the initialized `StepAccumulator`, or an allocation error.
    pub fn init(result_arena_allocator: Allocator, initial_step: api.Step) !@This() {
        switch (initial_step) {
            .thought => |contents| {
                var list = std.Io.Writer.Allocating.init(result_arena_allocator);
                for (contents) |c| {
                    if (c.text) |t| {
                        try list.writer.writeAll(t);
                    }
                }
                return .{ .thought = list };
            },
            .model_output => |contents| {
                var list = std.Io.Writer.Allocating.init(result_arena_allocator);
                for (contents) |c| {
                    if (c.text) |t| {
                        try list.writer.writeAll(t);
                    }
                }
                return .{ .model_output = list };
            },
            .function_call => |call| return .{
                .tool_call = .{
                    .id = try result_arena_allocator.dupe(u8, call.id),
                    .name = try result_arena_allocator.dupe(u8, call.name),
                    .arguments_json = std.Io.Writer.Allocating.init(result_arena_allocator),
                    .processed_argument_count = 0,
                },
            },
        }
    }

    /// Appends stream delta data to the accumulator.
    ///
    /// `step_self` points to the accumulator instance.
    /// `delta` is the stream delta payload containing new text or argument fragments.
    ///
    /// Returns a `ProviderError.BadResponse` if the delta type does not match the active accumulator variant.
    pub fn appendStep(step_self: *@This(), delta: api.InteractionStepDelta) !void {
        switch (step_self.*) {
            .thought => |*list| {
                if (delta != .thought_summary) return ProviderError.BadResponse;
                if (delta.thought_summary.content.text) |t| {
                    try list.writer.writeAll(t);
                }
            },
            .model_output => |*list| {
                if (delta != .text_delta) return ProviderError.BadResponse;
                if (delta.text_delta.text) |t| {
                    try list.writer.writeAll(t);
                }
            },
            .tool_call => |*tc| {
                if (delta != .arguments_delta) return ProviderError.BadResponse;
                try tc.arguments_json.writer.writeAll(delta.arguments_delta.arguments);
            },
            .empty => {
                return ProviderError.BadResponse;
            },
        }
    }

    /// Processes newly accumulated tool call arguments JSON and parses new complete arguments.
    ///
    /// `acc` is the active `StepAccumulator` (must be the `.tool_call` variant).
    /// `allocator` is used to allocate the returned array of arguments.
    ///
    /// **Memory Alert**:
    /// The caller takes ownership of the returned slice of `llm.types.Argument` and **MUST** free
    /// the slice, the `name` strings, and the `value` strings when done.
    ///
    /// Returns a slice of newly completed `llm.types.Argument` parameters, or `null` if no new arguments
    /// were completed or parsing failed.
    pub fn handleToolCallDelta(
        acc: *StepAccumulator,
        allocator: Allocator,
    ) !?[]const llm.types.Argument {
        const json_parsed_args = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            acc.tool_call.arguments_json.written(),
            .{},
        ) catch return null;
        defer json_parsed_args.deinit();

        if (json_parsed_args.value != .object) {
            return null;
        }

        const function_arguments = api.FunctionArgument.parseFromJsonObject(
            allocator,
            json_parsed_args.value,
        ) catch return null;
        defer allocator.free(function_arguments);

        const new_count = function_arguments.len - acc.tool_call.processed_argument_count;
        if (new_count == 0) {
            return null;
        }

        const arguments = try converter.dupeArguments(allocator, function_arguments[acc.tool_call.processed_argument_count..]);
        errdefer {
            for (arguments) |arg| {
                allocator.free(arg.name);
                switch (arg.value) {
                    .string => |s| allocator.free(s),
                    else => {},
                }
            }
            allocator.free(arguments);
        }

        acc.tool_call.processed_argument_count = function_arguments.len;
        return arguments;
    }

    /// Builds a transient delta payload if new contents or completed arguments are available.
    ///
    /// `self` is the accumulator instance.
    /// `allocator` is used to allocate new arguments for a tool call.
    /// `delta` is the incoming interaction step delta.
    ///
    /// Returns a `TransientDelta` containing the mapped LLM delta if new data was produced,
    /// or `null` if no new delta is ready to be sent (e.g. no new complete tool call arguments).
    pub fn buildDelta(
        self: *@This(),
        allocator: Allocator,
        delta: api.InteractionStepDelta,
    ) !?TransientDelta {
        return switch (self.*) {
            .thought => .{
                .delta = converter.toThoughtDelta(delta.thought_summary),
                .allocator = allocator,
            },
            .model_output => .{
                .delta = converter.toModelOutputDelta(delta.text_delta),
                .allocator = allocator,
            },
            .tool_call => |*tc| {
                if (try self.handleToolCallDelta(allocator)) |args| {
                    return .{
                        .delta = converter.toToolCallDelta(tc.id, tc.name, args),
                        .allocator = allocator,
                    };
                }
                return null;
            },
            .empty => null,
        };
    }
};

/// A wrapper around `llm.types.Delta` that manages the lifetime of allocated delta fields.
/// Holds the allocated fields and the allocator used to create them, so they can be
/// cleanly freed on destruction via `deinit`.
pub const TransientDelta = struct {
    /// The wrapped LLM delta payload.
    delta: llm.types.Delta,
    /// The allocator used to allocate fields in `delta` (such as tool call arguments).
    allocator: Allocator,

    /// Frees the resources associated with the nested `delta` payload using the stored allocator.
    pub fn deinit(self: @This()) void {
        switch (self.delta) {
            .tool_call => |tc| {
                for (tc.arguments) |arg| {
                    self.allocator.free(arg.name);
                    switch (arg.value) {
                        .string => |s| self.allocator.free(s),
                        else => {},
                    }
                }
                self.allocator.free(tc.arguments);
            },
            else => {},
        }
    }
};

test "StepAccumulator mismatch delta and init thought" {
    const allocator = std.testing.allocator;

    var thoughts = [_]api.Content{.{ .type = .text, .text = "thought_1" }};
    const init_step = api.Step{ .thought = &thoughts };
    var acc = try StepAccumulator.init(allocator, init_step);
    defer acc.thought.deinit();
    try std.testing.expect(acc == .thought);
    try std.testing.expectEqualStrings("thought_1", acc.thought.written());

    // Append mismatched delta (should fail)
    const mismatch_delta = api.InteractionStepDelta{
        .text_delta = .{ .type = .text, .text = "text" },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(mismatch_delta));
}

test "StepAccumulator mismatch delta and init model_output" {
    const allocator = std.testing.allocator;

    var outputs = [_]api.Content{.{ .type = .text, .text = "output_1" }};
    const init_step = api.Step{ .model_output = &outputs };
    var acc = try StepAccumulator.init(allocator, init_step);
    defer acc.model_output.deinit();
    try std.testing.expect(acc == .model_output);
    try std.testing.expectEqualStrings("output_1", acc.model_output.written());

    // Append mismatched delta (should fail)
    const mismatch_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "args" },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(mismatch_delta));
}

test "StepAccumulator mismatch delta and init tool_call" {
    const allocator = std.testing.allocator;

    const init_step = api.Step{
        .function_call = .{
            .id = "fc_id",
            .name = "fc_name",
            .arguments = &.{},
        },
    };
    var acc = try StepAccumulator.init(allocator, init_step);
    defer {
        allocator.free(acc.tool_call.id);
        allocator.free(acc.tool_call.name);
        acc.tool_call.arguments_json.deinit();
    }
    try std.testing.expect(acc == .tool_call);
    try std.testing.expectEqualStrings("fc_id", acc.tool_call.id);

    // Append mismatched delta (should fail)
    const mismatch_delta = api.InteractionStepDelta{
        .thought_summary = .{ .content = .{ .type = .text, .text = "think" } },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(mismatch_delta));

    // Test handleToolCallDelta when json is not valid (returns null)
    try std.testing.expect(try acc.handleToolCallDelta(allocator) == null);

    // Test append valid delta and handleToolCallDelta returning null when new_count == 0
    const args_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "{\"arg1\": \"val1\"}" },
    };
    try acc.appendStep(args_delta);
    const args = try acc.handleToolCallDelta(allocator);
    try std.testing.expect(args != null);
    defer {
        for (args.?) |arg| {
            allocator.free(arg.name);
            switch (arg.value) {
                .string => |s| allocator.free(s),
                else => {},
            }
        }
        allocator.free(args.?);
    }

    // Calling handleToolCallDelta again without new changes should return null
    try std.testing.expect(try acc.handleToolCallDelta(allocator) == null);
}

test "StepAccumulator mismatch delta and init empty" {
    var acc: StepAccumulator = .empty;
    const delta = api.InteractionStepDelta{
        .text_delta = .{ .type = .text, .text = "text" },
    };
    try std.testing.expectError(error.BadResponse, acc.appendStep(delta));
}

test "StepAccumulator buildDelta thought" {
    const allocator = std.testing.allocator;

    var thoughts = [_]api.Content{.{ .type = .text, .text = "thought_init" }};
    var acc = try StepAccumulator.init(allocator, .{ .thought = &thoughts });
    defer acc.thought.deinit();

    const delta = api.InteractionStepDelta{
        .thought_summary = .{
            .content = .{ .type = .text, .text = "thought_more" },
        },
    };
    try acc.appendStep(delta);
    const t_delta = (try acc.buildDelta(allocator, delta)).?;
    defer t_delta.deinit();

    try std.testing.expect(t_delta.delta == .thought);
    try std.testing.expectEqualStrings("thought_more", t_delta.delta.thought.text);
}

test "StepAccumulator buildDelta model_output" {
    const allocator = std.testing.allocator;

    var outputs = [_]api.Content{.{ .type = .text, .text = "output_init" }};
    var acc = try StepAccumulator.init(allocator, .{ .model_output = &outputs });
    defer acc.model_output.deinit();

    const delta = api.InteractionStepDelta{
        .text_delta = .{ .type = .text, .text = "output_more" },
    };
    try acc.appendStep(delta);
    const t_delta = (try acc.buildDelta(allocator, delta)).?;
    defer t_delta.deinit();

    try std.testing.expect(t_delta.delta == .model_output);
    try std.testing.expectEqualStrings("output_more", t_delta.delta.model_output.text);
}

test "StepAccumulator buildDelta tool_call" {
    const allocator = std.testing.allocator;

    var acc = try StepAccumulator.init(allocator, .{
        .function_call = .{
            .id = "tc_boston",
            .name = "get_weather",
            .arguments = &.{},
        },
    });
    defer {
        allocator.free(acc.tool_call.id);
        allocator.free(acc.tool_call.name);
        acc.tool_call.arguments_json.deinit();
    }

    const delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "{\"location\": \"Boston\"}" },
    };
    try acc.appendStep(delta);

    const t_delta_opt = try acc.buildDelta(allocator, delta);
    try std.testing.expect(t_delta_opt != null);
    const t_delta = t_delta_opt.?;
    defer t_delta.deinit();

    try std.testing.expect(t_delta.delta == .tool_call);
    try std.testing.expectEqualStrings("tc_boston", t_delta.delta.tool_call.id);
    try std.testing.expectEqualStrings("get_weather", t_delta.delta.tool_call.name);
    try std.testing.expectEqual(1, t_delta.delta.tool_call.arguments.len);
    try std.testing.expectEqualStrings("location", t_delta.delta.tool_call.arguments[0].name);
    try std.testing.expectEqualStrings("Boston", t_delta.delta.tool_call.arguments[0].value.string);
}

test "StepAccumulator handleToolCallDelta invalid JSON structures" {
    const allocator = std.testing.allocator;

    var acc = try StepAccumulator.init(allocator, .{
        .function_call = .{
            .id = "tc_invalid",
            .name = "some_func",
            .arguments = &.{},
        },
    });
    defer {
        allocator.free(acc.tool_call.id);
        allocator.free(acc.tool_call.name);
        acc.tool_call.arguments_json.deinit();
    }

    // 1. JSON is not an object (e.g. an array, which is invalid for tool call arguments)
    const array_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "[1, 2, 3]" },
    };
    try acc.appendStep(array_delta);
    try std.testing.expect(try acc.handleToolCallDelta(allocator) == null);

    // Clear and reset state to test another scenario
    acc.tool_call.arguments_json.clearRetainingCapacity();
    acc.tool_call.processed_argument_count = 0;

    // 2. JSON is an object but contains unsupported nested types (e.g. nested object)
    const nested_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "{\"nested\": {}}" },
    };
    try acc.appendStep(nested_delta);
    try std.testing.expect(try acc.handleToolCallDelta(allocator) == null);

    // Clear and reset state to test null/unsupported arrays
    acc.tool_call.arguments_json.clearRetainingCapacity();
    acc.tool_call.processed_argument_count = 0;

    const nested_arr_delta = api.InteractionStepDelta{
        .arguments_delta = .{ .arguments = "{\"nested_arr\": [1]}" },
    };
    try acc.appendStep(nested_arr_delta);
    try std.testing.expect(try acc.handleToolCallDelta(allocator) == null);
}

test "TransientDelta deinit all argument value types" {
    const allocator = std.testing.allocator;

    // Set up standard arguments of string, integer, float, boolean
    var args = try allocator.alloc(llm.types.Argument, 4);
    errdefer allocator.free(args);

    args[0] = .{ .name = try allocator.dupe(u8, "arg_str"), .value = .{ .string = try allocator.dupe(u8, "val_str") } };
    args[1] = .{ .name = try allocator.dupe(u8, "arg_int"), .value = .{ .integer = 42 } };
    args[2] = .{ .name = try allocator.dupe(u8, "arg_flt"), .value = .{ .float = 3.14 } };
    args[3] = .{ .name = try allocator.dupe(u8, "arg_bool"), .value = .{ .boolean = true } };

    const t_delta = TransientDelta{
        .delta = .{
            .tool_call = .{
                .id = "tc_all_types",
                .name = "func_all_types",
                .arguments = args,
            },
        },
        .allocator = allocator,
    };

    // This should cleanly deallocate the string values, names, and the arguments slice itself.
    t_delta.deinit();
}
