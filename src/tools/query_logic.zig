const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const Term = engine_mod.Term;
const Solution = engine_mod.Solution;

pub const tool = mcp.tools.Tool{
    .name = "query_logic",
    .description = "Execute a Prolog goal and return all variable bindings as JSON",
    .annotations = .{
        .readOnlyHint = true,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = mcp.tools.getString(args, "goal") orelse return mcp.tools.ToolError.InvalidArguments;
    if (goal.len == 0) return mcp.tools.errorResult(allocator, "Goal must not be empty") catch return mcp.tools.ToolError.OutOfMemory;
    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    var query_result = engine.query(goal) catch {
        return mcp.tools.errorResult(allocator, "Query execution failed") catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer query_result.deinit();

    const json_str = buildQueryJson(allocator, query_result.solutions) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json_str);

    return mcp.tools.textResult(allocator, json_str) catch return mcp.tools.ToolError.OutOfMemory;
}

fn buildQueryJson(allocator: std.mem.Allocator, solutions: []Solution) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    try writer.writeByte('[');
    for (solutions, 0..) |solution, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        var iter = solution.bindings.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;
            try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
            try writer.writeByte(':');
            try writeTermJson(writer, entry.value_ptr.*);
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');

    return aw.toOwnedSlice();
}

fn writeTermJson(writer: *std.io.Writer, term: Term) !void {
    switch (term) {
        .atom => |s| try std.json.Stringify.value(s, .{}, writer),
        .integer => |i| try std.json.Stringify.value(i, .{}, writer),
        .float => |f| try std.json.Stringify.value(f, .{}, writer),
        .variable => |s| try std.json.Stringify.value(s, .{}, writer),
        .list => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, idx| {
                if (idx > 0) try writer.writeByte(',');
                try writeTermJson(writer, item);
            }
            try writer.writeByte(']');
        },
        .compound => |c| {
            try writer.writeAll("{\"functor\":");
            try std.json.Stringify.value(c.functor, .{}, writer);
            try writer.writeAll(",\"args\":[");
            for (c.args, 0..) |arg, idx| {
                if (idx > 0) try writer.writeByte(',');
                try writeTermJson(writer, arg);
            }
            try writer.writeAll("]}");
        },
    }
}

const Engine = engine_mod.Engine;

test "handler returns JSON array of bindings for matching goal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("fruit(apple)");
    try engine.assertFact("fruit(banana)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("goal", .{ .string = "fruit(X)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.startsWith(u8, text, "["));
    try std.testing.expect(std.mem.endsWith(u8, text, "]"));
    try std.testing.expect(std.mem.indexOf(u8, text, "apple") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "banana") != null);
}

test "handler returns empty JSON array when no solutions exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("goal", .{ .string = "nonexistent_predicate(X)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("[]", result.content[0].text.text);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when goal key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when goal is empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("goal", .{ .string = "" });
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
    try obj.put("goal", .{ .string = "fruit(X)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
