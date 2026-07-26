const std = @import("std");
const agent = @import("agent");

pub const Tool = agent.Tool.init(.{
    .name = "update_todo",
    .description = "Replaces the current todo list with the provided markdown text. Use this list to keep track of upcoming tasks, completed tasks, and in progress tasks.",
    .parameters = &.{
        .{
            .name = "content",
            .description = "The todo list in markdown format. To clear the todo list, pass an empty string.",
            .type = .string,
            .required = true,
        },
    },
}, execute);

fn execute(ctx: agent.ToolCallContext, content: []const u8) ![]const u8 {
    if (content.len == 0) {
        ctx.clearInjectedContext();
        return "Todo list cleared.";
    } else {
        try ctx.setInjectedContext(content);
        return "Todo list updated.";
    }
}
