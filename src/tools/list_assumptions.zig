const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "list_assumptions",
        .description = "Return all named assumptions currently registered in the truth maintenance system",
        .inputSchema = .{
            .properties = built.object.get("properties"),
        },
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const engine = context.getEngineForMemory(context.resolveMemoryName(args)) orelse return mcp.tools.ToolError.ExecutionFailed;

    const query_str = "tms_justification(_, A)";

    var qr = engine.query(query_str) catch {
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

test "list_assumptions tool exposes memory as an optional JSON-schema string with exact description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const built_tool = try tool(arena.allocator());
    const schema = built_tool.inputSchema orelse return error.MissingSchema;
    const properties = schema.properties orelse return error.MissingProperties;
    const properties_object = switch (properties) {
        .object => |object| object,
        else => return error.UnexpectedPropertiesType,
    };
    const memory = properties_object.get("memory") orelse return error.MissingMemoryProperty;
    const memory_object = switch (memory) {
        .object => |object| object,
        else => return error.UnexpectedMemoryPropertyType,
    };

    try std.testing.expectEqualStrings("string", memory_object.get("type").?.string);
    try std.testing.expectEqualStrings(
        "Target memory segment (optional, defaults to default memory)",
        memory_object.get("description").?.string,
    );
    for (schema.required orelse &.{}) |required| {
        try std.testing.expect(!std.mem.eql(u8, required, "memory"));
    }
}

test "handler returns assumption names when assumptions exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "default" });
    const args = std.json.Value{ .object = obj };
    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "baseline") != null);
}

test "handler reads assumptions from explicitly named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    var knowledge = try tmp.dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer knowledge.close(std.testing.io);
    try knowledge.writeStreamingAll(std.testing.io, "tms_justification(named_fact, named_assumption).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("assumption_memory", path_buf[0..path_len], .project, .ro, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "assumption_memory" });
    const args = std.json.Value{ .object = obj };
    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "named_assumption") != null);
}

test "handler returns ExecutionFailed for unavailable named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "missing_memory" });
    const args = std.json.Value{ .object = obj };

    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, handler(null, std.testing.io, allocator, args));
}

test "handler returns deduplicated assumption names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("active(service).");
    try engine.assertFact("tms_justification(deployed(app, prod), a1).");
    try engine.assertFact("tms_justification(active(service), a1).");
    try engine.assertFact("tms_justification(deployed(app, prod), a2).");

    const result = try handler(null, std.testing.io, allocator, null);

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

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "[]") != null);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    const result = handler(null, std.testing.io, allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
