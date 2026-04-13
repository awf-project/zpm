const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");

pub const tool = mcp.tools.Tool{
    .name = "get_belief_status",
    .description = "Query whether a belief is currently supported and which assumptions justify it",
    .annotations = .{
        .readOnlyHint = true,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const query_str = std.fmt.allocPrint(allocator, "tms_justification({s}, A)", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(query_str);

    var qr = engine.query(query_str) catch {
        return buildResponse(allocator, false, &.{});
    };
    defer qr.deinit();

    var justifications: std.ArrayList([]const u8) = .empty;
    defer justifications.deinit(allocator);

    for (qr.solutions) |solution| {
        const assumption_term = solution.bindings.get("A") orelse continue;
        const assumption_str = switch (assumption_term) {
            .atom => |s| s,
            else => continue,
        };
        justifications.append(allocator, assumption_str) catch continue;
    }

    return buildResponse(allocator, justifications.items.len > 0, justifications.items);
}

fn buildResponse(allocator: std.mem.Allocator, supported: bool, justifications: []const []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"status\":\"") catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, if (supported) "in" else "out") catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, "\",\"justifications\":[") catch return mcp.tools.ToolError.OutOfMemory;
    for (justifications, 0..) |j, i| {
        if (i > 0) buf.append(allocator, ',') catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
        buf.appendSlice(allocator, j) catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
    }
    buf.appendSlice(allocator, "]}") catch return mcp.tools.ToolError.OutOfMemory;

    return mcp.tools.textResult(allocator, buf.items) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler returns status in with justifications when fact is supported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deployed(app, prod)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "baseline") != null);
}

test "handler returns status out with empty justifications when fact is unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "unknown_fact(x)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"out\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "[]") != null);
}

test "handler returns multiple justifications when fact has multiple supporting assumptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("active(service).");
    try engine.assertFact("tms_justification(active(service), assumption_a).");
    try engine.assertFact("tms_justification(active(service), assumption_b).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "active(service)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "assumption_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "assumption_b") != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when fact key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deployed(app, prod)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
