const std = @import("std");
const llm = @import("llm");

const Allocator = std.mem.Allocator;

pub const Turn = struct {
    prompt: []const u8,
};

pub const IntermediateStepResult = union(enum) {
    step_result: llm.types.StepResult,
    tool_result: llm.types.ToolResult,

    pub fn deinit(self: *IntermediateStepResult) void {
        switch (self.*) {
            .step_result => |*step_result| step_result.deinit(),
            .tool_result => |*tool_result| tool_result.deinit(),
        }
        self.* = undefined;
    }
};

pub const TurnResult = struct {
    allocator: Allocator,
    intermediate_steps: []IntermediateStepResult,
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
