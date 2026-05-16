const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const Term = engine_mod.Term;
const Solution = engine_mod.Solution;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("goal", "A Prolog goal to evaluate (e.g. 'parent(X, bob)')", true);
    const built = try schema.build();

    return .{
        .name = "query_logic",
        .description = "Execute a Prolog goal and return all variable bindings as JSON",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"goal"},
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
    const goal = mcp.tools.getString(args, "goal") orelse return mcp.tools.ToolError.InvalidArguments;
    if (goal.len == 0) return mcp.tools.errorResult(allocator, "Goal must not be empty") catch return mcp.tools.ToolError.OutOfMemory;
    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const memory_name = context.resolveMemoryName(args);
    if (!std.mem.eql(u8, memory_name, "default")) {
        const reg = context.getMemoryRegistryAs(MemoryRegistry);
        if (reg) |r| {
            if (r.getMounted(memory_name) == null) {
                const msg = std.fmt.allocPrint(allocator, "Memory not mounted: {s}", .{memory_name}) catch return mcp.tools.ToolError.OutOfMemory;
                return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
            }
        } else {
            const msg = std.fmt.allocPrint(allocator, "Memory not mounted: {s}", .{memory_name}) catch return mcp.tools.ToolError.OutOfMemory;
            return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
        }
    }
    const qualified_goal = context.qualifyClause(allocator, memory_name, goal) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(qualified_goal);

    var query_result = engine.query(qualified_goal) catch {
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

test "named memory query routes to qualified goal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    // Create the knowledge.pl file required by registry.mount
    var kfile = try tmp.dir.createFile("knowledge.pl", .{});
    defer kfile.close();
    try kfile.writeAll(":- module(feature_auth, []).\n");

    // Fact exists only in the feature_auth module namespace, not globally.
    // Without memory dispatch the unqualified search returns [] — this test fails RED.
    try engine.loadString(
        \\:- module(feature_auth, []).
        \\:- dynamic(task_status/2).
        \\task_status(auth_check, done).
        \\
    );

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.mount("feature_auth", dir_path, .project, .ro, engine);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("goal", .{ .string = "task_status(X, done)" });
    try obj.put("memory", .{ .string = "feature_auth" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(!std.mem.eql(u8, text, "[]"));
    try std.testing.expect(std.mem.indexOf(u8, text, "auth_check") != null);
}

test "default memory uses unqualified goal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("task_status(deploy_v1, done)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("goal", .{ .string = "task_status(X, done)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(!std.mem.eql(u8, text, "[]"));
    try std.testing.expect(std.mem.indexOf(u8, text, "deploy_v1") != null);
}

test "handler returns error result when goal is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("goal", .{ .string = "(((" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns error result when named memory is not mounted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("goal", .{ .string = "task_status(X, done)" });
    try obj.put("memory", .{ .string = "nonexistent_module" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "not mounted") != null);
}
