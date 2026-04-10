const std = @import("std");
const mcp = @import("mcp");

pub const tool = mcp.tools.Tool{
    .name = "echo",
    .description = "Echo back the input message",
    .annotations = .{
        .readOnlyHint = true,
        .idempotentHint = true,
        .destructiveHint = false,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const message = mcp.tools.getString(args, "message") orelse return mcp.tools.ToolError.InvalidArguments;
    return mcp.tools.textResult(allocator, message);
}

test "handler echoes message string from args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("message", .{ .string = "hello world" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("hello world", result.content[0].text.text);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when message key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}
