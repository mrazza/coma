const std = @import("std");
const llm = @import("llm");
const api = @import("api.zig");
const converter = @import("converter.zig");

const Allocator = std.mem.Allocator;

/// A Gemini-specific implementation of the `llm.types.ListModelsResult` interface.
/// Represents the result of a request to list Gemini models.
pub const ListModelsResult = struct {
    interface: llm.types.ListModelsResult,
    allocator: Allocator,
    parsed_response: std.json.Parsed(api.ListModelsResponse),

    const vtable = llm.types.ListModelsResult.VTable{
        .deinit = deinit,
    };

    /// Initializes a new ListModelsResult by parsing the raw API response and returns a
    /// pointer to the `llm.types.ListModelsResult` interface.
    pub fn init(allocator: Allocator, parsed_response: std.json.Parsed(api.ListModelsResponse)) !*llm.types.ListModelsResult {
        const self = try allocator.create(ListModelsResult);
        errdefer allocator.destroy(self);
        const models = try converter.toModels(allocator, parsed_response.value.models);
        errdefer allocator.free(models);
        self.* = .{
            .interface = .{
                .models = models,
                .vtable = &vtable,
            },
            .allocator = allocator,
            .parsed_response = parsed_response,
        };

        return &self.interface;
    }

    /// Frees resources associated with the result.
    pub fn deinit(res: *llm.types.ListModelsResult) void {
        const self: *ListModelsResult = @fieldParentPtr("interface", res);
        const allocator = self.allocator;
        allocator.free(self.interface.models);
        self.parsed_response.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

/// A Gemini-specific implementation of the `llm.types.StepResult` interface.
/// Represents the result of an interaction step with the Gemini API.
pub const StepResult = struct {
    interface: llm.types.StepResult,
    model_output: std.ArrayList(llm.types.ModelOutput),
    thoughts: std.ArrayList(llm.types.Thought),
    tool_calls: std.ArrayList(llm.types.ToolCall),

    allocator: std.mem.Allocator,
    parsed_response: std.json.Parsed(api.Interaction),

    const vtable = llm.types.StepResult.VTable{
        .deinit = deinit,
    };

    /// Initializes a new StepResult by parsing the raw interaction response and returns a
    /// pointer to the `llm.types.StepResult` interface.
    pub fn init(allocator: std.mem.Allocator, parsed_response: std.json.Parsed(api.Interaction)) !*llm.types.StepResult {
        var model_output_list: std.ArrayList(llm.types.ModelOutput) = .empty;
        errdefer model_output_list.deinit(allocator);
        var thoughts_list: std.ArrayList(llm.types.Thought) = .empty;
        errdefer thoughts_list.deinit(allocator);
        var tool_calls_list: std.ArrayList(llm.types.ToolCall) = .empty;
        errdefer {
            for (tool_calls_list.items) |call| {
                allocator.free(call.arguments);
            }
            tool_calls_list.deinit(allocator);
        }

        for (parsed_response.value.steps) |step| {
            switch (step) {
                .model_output => |contents| {
                    for (contents) |content| {
                        if (content.text) |text| {
                            try model_output_list.append(allocator, .{
                                .text = text,
                            });
                        }
                    }
                },
                .thought => |thoughts| {
                    for (thoughts) |thought| {
                        if (thought.text) |text| {
                            try thoughts_list.append(allocator, .{
                                .text = text,
                            });
                        }
                    }
                },
                .function_call => |call| {
                    const arguments = try converter.toArguments(allocator, call.arguments);
                    errdefer allocator.free(arguments);
                    try tool_calls_list.append(allocator, .{
                        .id = call.id,
                        .name = call.name,
                        .arguments = arguments,
                    });
                },
            }
        }

        const self = try allocator.create(StepResult);
        errdefer allocator.destroy(self);
        self.* = .{
            .interface = .{
                .model_output = model_output_list.items,
                .thoughts = thoughts_list.items,
                .tool_calls = tool_calls_list.items,
                .vtable = &vtable,
            },
            .model_output = model_output_list,
            .thoughts = thoughts_list,
            .tool_calls = tool_calls_list,
            .allocator = allocator,
            .parsed_response = parsed_response,
        };

        return &self.interface;
    }

    /// Frees resources associated with the result.
    pub fn deinit(res: *llm.types.StepResult) void {
        const self: *StepResult = @fieldParentPtr("interface", res);
        const allocator = self.allocator;
        self.model_output.deinit(allocator);
        self.thoughts.deinit(allocator);
        for (self.tool_calls.items) |call| {
            allocator.free(call.arguments);
        }
        self.tool_calls.deinit(allocator);
        self.parsed_response.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

/// A Gemini-specific implementation of the `llm.types.StepResult` interface for streaming requests.
pub const StreamingStepResult = struct {
    interface: llm.types.StepResult,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    const vtable = llm.types.StepResult.VTable{
        .deinit = deinit,
    };

    /// Initializes a new StreamingStepResult and returns a pointer to the `llm.types.StepResult` interface.
    pub fn init(
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        model_output: []const llm.types.ModelOutput,
        thoughts: []const llm.types.Thought,
        tool_calls: []const llm.types.ToolCall,
    ) !*llm.types.StepResult {
        const self = try allocator.create(StreamingStepResult);
        errdefer allocator.destroy(self);
        self.* = .{
            .interface = .{
                .model_output = model_output,
                .thoughts = thoughts,
                .tool_calls = tool_calls,
                .vtable = &vtable,
            },
            .arena = arena,
            .allocator = allocator,
        };

        return &self.interface;
    }

    /// Frees the resources associated with the StreamingStepResult.
    pub fn deinit(res: *llm.types.StepResult) void {
        const self: *StreamingStepResult = @fieldParentPtr("interface", res);
        const allocator = self.allocator;
        self.arena.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }
};

pub const StepContinuation = struct {
    interface: llm.types.StepContinuation,
    interaction_id: []const u8,
    allocator: std.mem.Allocator,

    const vtable = llm.types.StepContinuation.VTable{
        .deinit = deinit,
    };

    /// Initializes a new StepContinuation and returns a pointer to the `llm.types.StepContinuation` interface.
    ///
    /// This function creates a copy of the interaction_id and stores it in the new StepContinuation.
    /// The StepContinuation will deallocate the interaction_id when it is deinitialized.
    pub fn init(allocator: std.mem.Allocator, interaction_id: []const u8) !*llm.types.StepContinuation {
        const self = try allocator.create(StepContinuation);
        errdefer allocator.destroy(self);
        const dupe_interaction_id = try allocator.dupe(u8, interaction_id);
        errdefer allocator.free(dupe_interaction_id);
        self.* = .{
            .interface = .{
                .vtable = &vtable,
            },
            .interaction_id = dupe_interaction_id,
            .allocator = allocator,
        };

        return &self.interface;
    }

    /// Frees the resources associated with the StepContinuation.
    pub fn deinit(cont: *llm.types.StepContinuation) void {
        const self: *StepContinuation = @fieldParentPtr("interface", cont);
        const allocator = self.allocator;
        allocator.free(self.interaction_id);
        self.* = undefined;
        allocator.destroy(self);
    }
};
