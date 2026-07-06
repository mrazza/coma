const std = @import("std");
const llm = @import("llm");

const Allocator = std.mem.Allocator;
const Argument = llm.types.Argument;
const ToolResult = llm.types.ToolResult;

/// Errors that can occur when executing or calling a tool.
pub const CallError = error{
    /// A required argument was not provided.
    RequiredArgumentMissing,
    /// An argument was provided with a type that does not match the expected type.
    ArgumentTypeMismatch,
    /// An argument was provided with a name that does not match the expected name;
    /// either an unexpected name or the order does not match.
    ArgumentMismatch,
} || std.mem.Allocator.Error;

const Tool = @This();
const ToolExecuteFn = *const fn (allocator: Allocator, args: []const Argument) CallError![]const u8;

descriptor: llm.types.Tool,
execute_fn: ToolExecuteFn,

/// Executes the tool with the given arguments.
///
/// `allocator` is used to allocate memory for the result.
/// `id` is the identifier of the tool call.
/// `args` is the list of arguments to pass to the tool function. All required arguments must be present.
/// Order is not relevant. Unexpected arguments are ignored.
///
/// Returns a `ToolResult` containing the result of the tool call. The caller is responsible
/// for freeing the memory in the result's `result` field.
pub fn execute(self: *const Tool, allocator: Allocator, id: []const u8, args: []const Argument) CallError!ToolResult {
    const result = try self.execute_fn(allocator, args);
    return .{
        .tool_name = self.descriptor.name,
        .id = id,
        .result = result,
    };
}

/// Creates a Tool from a descriptor and a function.
/// Tool calls will delegate to the provided function when called.
///
/// `descriptor` is the tool's descriptor defining the structure of the tool for the LLM.
/// `execute_fn` is the function to be called when the tool is executed.
///
/// The function arguments must match the descriptor parameters and be in the same order.
/// The function also takes an allocator as an argument. The allocator can be in any position
/// provided the other arguments are still in the same order as the parameters in the
/// descriptor.
///
/// The `execute_fn` should return the result of the tool call as a string. The result will
/// be passed to the LLM as the result of the tool call. The caller will own the result
/// and be responsible for freeing it.
pub fn init(comptime descriptor: llm.types.Tool, comptime execute_fn: anytype) Tool {
    return comptime blk: {
        for (descriptor.parameters, 0..) |p1, i| {
            for (descriptor.parameters, 0..) |p2, j| {
                if (i != j and std.mem.eql(u8, p1.name, p2.name)) {
                    @compileError("Duplicate parameter name: " ++ p1.name);
                }
            }
        }

        const res = makeExecuteFn(descriptor, execute_fn);
        break :blk Tool{
            .descriptor = descriptor,
            .execute_fn = switch (res) {
                .ok => |f| f,
                .err => |e| @compileError(e.msg),
            },
        };
    };
}

const ValidationError = error{
    UnsupportedType,
    ExpectedFunctionOrPointer,
    ArgumentTypeMismatch,
    ArgumentCountMismatch,
    ReturnTypeMismatch,
};

const ValidationResult = union(enum) {
    ok: ToolExecuteFn,
    err: struct {
        code: ValidationError,
        msg: []const u8,
    },
};

fn expectedTagForType(comptime T: type) ValidationError!struct { tag: std.meta.Tag(Argument.Value), required: bool } {
    var InputT = T;
    var is_optional = false;
    var tag: std.meta.Tag(Argument.Value) = undefined;

    if (@typeInfo(InputT) == .optional) {
        is_optional = true;
        InputT = @typeInfo(InputT).optional.child;
    }

    if (InputT == i64) {
        tag = .integer;
    } else if (InputT == f64) {
        tag = .float;
    } else if (InputT == []const u8) {
        tag = .string;
    } else if (InputT == bool) {
        tag = .boolean;
    } else {
        return ValidationError.UnsupportedType;
    }
    return .{ .tag = tag, .required = !is_optional };
}

fn ExpectedTypeForParam(comptime param: llm.types.Tool.Param) ValidationError!type {
    const ExpectedType = switch (param.type) {
        .string => []const u8,
        .enumeration => []const u8,
        .integer => i64,
        .float => f64,
        .boolean => bool,
        .array => return error.UnsupportedType,
    };

    if (!param.required) {
        return ?ExpectedType;
    }

    return ExpectedType;
}

fn makeExecuteFn(comptime descriptor: llm.types.Tool, comptime execute_fn: anytype) ValidationResult {
    const FnType = @TypeOf(execute_fn);
    const fn_info = switch (@typeInfo(FnType)) {
        .@"fn" => |info| info,
        .pointer => |ptr_info| switch (@typeInfo(ptr_info.child)) {
            .@"fn" => |info| info,
            else => return .{ .err = .{ .code = ValidationError.ExpectedFunctionOrPointer, .msg = "Expected function or function pointer" } },
        },
        else => return .{ .err = .{ .code = ValidationError.ExpectedFunctionOrPointer, .msg = "Expected function or function pointer" } },
    };

    const return_type = fn_info.return_type.?;
    const payload_type = switch (@typeInfo(return_type)) {
        .error_union => |err_union| err_union.payload,
        else => return_type,
    };
    if (payload_type != []const u8) return .{ .err = .{ .code = ValidationError.ReturnTypeMismatch, .msg = "Function return type must be a string." } };

    const types = comptime blk: {
        var param_idx: usize = 0;
        const descriptor_params = descriptor.parameters;
        var result_types: [fn_info.params.len]type = undefined;
        for (fn_info.params, 0..) |fn_param, i| {
            result_types[i] = fn_param.type.?;

            if (fn_param.type.? != Allocator) {
                if (param_idx >= descriptor_params.len) {
                    return .{ .err = .{ .code = ValidationError.ArgumentCountMismatch, .msg = "More arguments in function than descriptor." } };
                }

                const ExpectedType = ExpectedTypeForParam(descriptor_params[param_idx]) catch |val_err| return .{ .err = .{ .code = val_err, .msg = "Failed to resolve type from descriptor (tool: " ++ descriptor.name ++ ", param: " ++ descriptor_params[param_idx].name ++ ")" } };
                if (ExpectedType != fn_param.type.?) {
                    return .{ .err = .{
                        .code = ValidationError.ArgumentTypeMismatch,
                        .msg = "Argument type mismatch in tool " ++ descriptor.name ++ " for " ++
                            "argument " ++ descriptor_params[param_idx].name ++ ": " ++
                            "expected " ++ @typeName(ExpectedType) ++ " but got " ++ @typeName(fn_param.type.?),
                    } };
                }
                param_idx += 1;
            }
        }

        if (param_idx < descriptor_params.len) {
            return .{ .err = .{ .code = ValidationError.ArgumentCountMismatch, .msg = "Fewer arguments in function than descriptor." } };
        }
        break :blk result_types;
    };

    const TupleType = @Tuple(&types);
    return .{
        .ok = struct {
            pub fn call(allocator: Allocator, input_args: []const Argument) CallError![]const u8 {
                var argument_map: std.StringHashMap(*const Argument) = .init(allocator);
                defer argument_map.deinit();
                for (input_args) |*arg| try argument_map.put(arg.name, arg);

                var args: TupleType = undefined;
                var descriptor_idx: usize = 0;
                inline for (0..fn_info.params.len) |func_idx| {
                    const T = types[func_idx];
                    if (T == Allocator) {
                        args[func_idx] = allocator;
                    } else {
                        const curr_descriptor = descriptor.parameters[descriptor_idx];
                        descriptor_idx += 1;
                        const opt_argument = argument_map.get(curr_descriptor.name);
                        if (opt_argument) |argument| {
                            const expected_tag = comptime try expectedTagForType(T);
                            if (argument.value != expected_tag.tag) {
                                std.debug.print("expected {}, actual {} [descriptor {s}]\n", .{ expected_tag.tag, argument.value, curr_descriptor.name });
                                return CallError.ArgumentTypeMismatch;
                            }
                            args[func_idx] = switch (expected_tag.tag) {
                                .integer => @intCast(argument.value.integer),
                                .float => argument.value.float,
                                .string => argument.value.string,
                                .boolean => argument.value.boolean,
                            };
                        } else {
                            if (curr_descriptor.required) return CallError.RequiredArgumentMissing;
                            if (@typeInfo(@TypeOf(args[func_idx])) != .optional) unreachable;
                            args[func_idx] = null;
                        }
                    }
                }

                return @call(.auto, execute_fn, args);
            }
        }.call,
    };
}

test init {
    const allocator = std.testing.allocator;

    const tool_descriptor: llm.types.Tool = .{
        .name = "example_function",
        .description = "An example function that takes two arguments",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "The first argument to the function",
                .type = .integer,
                .required = true,
            },
            .{
                .name = "arg2",
                .description = "The second argument to the function",
                .type = .string,
                .required = true,
            },
        },
    };
    const tool_impl = struct {
        pub fn example_function(_: Allocator, arg1: i64, arg2: []const u8) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "{d}{s}", .{ arg1, arg2 });
        }
    };
    const tool = comptime init(tool_descriptor, tool_impl.example_function);

    const args = [_]Argument{
        .{ .name = "arg1", .value = .{ .integer = 12 } },
        .{ .name = "arg2", .value = .{ .string = "hello" } },
    };

    const result = try tool.execute(allocator, "123", &args);
    defer allocator.free(result.result);

    try std.testing.expectEqualStrings("example_function", result.tool_name);
    try std.testing.expectEqualStrings("123", result.id);
    try std.testing.expectEqualStrings("12hello", result.result);
}

test "makeExecuteFn - ExpectedFunctionOrPointer" {
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{},
    };
    const res = comptime makeExecuteFn(desc, 42);
    try std.testing.expectEqual(ValidationError.ExpectedFunctionOrPointer, res.err.code);
}

test "makeExecuteFn - ArgumentTypeMismatch" {
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .integer,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(arg1: []const u8) ![]const u8 {
            return arg1;
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expectEqual(ValidationError.ArgumentTypeMismatch, res.err.code);
    try std.testing.expectEqualStrings("Argument type mismatch in tool test_tool for argument arg1: expected i64 but got []const u8", res.err.msg);
}

test "makeExecuteFn - ArgumentCountMismatch (too many arguments)" {
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{},
    };
    const Impl = struct {
        pub fn run(arg1: i64) ![]const u8 {
            _ = arg1;
            return "";
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expectEqual(ValidationError.ArgumentCountMismatch, res.err.code);
    try std.testing.expectEqualStrings("More arguments in function than descriptor.", res.err.msg);
}

test "makeExecuteFn - ArgumentCountMismatch (too few arguments)" {
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .integer,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run() ![]const u8 {
            return "";
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expectEqual(ValidationError.ArgumentCountMismatch, res.err.code);
    try std.testing.expectEqualStrings("Fewer arguments in function than descriptor.", res.err.msg);
}

test "makeExecuteFn - ParamTypeArrayNotSupported" {
    const array_inner_type: llm.types.Tool.Param.Type = .integer;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .{ .array = &array_inner_type },
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(arg1: []const u8) ![]const u8 {
            return arg1;
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expectEqual(ValidationError.UnsupportedType, res.err.code);
    try std.testing.expectEqualStrings("Failed to resolve type from descriptor (tool: test_tool, param: arg1)", res.err.msg);
}

test "makeExecuteFn - ReturnTypeMismatch" {
    const array_inner_type: llm.types.Tool.Param.Type = .integer;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .{ .array = &array_inner_type },
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(_: []const u8) !i32 {
            return 10;
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expectEqual(ValidationError.ReturnTypeMismatch, res.err.code);
    try std.testing.expectEqualStrings("Function return type must be a string.", res.err.msg);
}

test "makeExecuteFn - argument optionals OK" {
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = false,
            },
        },
    };
    const Impl = struct {
        pub fn run(optional: ?[]const u8) ![]const u8 {
            if (optional) |val| return val;
            return "";
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expect(res == .ok);
}

test "makeExecuteFn - argument optional in descriptor, required in fn" {
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = false,
            },
        },
    };
    const Impl = struct {
        pub fn run(required: []const u8) ![]const u8 {
            return required;
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expectEqual(ValidationError.ArgumentTypeMismatch, res.err.code);
    try std.testing.expectEqualStrings("Argument type mismatch in tool test_tool for argument arg1: expected ?[]const u8 but got []const u8", res.err.msg);
}

test "makeExecuteFn - argument required in descriptor, optional in fn" {
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(optional: ?[]const u8) ![]const u8 {
            if (optional) |val| return val;
            return "";
        }
    };
    const res = comptime makeExecuteFn(desc, Impl.run);
    try std.testing.expectEqual(ValidationError.ArgumentTypeMismatch, res.err.code);
    try std.testing.expectEqualStrings("Argument type mismatch in tool test_tool for argument arg1: expected []const u8 but got ?[]const u8", res.err.msg);
}

test execute {
    const testing_allocator = std.testing.allocator;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(allocator: Allocator, arg1: []const u8) ![]const u8 {
            return try allocator.dupe(u8, arg1);
        }
    };
    const tool = Tool.init(desc, Impl.run);
    const args: []const Argument = &.{
        .{
            .name = "arg1",
            .value = .{ .string = "value" },
        },
    };
    const result = try tool.execute(testing_allocator, "id", args);
    defer testing_allocator.free(result.result);

    try std.testing.expectEqualStrings("test_tool", result.tool_name);
    try std.testing.expectEqualStrings("id", result.id);
    try std.testing.expectEqualStrings("value", result.result);
}

test "execute - unknown argument" {
    const testing_allocator = std.testing.allocator;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(allocator: Allocator, arg1: []const u8) ![]const u8 {
            return try allocator.dupe(u8, arg1);
        }
    };
    const tool = Tool.init(desc, Impl.run);
    const args: []const Argument = &.{
        .{
            .name = "unknown",
            .value = .{ .string = "value" },
        },
    };
    try std.testing.expectError(CallError.RequiredArgumentMissing, tool.execute(testing_allocator, "id", args));
}

test "execute - extra argument ignored" {
    const testing_allocator = std.testing.allocator;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(allocator: Allocator, arg1: []const u8) ![]const u8 {
            return try allocator.dupe(u8, arg1);
        }
    };
    const tool = Tool.init(desc, Impl.run);
    const args: []const Argument = &.{
        .{
            .name = "arg1",
            .value = .{ .string = "value1" },
        },
        .{
            .name = "arg2",
            .value = .{ .string = "value2" },
        },
    };
    const result = try tool.execute(testing_allocator, "id", args);
    defer testing_allocator.free(result.result);
    try std.testing.expectEqualStrings("value1", result.result);
}

test "execute - missing required argument" {
    const testing_allocator = std.testing.allocator;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(allocator: Allocator, arg1: []const u8) ![]const u8 {
            return try allocator.dupe(u8, arg1);
        }
    };
    const tool = Tool.init(desc, Impl.run);
    const args: []const Argument = &.{};
    try std.testing.expectError(CallError.RequiredArgumentMissing, tool.execute(testing_allocator, "id", args));
}

test "execute - missing optional argument" {
    const testing_allocator = std.testing.allocator;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = false,
            },
        },
    };
    const Impl = struct {
        pub fn run(allocator: Allocator, arg1: ?[]const u8) ![]const u8 {
            if (arg1 != null) return allocator.dupe(u8, arg1.?);
            return allocator.dupe(u8, "default");
        }
    };
    const tool = Tool.init(desc, Impl.run);
    const args: []const Argument = &.{};
    const result = try tool.execute(testing_allocator, "id", args);
    defer testing_allocator.free(result.result);

    try std.testing.expectEqualStrings("test_tool", result.tool_name);
    try std.testing.expectEqualStrings("id", result.id);
    try std.testing.expectEqualStrings("default", result.result);
}

test "execute - argument type mismatch" {
    const testing_allocator = std.testing.allocator;
    const desc: llm.types.Tool = .{
        .name = "test_tool",
        .description = "desc",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "desc",
                .type = .string,
                .required = true,
            },
        },
    };
    const Impl = struct {
        pub fn run(allocator: Allocator, arg1: []const u8) ![]const u8 {
            return try allocator.dupe(u8, arg1);
        }
    };
    const tool = Tool.init(desc, Impl.run);
    const args: []const Argument = &.{
        .{
            .name = "arg1",
            .value = .{ .integer = 10 },
        },
    };
    try std.testing.expectError(CallError.ArgumentTypeMismatch, tool.execute(testing_allocator, "id", args));
}

test "execute - no Allocator parameter" {
    const allocator = std.testing.allocator;

    const tool_descriptor: llm.types.Tool = .{
        .name = "no_allocator_func",
        .description = "Takes two arguments, no allocator in parameter signature",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "The first argument",
                .type = .string,
                .required = true,
            },
        },
    };
    const tool_impl = struct {
        pub fn no_allocator_func(arg1: []const u8) ![]const u8 {
            return allocator.dupe(u8, arg1);
        }
    };
    const tool = comptime init(tool_descriptor, tool_impl.no_allocator_func);

    const args = [_]Argument{
        .{ .name = "arg1", .value = .{ .string = "hello" } },
    };

    const result = try tool.execute(allocator, "abc", &args);
    defer allocator.free(result.result);

    try std.testing.expectEqualStrings("no_allocator_func", result.tool_name);
    try std.testing.expectEqualStrings("abc", result.id);
    try std.testing.expectEqualStrings("hello", result.result);
}

test "execute - Allocator as middle/last parameter" {
    const allocator = std.testing.allocator;

    const tool_descriptor: llm.types.Tool = .{
        .name = "middle_last_allocator_func",
        .description = "Takes three arguments, allocator is at the middle/end",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "The first argument",
                .type = .integer,
                .required = true,
            },
            .{
                .name = "arg2",
                .description = "The second argument",
                .type = .string,
                .required = true,
            },
        },
    };
    const tool_impl = struct {
        pub fn middle_last_allocator_func(arg1: i64, tool_allocator: Allocator, arg2: []const u8) ![]const u8 {
            return try std.fmt.allocPrint(tool_allocator, "middle-{d}-{s}", .{ arg1, arg2 });
        }
    };
    const tool = comptime init(tool_descriptor, tool_impl.middle_last_allocator_func);

    const args = [_]Argument{
        .{ .name = "arg1", .value = .{ .integer = 99 } },
        .{ .name = "arg2", .value = .{ .string = "test" } },
    };

    const result = try tool.execute(allocator, "xyz", &args);
    defer allocator.free(result.result);

    try std.testing.expectEqualStrings("middle_last_allocator_func", result.tool_name);
    try std.testing.expectEqualStrings("xyz", result.id);
    try std.testing.expectEqualStrings("middle-99-test", result.result);
}

test "execute - multiple Allocator parameters" {
    const allocator = std.testing.allocator;

    const tool_descriptor: llm.types.Tool = .{
        .name = "multi_allocator_func",
        .description = "Takes multiple allocator arguments",
        .parameters = &.{
            .{
                .name = "arg1",
                .description = "The first argument",
                .type = .integer,
                .required = true,
            },
        },
    };
    const tool_impl = struct {
        pub fn multi_allocator_func(alloc1: Allocator, arg1: i64, alloc2: Allocator) ![]const u8 {
            if (alloc1.ptr != alloc2.ptr) return error.OutOfMemory;
            return try std.fmt.allocPrint(alloc1, "multi-{d}", .{arg1});
        }
    };
    const tool = comptime init(tool_descriptor, tool_impl.multi_allocator_func);

    const args = [_]Argument{
        .{ .name = "arg1", .value = .{ .integer = 7 } },
    };

    const result = try tool.execute(allocator, "multi", &args);
    defer allocator.free(result.result);

    try std.testing.expectEqualStrings("multi_allocator_func", result.tool_name);
    try std.testing.expectEqualStrings("multi", result.id);
    try std.testing.expectEqualStrings("multi-7", result.result);
}
