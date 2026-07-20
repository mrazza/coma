const std = @import("std");
const llm = @import("llm");
const Tool = @import("Tool.zig");

const Allocator = std.mem.Allocator;

/// Configuration for initializing a Session.
pub const SessionConfig = struct {
    /// The LLM model to be used by the Session.
    model: llm.types.Model,
    /// A list of executable tools available for the Session to use.
    tools: []const Tool = &.{},
};

/// Represents the input to start a single execution turn in a Session.
pub const Turn = struct {
    /// The input text prompt or message for this turn.
    prompt: []const u8,
};

/// The result of an intermediate step executed during a turn.
///
/// An intermediate step is either a response from the model that required further
/// processing (e.g. a tool call) or the result of executing a tool call requested by
/// the model.
pub const IntermediateStepResult = union(enum) {
    /// The result of an LLM generation step.
    step_result: llm.types.StepResult,
    /// The result of executing a tool call requested by the model.
    tool_result: llm.types.ToolResult,

    /// Frees the resources associated with the intermediate step result.
    pub fn deinit(self: *IntermediateStepResult) void {
        switch (self.*) {
            .step_result => |*step_result| step_result.deinit(),
            .tool_result => |*tool_result| tool_result.deinit(),
        }
        self.* = undefined;
    }
};

/// The final result of a turn, including all intermediate steps taken and the final LLM step result.
/// Memory must be freed using the `deinit` method.
pub const TurnResult = struct {
    /// The allocator used to allocate resources in this TurnResult.
    allocator: Allocator,
    /// The history of intermediate steps (model thoughts, tool calls, and results) executed during the turn.
    intermediate_steps: []IntermediateStepResult,
    /// The final step result that completed the turn (typically the model's final text output).
    final_step: llm.types.StepResult,

    /// Deinitializes the TurnResult and frees all associated memory.
    ///
    /// This method must be called exactly once for each TurnResult when it is no longer needed.
    /// All `intermediate_steps` and `final_step` will be deinitialized in order to free their
    /// allocated resources.
    pub fn deinit(self: *TurnResult) void {
        for (self.intermediate_steps) |*step| {
            step.deinit();
        }
        self.final_step.deinit();
        self.allocator.free(self.intermediate_steps);
        self.* = undefined;
    }
};

/// The data chunk representing incremental updates in a streaming Agent turn.
pub const StreamingChunk = union(enum) {
    /// An incremental update chunk from the streaming LLM response.
    model_chunk: llm.types.StreamingChunk,
    /// The outcome/result of executing a tool.
    tool_result: llm.types.ToolResult,
};

/// Callback function signature for processing streaming response chunks.
pub const StreamingCallback = *const fn (context: ?*anyopaque, chunk: StreamingChunk) void;
