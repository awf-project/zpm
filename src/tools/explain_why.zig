const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const term_utils = @import("term_utils");

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("fact", "The Prolog fact to explain (e.g. 'grandparent(tom, jim)')", true);
    _ = try schema.addInteger("max_depth", "Maximum proof tree depth (default: unlimited)", false);
    const built = try schema.build();

    return .{
        .name = "explain_why",
        .description = "Trace the proof tree for a given fact and return a structured JSON explanation of how it was derived",
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

const Engine = engine_mod.Engine;

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;
    if (fact.len == 0) return mcp.tools.ToolError.InvalidArguments;
    const max_depth_opt = mcp.tools.getInteger(args, "max_depth");

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    var provability = engine.query(fact) catch return mcp.tools.ToolError.ExecutionFailed;
    defer provability.deinit();
    const proven = provability.solutions.len > 0;

    const json_str = buildExplainJson(allocator, engine, fact, proven, max_depth_opt) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json_str);

    return mcp.tools.textResult(allocator, json_str) catch return mcp.tools.ToolError.OutOfMemory;
}

fn buildExplainJson(
    allocator: std.mem.Allocator,
    engine: *Engine,
    fact: []const u8,
    proven: bool,
    max_depth_opt: ?i64,
) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    if (!proven) {
        try writer.writeAll("{\"goal\":");
        try std.json.Stringify.value(fact, .{}, writer);
        try writer.writeAll(",\"proven\":false,\"children\":[]}");
    } else {
        const max_depth: usize = if (max_depth_opt) |d|
            if (d >= 0) @intCast(d) else 1000
        else
            1000;
        try buildProofTree(allocator, writer, engine, fact, max_depth, 0);
    }

    return aw.toOwnedSlice();
}

fn buildProofTree(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    engine: *Engine,
    goal: []const u8,
    max_depth: usize,
    current_depth: usize,
) !void {
    try writer.writeAll("{\"goal\":");
    try std.json.Stringify.value(goal, .{}, writer);
    try writer.writeAll(",\"proven\":true");

    if (current_depth >= max_depth) {
        try writer.writeAll(",\"children\":\"truncated\"}");
        return;
    }

    const clause_query = try std.fmt.allocPrint(allocator, "clause({s},Body),call(Body)", .{goal});
    defer allocator.free(clause_query);

    var clause_result = engine.query(clause_query) catch {
        try writer.writeAll(",\"children\":[]}");
        return;
    };
    defer clause_result.deinit();

    if (clause_result.solutions.len == 0) {
        try writer.writeAll(",\"children\":[]}");
        return;
    }

    const body_term = clause_result.solutions[0].bindings.get("Body") orelse {
        try writer.writeAll(",\"children\":[]}");
        return;
    };

    var goals: std.ArrayList([]u8) = .empty;
    defer {
        for (goals.items) |g| allocator.free(g);
        goals.deinit(allocator);
    }
    try collectGoals(allocator, body_term, &goals);

    try writer.writeAll(",\"children\":[");
    for (goals.items, 0..) |sub_goal, i| {
        if (i > 0) try writer.writeByte(',');
        try buildProofTree(allocator, writer, engine, sub_goal, max_depth, current_depth + 1);
    }
    try writer.writeAll("]}");
}

fn collectGoals(allocator: std.mem.Allocator, term: engine_mod.Term, goals: *std.ArrayList([]u8)) !void {
    switch (term) {
        .atom => |s| {
            if (!std.mem.eql(u8, s, "true")) {
                try goals.append(allocator, try allocator.dupe(u8, s));
            }
        },
        .compound => |c| {
            if (std.mem.eql(u8, c.functor, ",") and c.args.len == 2) {
                try collectGoals(allocator, c.args[0], goals);
                try collectGoals(allocator, c.args[1], goals);
            } else {
                try goals.append(allocator, try term_utils.termToString(allocator, term));
            }
        },
        else => {
            try goals.append(allocator, try term_utils.termToString(allocator, term));
        },
    }
}

test "handler returns proof tree for provable fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("risky(deploy_v3)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "risky(deploy_v3)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "proven") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "risky(deploy_v3)") != null);
}

test "handler returns proven false for unprovable fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "risky(deploy_v3)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "proven") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "false") != null);
}

test "handler returns full proof tree for multi-level deduction chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("parent(a,b)");
    try engine.assertFact("parent(b,c)");
    try engine.assert("ancestor(X,Y) :- parent(X,Y)");
    try engine.assert("ancestor(X,Y) :- parent(X,Z), ancestor(Z,Y)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "ancestor(a,c)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "children") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ancestor(a,c)") != null);
    // Deduction chain must show actual proof steps — children must be non-empty
    try std.testing.expect(std.mem.indexOf(u8, text, "parent") != null);
}

test "handler returns InvalidArguments when fact arg is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = handler(allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when fact is empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "" });
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
    try obj.put("fact", .{ .string = "risky(x)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler truncates proof tree at max_depth with marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("parent(a,b)");
    try engine.assertFact("parent(b,c)");
    try engine.assertFact("parent(c,d)");
    try engine.assertFact("parent(d,e)");
    try engine.assertFact("parent(e,f)");
    try engine.assertFact("parent(f,g)");
    try engine.assertFact("parent(g,h)");
    try engine.assertFact("parent(h,i)");
    try engine.assertFact("parent(i,j)");
    try engine.assertFact("parent(j,k)");
    try engine.assert("ancestor(X,Y) :- parent(X,Y)");
    try engine.assert("ancestor(X,Y) :- parent(X,Z), ancestor(Z,Y)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "ancestor(a,k)" });
    try obj.put("max_depth", .{ .integer = 3 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "truncated") != null or
        std.mem.indexOf(u8, text, "...") != null or
        std.mem.indexOf(u8, text, "omitted") != null);
}

test "handler returns full tree when max_depth exceeds actual depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("parent(a,b)");
    try engine.assertFact("parent(b,c)");
    try engine.assert("ancestor(X,Y) :- parent(X,Y)");
    try engine.assert("ancestor(X,Y) :- parent(X,Z), ancestor(Z,Y)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "ancestor(a,c)" });
    try obj.put("max_depth", .{ .integer = 10 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "proven") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "children") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "truncated") == null);
    // When depth limit is not reached, actual proof steps must be visible
    try std.testing.expect(std.mem.indexOf(u8, text, "parent") != null);
}
