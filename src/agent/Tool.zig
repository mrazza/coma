const std = @import("std");
const llm = @import("llm");

const Allocator = std.mem.Allocator;

const Tool = @This();

descriptor: llm.types.Tool,
