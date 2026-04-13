const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");

pub const tool = mcp.tools.Tool{
    .name = "list_assumptions",
    .description = "Return all named assumptions currently registered in the truth maintenance system",
    .annotations = .{
        .readOnlyHint = true,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = args;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    var qr = engine.query("tms_justification(_, A)") catch {
        return buildResponse(allocator, &.{});
    };
    defer qr.deinit();

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var assumptions: std.ArrayList([]const u8) = .empty;
    defer assumptions.deinit(allocator);

    for (qr.solutions) |solution| {
        const assumption_term = solution.bindings.get("A") orelse continue;
        const assumption_str = switch (assumption_term) {
            .atom => |s| s,
            else => continue,
        };
        if (seen.contains(assumption_str)) continue;
        seen.put(assumption_str, {}) catch continue;
        assumptions.append(allocator, assumption_str) catch continue;
    }

    return buildResponse(allocator, assumptions.items);
}

fn buildResponse(allocator: std.mem.Allocator, assumptions: []const []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    buf.append(allocator, '[') catch return mcp.tools.ToolError.OutOfMemory;
    for (assumptions, 0..) |a, i| {
        if (i > 0) buf.append(allocator, ',') catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
        buf.appendSlice(allocator, a) catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
    }
    buf.append(allocator, ']') catch return mcp.tools.ToolError.OutOfMemory;

    return mcp.tools.textResult(allocator, buf.items) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler returns assumption names when assumptions exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "baseline") != null);
}

test "handler returns deduplicated assumption names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("active(service).");
    try engine.assertFact("tms_justification(deployed(app, prod), a1).");
    try engine.assertFact("tms_justification(active(service), a1).");
    try engine.assertFact("tms_justification(deployed(app, prod), a2).");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    // a1 appears twice in tms_justification but must appear once in result
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "a1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "a2") != null);
}

test "handler returns empty list when no assumptions are registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "[]") != null);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    const result = handler(allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
