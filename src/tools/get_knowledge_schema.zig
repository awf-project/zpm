const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const validation = @import("tool_validation");
const clause_utils = @import("tool_clause_utils");

pub const tool = mcp.tools.Tool{
    .name = "get_knowledge_schema",
    .description = "Introspect the knowledge base to discover all defined predicates, their arities, and whether they are facts, rules, or both",
    .inputSchema = .{},
    .annotations = .{
        .readOnlyHint = true,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

const PredicateEntry = struct {
    name: []u8,
    arity: i64,
    fact_count: usize,
    rule_count: usize,
};

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const engine = context.getEngine() orelse
        return mcp.tools.errorResult(allocator, "Prolog engine is not initialized") catch return mcp.tools.ToolError.OutOfMemory;

    var entries: std.ArrayList(PredicateEntry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    const query_str = "current_predicate(F/A),functor(H,F,A),predicate_property(H,dynamic)";
    const memory_name = context.resolveMemoryName(args);
    const qualified_query = context.qualifyClause(allocator, memory_name, query_str) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(qualified_query);

    var schema_result = engine.query(qualified_query) catch {
        const json = buildSchemaJson(allocator, entries.items) catch return mcp.tools.ToolError.OutOfMemory;
        defer allocator.free(json);
        return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer schema_result.deinit();

    for (schema_result.solutions) |sol| {
        const f_term = sol.bindings.get("F") orelse continue;
        const a_term = sol.bindings.get("A") orelse continue;
        const name_raw = switch (f_term) {
            .atom => |s| s,
            else => continue,
        };
        const arity: i64 = switch (a_term) {
            .integer => |i| i,
            .atom => |s| std.fmt.parseInt(i64, s, 10) catch continue,
            else => continue,
        };
        if (clause_utils.isBuiltin(name_raw)) continue;
        if (!validation.isValidAtomName(name_raw)) continue;

        const name = allocator.dupe(u8, name_raw) catch return mcp.tools.ToolError.OutOfMemory;
        errdefer allocator.free(name);

        const fact_count = clause_utils.countClauses(engine, allocator, name, arity, "true") catch
            return mcp.tools.ToolError.ExecutionFailed;
        const all_count = clause_utils.countClauses(engine, allocator, name, arity, "_") catch
            return mcp.tools.ToolError.ExecutionFailed;
        const rule_count = if (all_count > fact_count) all_count - fact_count else 0;

        entries.append(allocator, .{
            .name = name,
            .arity = arity,
            .fact_count = fact_count,
            .rule_count = rule_count,
        }) catch |e| return e;
    }

    const json = buildSchemaJson(allocator, entries.items) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json);
    return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
}

fn buildSchemaJson(allocator: std.mem.Allocator, entries: []const PredicateEntry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"predicates\":[");
    for (entries, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        const pred_type = clause_utils.predicateKind(entry.fact_count, entry.rule_count);
        const count = entry.fact_count + entry.rule_count;
        try w.writeAll("{\"name\":");
        try std.json.Stringify.value(entry.name, .{}, w);
        try w.writeAll(",\"arity\":");
        try std.json.Stringify.value(entry.arity, .{}, w);
        try w.writeAll(",\"type\":");
        try std.json.Stringify.value(pred_type, .{}, w);
        try w.writeAll(",\"count\":");
        try std.json.Stringify.value(count, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"total\":");
    try std.json.Stringify.value(entries.len, .{}, w);
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

const Engine = engine_mod.Engine;

test "handler returns predicate list when facts are asserted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("person(alice)");
    try engine.assertFact("person(bob)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "predicates") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "person") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"arity\":1") != null);
}

test "handler returns empty predicates list for empty knowledge base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "predicates") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"total\":0") != null);
}

test "handler classifies rule-only predicate as rule type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assert("grandparent(X,Z) :- parent(X,Y), parent(Y,Z)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "grandparent") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"rule\"") != null);
}

test "handler returns valid result when args are null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
}

test "handler returns error message when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    const result = try handler(null, std.testing.io, allocator, null);
    try std.testing.expect(result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "not initialized") != null);
}

test "handler classifies fact-only predicate as fact type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("animal(dog)");
    try engine.assertFact("animal(cat)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"fact\"") != null);
}

test "handler classifies predicate with facts and rules as both type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("vehicle(car)");
    try engine.assert("vehicle(X) :- motorbike(X)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"both\"") != null);
}

test "handler includes accurate clause count in schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("color(red)");
    try engine.assertFact("color(blue)");
    try engine.assertFact("color(green)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":3") != null);
}

test "handler reports arity 0 for zero-argument predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("is_ready");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"is_ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"arity\":0") != null);
}

test "handler returns ExecutionFailed when countClauses allocation fails" {
    // A sentinel predicate forces the iteration path that calls countClauses.
    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    try engine.assertFact("sentinel_pred(x)");

    // fail_index=2 lets `entries` storage + name dupe succeed, then trips
    // the first allocation inside buildClauseQuery.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing.allocator();

    const result = handler(null, std.testing.io, allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
