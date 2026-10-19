const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const term_utils = @import("term_utils");
const validation = @import("tool_validation");
const Term = engine_mod.Term;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "assumption", "The assumption name to get justifications for", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "get_justification",
        .description = "Return all facts currently supported by a given assumption",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"assumption"},
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
    const assumption = mcp.tools.getString(args, "assumption") orelse return mcp.tools.ToolError.InvalidArguments;
    if (!validation.isValidAtomName(assumption)) return mcp.tools.ToolError.InvalidArguments;

    const engine = context.getEngineForMemory(context.resolveMemoryName(args)) orelse return mcp.tools.ToolError.ExecutionFailed;

    const query_str = std.fmt.allocPrint(allocator, "tms_justification(F,{s})", .{assumption}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(query_str);

    var qr = engine.query(query_str) catch {
        return buildResponse(allocator, &.{});
    };
    defer qr.deinit();

    var facts: std.ArrayList([]u8) = .empty;
    defer {
        for (facts.items) |s| allocator.free(s);
        facts.deinit(allocator);
    }

    for (qr.solutions) |solution| {
        const fact_term = solution.bindings.get("F") orelse continue;
        const fact_str = term_utils.termToString(allocator, fact_term) catch continue;
        facts.append(allocator, fact_str) catch {
            allocator.free(fact_str);
            continue;
        };
    }

    return buildResponse(allocator, facts.items);
}

fn buildResponse(allocator: std.mem.Allocator, facts: []const []u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    buf.append(allocator, '[') catch return mcp.tools.ToolError.OutOfMemory;
    for (facts, 0..) |f, i| {
        if (i > 0) buf.append(allocator, ',') catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
        buf.appendSlice(allocator, f) catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
    }
    buf.append(allocator, ']') catch return mcp.tools.ToolError.OutOfMemory;

    return mcp.tools.textResult(allocator, buf.items) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

test "tool schema exposes memory as an optional string with the exact description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    const schema = t.inputSchema orelse return error.MissingSchema;
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

test "handler returns list of facts supported by assumption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "deployed(app, prod)") != null);
}

test "handler returns all facts when assumption supports multiple facts" {
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

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "assumption", .{ .string = "a1" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "deployed(app, prod)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "active(service)") != null);
}

test "handler returns empty facts list when assumption supports no facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "assumption", .{ .string = "nonexistent_assumption" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "[]") != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when assumption key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler returns justifications from explicitly named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);

    var kfile = try tmp.dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer kfile.close(std.testing.io);
    try kfile.writeStreamingAll(std.testing.io, "tms_justification(named_fact, named_assumption).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("feature_justifications", path_buf[0..path_len], .project, .ro, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "assumption", .{ .string = "named_assumption" });
    try obj.put(allocator, "memory", .{ .string = "feature_justifications" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "named_fact") != null);
}

test "handler returns ExecutionFailed for unmounted named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "assumption", .{ .string = "named_assumption" });
    try obj.put(allocator, "memory", .{ .string = "missing_memory" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
