const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("start_node", "The reference atom whose dependents are traced. The tool queries path(X, start_node), so the caller's path/2 rules must be written as path(X, Start) :- depends_on(Start, X) (or similar), i.e. second argument is the source and first is the destination.", true);
    const built = try schema.build();

    return .{
        .name = "trace_dependency",
        .description = "Trace transitive dependents of an atom via path/2 rules. Returns every X such that path(X, start_node) is provable. Convention: path/2 rules must have the source as the SECOND argument (path(X, Start) :- depends_on(Start, X), ...). If your rules put the source first, swap the argument order before calling.",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"start_node"},
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
    const start_node = mcp.tools.getString(args, "start_node") orelse return mcp.tools.ToolError.InvalidArguments;
    if (start_node.len == 0) return mcp.tools.errorResult(allocator, "start_node must not be empty") catch return mcp.tools.ToolError.OutOfMemory;

    // Validate start_node is a safe Prolog atom (prevents injection)
    for (start_node, 0..) |c, idx| {
        const valid = if (idx == 0)
            (c >= 'a' and c <= 'z') or c == '_'
        else
            (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!valid) return mcp.tools.errorResult(allocator, "start_node must be a valid Prolog atom") catch return mcp.tools.ToolError.OutOfMemory;
    }

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const goal = std.fmt.allocPrint(allocator, "path(X, {s})", .{start_node}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(goal);

    var query_result = engine.query(goal) catch {
        return mcp.tools.errorResult(allocator, "Query execution failed") catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer query_result.deinit();

    const json_str = buildDepsJson(allocator, query_result.solutions) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json_str);

    return mcp.tools.textResult(allocator, json_str) catch return mcp.tools.ToolError.OutOfMemory;
}

fn buildDepsJson(allocator: std.mem.Allocator, solutions: []engine_mod.Solution) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    try writer.writeByte('[');
    var first = true;
    for (solutions) |solution| {
        if (solution.bindings.get("X")) |x_term| {
            switch (x_term) {
                .atom => |s| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try std.json.Stringify.value(s, .{}, writer);
                },
                .integer => |n| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try std.json.Stringify.value(n, .{}, writer);
                },
                .float => |f| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try std.json.Stringify.value(f, .{}, writer);
                },
                else => {},
            }
        }
    }
    try writer.writeByte(']');

    return aw.toOwnedSlice();
}

const Engine = engine_mod.Engine;

test "handler returns reachable nodes for transitive dependency chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("depends_on(a, b)");
    try engine.assertFact("depends_on(b, c)");
    try engine.assert("path(X, Start) :- depends_on(Start, X)");
    try engine.assert("path(X, Start) :- depends_on(Start, Mid), path(X, Mid)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("start_node", .{ .string = "a" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "c") != null);
}

test "handler returns empty result for isolated node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("start_node", .{ .string = "isolated" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("[]", result.content[0].text.text);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when start_node key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when start_node is empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("start_node", .{ .string = "" });
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
    try obj.put("start_node", .{ .string = "a" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler rejects start_node with injection attempt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("start_node", .{ .string = "a), halt(0" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}
