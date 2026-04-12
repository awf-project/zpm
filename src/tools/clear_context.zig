const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");

pub const tool = mcp.tools.Tool{
    .name = "clear_context",
    .description = "Retract all Prolog facts matching a given category pattern",
    .annotations = .{
        .readOnlyHint = false,
        .destructiveHint = true,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const category = mcp.tools.getString(args, "category") orelse return mcp.tools.ToolError.InvalidArguments;
    if (category.len == 0) return mcp.tools.errorResult(allocator, "Category must not be empty") catch return mcp.tools.ToolError.OutOfMemory;
    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;
    engine.retractAll(category) catch return mcp.tools.ToolError.ExecutionFailed;
    const msg = std.fmt.allocPrint(allocator, "Cleared: {s}", .{category}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler retracts all matching facts and returns confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("color(red).");
    try engine.assertFact("color(green).");
    try engine.assertFact("color(blue).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("category", .{ .string = "color(_)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "color(_)") != null);
}

test "handler succeeds when no facts match category" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("category", .{ .string = "nonexistent(_)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when category key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when category is empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("category", .{ .string = "" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("category", .{ .string = "role(_, _)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
