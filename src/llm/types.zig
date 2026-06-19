const std = @import("std");

pub const SessionConfig = struct {
    model: Model,
    tools: []const Tool,
};

pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
};

pub const Tool = struct {
    pub const Param = struct {
        pub const Type = enum {
            string,
        };

        name: []const u8,
        description: []const u8,
        type: Type,
        required: bool = false,
    };

    name: []const u8,
    description: []const u8,
    parameters: []const Param,
};

pub const ListModelsResult = struct {
    models: []const Model,

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn deinit(self: *ListModelsResult) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};

pub const StepResult = struct {
    model_output: []const ModelOutput,
    thoughts: []const Thought,
    tool_calls: []const ToolCall,

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn deinit(self: *StepResult) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }

    pub const ModelOutput = union(enum) {
        text: []const u8,
    };

    pub const Thought = struct {
        text: []const u8,
    };

    pub const ToolCall = struct {
        pub const Argument = struct {
            name: []const u8,
            value: []const u8,
        };

        id: []const u8,
        name: []const u8,
        arguments: []Argument,
    };
};

pub const Step = union(enum) {
    prompt: []const u8,
    tool_result: ToolResult,
};

pub const ToolResult = struct {
    tool_name: []const u8,
    id: []const u8,
    result: []const u8,
};
