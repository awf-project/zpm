const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("fact", "The Prolog fact to check belief status for", true);
    const built = try schema.build();

    return .{
        .name = "get_belief_status",
        .description = "Query whether a belief is currently supported and which assumptions justify it",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"fact"},
        },
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const query_str = std.fmt.allocPrint(allocator, "tms_justification({s}, A)", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(query_str);

    var qr = engine.query(query_str) catch {
        return buildResponse(allocator, false, &.{}, "unknown");
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

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |s| allocator.free(s);

    const source: []const u8 = blk: {
        const source_query = std.fmt.allocPrint(allocator, "zpm_source({s}, S)", .{fact}) catch break :blk "unknown";
        defer allocator.free(source_query);
        var sqr = engine.query(source_query) catch break :blk "unknown";
        defer sqr.deinit();
        if (sqr.solutions.len > 0) {
            if (sqr.solutions[0].bindings.get("S")) |s_term| {
                const atom = switch (s_term) {
                    .atom => |s| s,
                    else => break :blk "unknown",
                };
                owned_source = allocator.dupe(u8, atom) catch break :blk "unknown";
                break :blk owned_source.?;
            }
        }
        break :blk "unknown";
    };

    return buildResponse(allocator, justifications.items.len > 0, justifications.items, source);
}

fn buildResponse(allocator: std.mem.Allocator, supported: bool, justifications: []const []const u8, source: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
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
    buf.appendSlice(allocator, "],\"source\":\"") catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, source) catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, "\"}") catch return mcp.tools.ToolError.OutOfMemory;

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

test "source field is interactive when zpm_source metadata is asserted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("config(timeout, 30).");
    try engine.assertFact("zpm_source(config(timeout, 30), interactive).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "config(timeout, 30)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"interactive\"") != null);
}

test "source field is unknown when no zpm_source metadata exists for fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("config(timeout, 30).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "config(timeout, 30)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"unknown\"") != null);
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
