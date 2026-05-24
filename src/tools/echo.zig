const std = @import("std");
const mcp = @import("mcp");

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "message", "The message to echo back", true);
    const built = try schema.build(allocator);

    return .{
        .name = "echo",
        .description = "Echo back the input message",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"message"},
        },
        .annotations = .{
            .readOnlyHint = true,
            .idempotentHint = true,
            .destructiveHint = false,
        },
        .handler = handler,
    };
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const message = mcp.tools.getString(args, "message") orelse return mcp.tools.ToolError.InvalidArguments;
    return mcp.tools.textResult(allocator, message);
}

test "handler echoes message string from args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "message", .{ .string = "hello world" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("hello world", result.content[0].text.text);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when message key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}
