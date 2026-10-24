//! Agent tool for executing shell commands.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../root.zig");
const SessionState = @import("../SessionState.zig");

pub const MAX_STREAM_LINES: usize = 2000;
pub const MAX_STREAM_BYTES: usize = 64 * 1024; // 64 KiB display limit per stream
pub const MAX_PROCESS_STREAM_BYTES: usize = 10 * 1024 * 1024; // 10 MiB limit per process stream
pub const DEFAULT_TIMEOUT_SECS: i64 = 30;

/// Structured result of a shell execution.
const ShellResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: ?u32 = null,
    error_message: ?[]const u8 = null,
};

/// Constructs an argv builder function for POSIX shells (`<shell_binary> -c <command>`).
pub fn makePosixArgv(comptime shell_binary: []const u8) fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]const []const u8 {
    return struct {
        fn make(allocator: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]const []const u8 {
            const argv = try allocator.alloc([]const u8, 3);
            argv[0] = shell_binary;
            argv[1] = "-c";
            argv[2] = command;
            return argv;
        }
    }.make;
}

/// Constructs an argv builder function for Windows Command Prompt (`cmd.exe /c <command>`).
pub fn makeCmdArgv(allocator: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 3);
    argv[0] = "cmd.exe";
    argv[1] = "/c";
    argv[2] = command;
    return argv;
}

/// Constructs an argv builder function for PowerShell (`<pwsh_binary> -NoProfile -NonInteractive -Command <command>`).
pub fn makePowershellArgv(comptime pwsh_binary: []const u8) fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]const []const u8 {
    return struct {
        fn make(allocator: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]const []const u8 {
            const argv = try allocator.alloc([]const u8, 5);
            argv[0] = pwsh_binary;
            argv[1] = "-NoProfile";
            argv[2] = "-NonInteractive";
            argv[3] = "-Command";
            argv[4] = command;
            return argv;
        }
    }.make;
}

/// Creates an agent `Tool` configured for the specified shell name and argv builder function.
pub fn makeTool(
    comptime shell_name: []const u8,
    comptime make_argv_fn: fn (allocator: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error![]const []const u8,
) agent.Tool {
    const description = std.fmt.comptimePrint(
        \\Execute a shell command in the current dir.
        \\Commands run under `{s}` - write command strings in that shell's syntax.
        \\Execution is non-interactive; stdin is ignored.
        \\Returns an object with stdout and stderr as separate fields.
        \\The output of each stream is limited to up to {d} lines ({d} KiB); longer outputs will be saved to a temporary file.
    , .{ shell_name, MAX_STREAM_LINES, MAX_STREAM_BYTES / 1024 });

    const S = struct {
        fn execute(allocator: std.mem.Allocator, io: std.Io, command: []const u8, timeout_secs: ?i64) std.mem.Allocator.Error![]const u8 {
            const argv = try make_argv_fn(allocator, command);
            defer allocator.free(argv);

            const effective_timeout_secs: i64 = if (timeout_secs) |t| (if (t > 0) t else DEFAULT_TIMEOUT_SECS) else DEFAULT_TIMEOUT_SECS;
            const dur: std.Io.Duration = .fromSeconds(effective_timeout_secs);
            const timeout: std.Io.Timeout = (std.Io.Timeout{ .duration = .{ .raw = dur, .clock = .awake } }).toDeadline(io);

            const run_res = std.process.run(allocator, io, .{
                .argv = argv,
                .timeout = timeout,
                .stdout_limit = std.Io.Limit.limited(MAX_PROCESS_STREAM_BYTES),
                .stderr_limit = std.Io.Limit.limited(MAX_PROCESS_STREAM_BYTES),
            });

            if (run_res) |res| {
                defer {
                    allocator.free(res.stdout);
                    allocator.free(res.stderr);
                }

                const processed_stdout = try processStream(allocator, io, "stdout", res.stdout);
                defer allocator.free(processed_stdout);

                const processed_stderr = try processStream(allocator, io, "stderr", res.stderr);
                defer allocator.free(processed_stderr);

                const exit_code: ?u32 = switch (res.term) {
                    .exited => |code| code,
                    else => null,
                };

                const term_error_msg: ?[]const u8 = switch (res.term) {
                    .exited => null,
                    .signal => |sig| try std.fmt.allocPrint(allocator, "Process terminated by signal {d}", .{@intFromEnum(sig)}),
                    .stopped => |sig| try std.fmt.allocPrint(allocator, "Process stopped by signal {d}", .{sig}),
                    .unknown => |val| try std.fmt.allocPrint(allocator, "Process terminated abnormally (status {d})", .{val}),
                };
                defer if (term_error_msg) |msg| allocator.free(msg);

                const shell_res: ShellResult = .{
                    .stdout = processed_stdout,
                    .stderr = processed_stderr,
                    .exit_code = exit_code,
                    .error_message = term_error_msg,
                };

                return try formatJson(allocator, shell_res);
            } else |err| {
                const error_msg = switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Timeout => try std.fmt.allocPrint(allocator, "Command timed out after {d} seconds", .{effective_timeout_secs}),
                    error.StreamTooLong => try std.fmt.allocPrint(allocator, "Command output exceeded maximum process stream limit ({d} bytes)", .{MAX_PROCESS_STREAM_BYTES}),
                    else => try std.fmt.allocPrint(allocator, "Failed to execute command: {}", .{err}),
                };
                defer allocator.free(error_msg);

                const shell_res: ShellResult = .{
                    .stdout = "",
                    .stderr = "",
                    .exit_code = null,
                    .error_message = error_msg,
                };

                return try formatJson(allocator, shell_res);
            }
        }
    };

    return agent.Tool.fromFn(.{
        .name = "shell",
        .description = description,
        .parameters = &.{
            .{
                .name = "command",
                .description = "The command to execute.",
                .type = .string,
                .required = true,
            },
            .{
                .name = "timeout_secs",
                .description = std.fmt.comptimePrint(
                    "The number of seconds to wait for the command to complete before terminating. If omitted, defaults to {d} seconds.",
                    .{DEFAULT_TIMEOUT_SECS},
                ),
                .type = .integer,
            },
        },
    }, S.execute);
}

/// Pre-configured shell tools.
pub const sh = makeTool("sh", makePosixArgv("sh"));
pub const bash = makeTool("bash", makePosixArgv("bash"));
pub const zsh = makeTool("zsh", makePosixArgv("zsh"));
pub const cmd = makeTool("cmd", makeCmdArgv);
pub const powershell = makeTool("powershell", makePowershellArgv("powershell.exe"));
pub const pwsh = makeTool("pwsh", makePowershellArgv("pwsh"));

/// Default shell tool based on the host operating system.
pub const default = if (builtin.os.tag == .windows) cmd else sh;

/// Replaces invalid UTF-8 byte sequences with Unicode replacement character U+FFFD.
fn sanitizeUtf8(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(input)) {
        return try allocator.dupe(u8, input);
    }

    var out: std.ArrayList(u8) = .initCapacity(allocator, input.len);
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
            continue;
        };

        if (i + cp_len > input.len) {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            break;
        }

        if (std.unicode.utf8Decode(input[i .. i + cp_len])) |_| {
            try out.appendSlice(allocator, input[i .. i + cp_len]);
            i += cp_len;
        } else |_| {
            try out.appendSlice(allocator, "\xEF\xBF\xBD");
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Creates a temporary file with the given prefix and writes the provided content into it.
/// Returns the allocated path of the created temporary file, which the caller is responsible for freeing.
fn writeTempFile(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8, content: []const u8) ![]const u8 {
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const rand_val = std.mem.readInt(u64, &rand_bytes, .little);
    const temp_dir = if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
    const temp_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}_{x}.txt", .{ temp_dir, prefix, rand_val });
    errdefer allocator.free(temp_path);

    const file = try std.Io.Dir.createFileAbsolute(io, temp_path, .{});
    defer file.close(io);

    var offset: u64 = 0;
    while (offset < content.len) {
        const written = try file.writePositional(io, &.{content[offset..]}, offset);
        if (written == 0) return error.WriteFailed;
        offset += written;
    }

    return temp_path;
}

const CutoffReason = enum { lines, bytes };
const CutoffResult = struct {
    cutoff: usize,
    reason: CutoffReason,
};

fn processStream(allocator: std.mem.Allocator, io: std.Io, stream_name: []const u8, content: []const u8) std.mem.Allocator.Error![]const u8 {
    const maybe_cutoff = findCutoff(content, MAX_STREAM_LINES, MAX_STREAM_BYTES);
    if (maybe_cutoff == null) {
        return try sanitizeUtf8(allocator, content);
    }

    const cutoff_res = maybe_cutoff.?;
    const truncated_raw = content[0..cutoff_res.cutoff];
    const sanitized_truncated = try sanitizeUtf8(allocator, truncated_raw);
    defer allocator.free(sanitized_truncated);

    const prefix = if (std.mem.eql(u8, stream_name, "stdout")) "coma_shell_stdout" else "coma_shell_stderr";
    const temp_file_res = writeTempFile(allocator, io, prefix, content);

    const reason_str = switch (cutoff_res.reason) {
        .lines => try std.fmt.allocPrint(allocator, "{d} lines", .{MAX_STREAM_LINES}),
        .bytes => try std.fmt.allocPrint(allocator, "{d} KiB", .{MAX_STREAM_BYTES / 1024}),
    };
    defer allocator.free(reason_str);

    if (temp_file_res) |temp_path| {
        defer allocator.free(temp_path);
        return try std.fmt.allocPrint(
            allocator,
            "{s}\n\n[Output truncated to {s}. Full output saved to {s}]",
            .{ sanitized_truncated, reason_str, temp_path },
        );
    } else |err| {
        return try std.fmt.allocPrint(
            allocator,
            "{s}\n\n[Output truncated to {s}. Failed to save overflow file: {}]",
            .{ sanitized_truncated, reason_str, err },
        );
    }
}

fn findCutoff(content: []const u8, max_lines: usize, max_bytes: usize) ?CutoffResult {
    var line_count: usize = 0;
    for (content, 0..) |byte, idx| {
        if (idx >= max_bytes) {
            var cut = max_bytes;
            while (cut > 0 and cut < content.len and (content[cut] & 0xC0) == 0x80) : (cut -= 1) {}
            return .{ .cutoff = cut, .reason = .bytes };
        }
        if (byte == '\n') {
            line_count += 1;
            if (line_count >= max_lines and idx + 1 < content.len) {
                return .{ .cutoff = idx + 1, .reason = .lines };
            }
        }
    }
    if (content.len > max_bytes) {
        var cut = max_bytes;
        while (cut > 0 and cut < content.len and (content[cut] & 0xC0) == 0x80) : (cut -= 1) {}
        return .{ .cutoff = cut, .reason = .bytes };
    }
    return null;
}

fn formatJson(allocator: std.mem.Allocator, result: ShellResult) std.mem.Allocator.Error![]const u8 {
    var write_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer write_buffer.deinit();
    var stringifier = std.json.Stringify{
        .writer = &write_buffer.writer,
        .options = .{},
    };
    // std.json.Stringify writes to std.Io.Writer.Allocating, which only fails if memory allocation fails.
    stringifier.write(result) catch return error.OutOfMemory;
    return try write_buffer.toOwnedSlice();
}

const llm = @import("llm");

test "Shell tool descriptor metadata" {
    const tool = default;
    try std.testing.expectEqualStrings("shell", tool.descriptor.name);
    try std.testing.expect(std.mem.indexOf(u8, tool.descriptor.description, "2000 lines (64 KiB)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool.descriptor.description, "non-interactive") != null);
    try std.testing.expectEqual(2, tool.descriptor.parameters.len);
    try std.testing.expectEqualStrings("command", tool.descriptor.parameters[0].name);
    try std.testing.expectEqual(llm.types.Tool.Param.Type.string, tool.descriptor.parameters[0].type);
    try std.testing.expect(tool.descriptor.parameters[0].required);
    try std.testing.expectEqualStrings("timeout_secs", tool.descriptor.parameters[1].name);
    try std.testing.expectEqual(llm.types.Tool.Param.Type.integer, tool.descriptor.parameters[1].type);
    try std.testing.expect(!tool.descriptor.parameters[1].required);
    try std.testing.expect(std.mem.indexOf(u8, tool.descriptor.parameters[1].description, "defaults to 30 seconds") != null);
}

test "Shell tool stdout execution" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = sh;
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "echo hello coma" },
        },
    };

    var result = try tool.execute(testing_allocator, io, &session_state, "call_1", args);
    defer result.deinit();

    try std.testing.expectEqualStrings("shell", result.tool_name);
    try std.testing.expectEqualStrings("call_1", result.id);

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello coma\n", parsed.value.stdout);
    try std.testing.expectEqualStrings("", parsed.value.stderr);
    try std.testing.expectEqual(0, parsed.value.exit_code.?);
    try std.testing.expectEqual(null, parsed.value.error_message);
}

test "Shell tool stderr and non-zero exit code" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = sh;
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "echo error output >&2; exit 42" },
        },
    };

    var result = try tool.execute(testing_allocator, io, &session_state, "call_2", args);
    defer result.deinit();

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("", parsed.value.stdout);
    try std.testing.expectEqualStrings("error output\n", parsed.value.stderr);
    try std.testing.expectEqual(42, parsed.value.exit_code.?);
    try std.testing.expectEqual(null, parsed.value.error_message);
}

test "Shell tool timeout triggered" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = sh;
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "sleep 2" },
        },
        .{
            .name = "timeout_secs",
            .value = .{ .integer = 1 },
        },
    };

    var result = try tool.execute(testing_allocator, io, &session_state, "call_3", args);
    defer result.deinit();

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.error_message != null);
    try std.testing.expectEqualStrings("Command timed out after 1 seconds", parsed.value.error_message.?);
    try std.testing.expectEqual(null, parsed.value.exit_code);
}

test "Shell tool line cutoff and temp file overflow" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = sh;
    // Generate 2005 lines of output
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "i=1; while [ $i -le 2005 ]; do echo line $i; i=$((i+1)); done" },
        },
    };

    var result = try tool.execute(testing_allocator, io, &session_state, "call_4", args);
    defer result.deinit();

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(0, parsed.value.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.stdout, "[Output truncated to 2000 lines. Full output saved to ") != null);

    // Extract the temp file path from stdout notice
    const prefix = "Full output saved to ";
    if (std.mem.indexOf(u8, parsed.value.stdout, prefix)) |idx| {
        const start = idx + prefix.len;
        if (std.mem.indexOf(u8, parsed.value.stdout[start..], "]")) |end_rel| {
            const temp_path = parsed.value.stdout[start .. start + end_rel];
            // Verify file exists and clean it up
            std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        }
    }
}

test "Shell tool missing required argument" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = default;
    const empty_args: []const llm.types.Argument = &.{};
    try std.testing.expectError(
        agent.Tool.CallError.RequiredArgumentMissing,
        tool.execute(testing_allocator, io, &session_state, "call_err", empty_args),
    );
}

test "Argv builders" {
    const allocator = std.testing.allocator;

    const posix_builder = makePosixArgv("custom_sh");
    const posix_argv = try posix_builder(allocator, "echo 1");
    defer allocator.free(posix_argv);
    try std.testing.expectEqual(3, posix_argv.len);
    try std.testing.expectEqualStrings("custom_sh", posix_argv[0]);
    try std.testing.expectEqualStrings("-c", posix_argv[1]);
    try std.testing.expectEqualStrings("echo 1", posix_argv[2]);

    const cmd_argv = try makeCmdArgv(allocator, "dir");
    defer allocator.free(cmd_argv);
    try std.testing.expectEqual(3, cmd_argv.len);
    try std.testing.expectEqualStrings("cmd.exe", cmd_argv[0]);
    try std.testing.expectEqualStrings("/c", cmd_argv[1]);
    try std.testing.expectEqualStrings("dir", cmd_argv[2]);

    const pwsh_builder = makePowershellArgv("pwsh");
    const pwsh_argv = try pwsh_builder(allocator, "Get-Process");
    defer allocator.free(pwsh_argv);
    try std.testing.expectEqual(5, pwsh_argv.len);
    try std.testing.expectEqualStrings("pwsh", pwsh_argv[0]);
    try std.testing.expectEqualStrings("-NoProfile", pwsh_argv[1]);
    try std.testing.expectEqualStrings("-NonInteractive", pwsh_argv[2]);
    try std.testing.expectEqualStrings("-Command", pwsh_argv[3]);
    try std.testing.expectEqualStrings("Get-Process", pwsh_argv[4]);
}

test "Custom makeTool" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const custom_tool = makeTool("sh", makePosixArgv("sh"));
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "printf 'custom tool output'" },
        },
    };

    var result = try custom_tool.execute(testing_allocator, io, &session_state, "call_custom", args);
    defer result.deinit();

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("custom tool output", parsed.value.stdout);
    try std.testing.expectEqual(0, parsed.value.exit_code.?);
}

test "findCutoff helper" {
    const text_few_lines = "line 1\nline 2\nline 3\n";
    try std.testing.expectEqual(null, findCutoff(text_few_lines, 3, 100));
    try std.testing.expectEqual(null, findCutoff(text_few_lines, 5, 100));

    // Cutoff by lines
    const line_cutoff = findCutoff(text_few_lines, 2, 100);
    try std.testing.expect(line_cutoff != null);
    try std.testing.expectEqual(CutoffReason.lines, line_cutoff.?.reason);
    try std.testing.expectEqualStrings("line 1\nline 2\n", text_few_lines[0..line_cutoff.?.cutoff]);

    // Cutoff by bytes
    const byte_cutoff = findCutoff("abcdefghijklmnop", 10, 5);
    try std.testing.expect(byte_cutoff != null);
    try std.testing.expectEqual(CutoffReason.bytes, byte_cutoff.?.reason);
    try std.testing.expectEqualStrings("abcde", "abcdefghijklmnop"[0..byte_cutoff.?.cutoff]);

    // Cutoff does not split multi-byte UTF-8 sequence
    // '€' is 3 bytes: 0xE2 0x82 0xAC
    const utf8_text = "ab€cd"; // 2 + 3 + 2 = 7 bytes
    const cut_mid_char = findCutoff(utf8_text, 10, 4); // index 4 is in the middle of '€'
    try std.testing.expect(cut_mid_char != null);
    try std.testing.expectEqual(CutoffReason.bytes, cut_mid_char.?.reason);
    try std.testing.expectEqualStrings("ab", utf8_text[0..cut_mid_char.?.cutoff]);
}

test "sanitizeUtf8 helper" {
    const allocator = std.testing.allocator;

    const valid = "Hello, world! 123";
    const s_valid = try sanitizeUtf8(allocator, valid);
    defer allocator.free(s_valid);
    try std.testing.expectEqualStrings(valid, s_valid);

    const invalid = "bad \xFF\xFE bytes";
    const s_invalid = try sanitizeUtf8(allocator, invalid);
    defer allocator.free(s_invalid);
    try std.testing.expectEqualStrings("bad \xEF\xBF\xBD\xEF\xBF\xBD bytes", s_invalid);
}

test "Shell tool chatty command total timeout" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = sh;
    // Command prints periodically for ~3s total; each output interval (0.2s) is well below the 1s timeout.
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i; sleep 0.2; done" },
        },
        .{
            .name = "timeout_secs",
            .value = .{ .integer = 1 },
        },
    };

    var result = try tool.execute(testing_allocator, io, &session_state, "call_chatty_timeout", args);
    defer result.deinit();

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.error_message != null);
    try std.testing.expectEqualStrings("Command timed out after 1 seconds", parsed.value.error_message.?);
    try std.testing.expectEqual(null, parsed.value.exit_code);
}

test "Shell tool single long line byte cap truncation" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = sh;
    // Generate a single 70 KiB string without newlines
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "printf '%*s' 70000 '' | tr ' ' 'a'" },
        },
    };

    var result = try tool.execute(testing_allocator, io, &session_state, "call_byte_cap", args);
    defer result.deinit();

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(0, parsed.value.exit_code.?);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.stdout, "[Output truncated to 64 KiB. Full output saved to ") != null);

    // Clean up temporary file
    const prefix = "Full output saved to ";
    if (std.mem.indexOf(u8, parsed.value.stdout, prefix)) |idx| {
        const start = idx + prefix.len;
        if (std.mem.indexOf(u8, parsed.value.stdout[start..], "]")) |end_rel| {
            const temp_path = parsed.value.stdout[start .. start + end_rel];
            std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        }
    }
}

test "Shell tool non-UTF8 output sanitization" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;
    var session_state = SessionState.init(testing_allocator);
    defer session_state.deinit();

    const tool = sh;
    const args: []const llm.types.Argument = &.{
        .{
            .name = "command",
            .value = .{ .string = "printf 'hello \\xff\\xfe world'" },
        },
    };

    var result = try tool.execute(testing_allocator, io, &session_state, "call_non_utf8", args);
    defer result.deinit();

    const parsed = try std.json.parseFromSlice(ShellResult, testing_allocator, result.result, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(0, parsed.value.exit_code.?);
    try std.testing.expectEqualStrings("hello \u{FFFD}\u{FFFD} world", parsed.value.stdout);
}

test "writeTempFile creates and writes file content" {
    const testing_allocator = std.testing.allocator;
    const io = std.testing.io;

    const sample_content = "This is a test temporary file content.\n";
    const temp_path = try writeTempFile(testing_allocator, io, "coma_test_file", sample_content);
    defer testing_allocator.free(temp_path);
    defer std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};

    const file = try std.Io.Dir.openFileAbsolute(io, temp_path, .{ .mode = .read_only });
    defer file.close(io);

    var read_buf: [100]u8 = undefined;
    const slices = [_][]u8{&read_buf};
    const bytes_read = try file.readPositional(io, &slices, 0);
    try std.testing.expectEqualStrings(sample_content, read_buf[0..bytes_read]);
}
