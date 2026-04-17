const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");

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

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = args;
    const engine = context.getEngine() orelse
        return mcp.tools.errorResult(allocator, "Prolog engine is not initialized") catch return mcp.tools.ToolError.OutOfMemory;

    var entries: std.ArrayList(PredicateEntry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var schema_result = engine.query("current_predicate(F/A),functor(H,F,A),predicate_property(H,dynamic)") catch {
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
        if (isBuiltin(name_raw)) continue;
        if (!isValidAtomName(name_raw)) continue;

        const name = allocator.dupe(u8, name_raw) catch return mcp.tools.ToolError.OutOfMemory;
        errdefer allocator.free(name);

        const fact_count = countClauses(engine, allocator, name, arity, "true");
        const all_count = countClauses(engine, allocator, name, arity, "_");
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

fn isBuiltin(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '$') return true;
    if (std.mem.indexOf(u8, name, ":") != null) return true;
    if (std.mem.eql(u8, name, "tms_justification")) return true;
    if (std.mem.eql(u8, name, "zpm_source")) return true;
    return false;
}

/// Validates that a predicate name is a safe Prolog atom: lowercase start, then [a-zA-Z0-9_].
/// Rejects names containing parentheses, commas, operators, or other injection-prone characters.
fn isValidAtomName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => return false,
        }
    }
    return true;
}

fn buildClauseQuery(allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("clause(");
    try w.writeAll(name);
    if (arity > 0) {
        try w.writeByte('(');
        var i: i64 = 0;
        while (i < arity) : (i += 1) {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('_');
        }
        try w.writeByte(')');
    }
    try w.writeByte(',');
    try w.writeAll(body);
    try w.writeByte(')');
    return aw.toOwnedSlice();
}

fn countClauses(engine: *engine_mod.Engine, allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) usize {
    const query_str = buildClauseQuery(allocator, name, arity, body) catch return 0;
    defer allocator.free(query_str);
    var result = engine.query(query_str) catch return 0;
    defer result.deinit();
    return result.solutions.len;
}

fn buildSchemaJson(allocator: std.mem.Allocator, entries: []const PredicateEntry) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"predicates\":[");
    for (entries, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        const pred_type: []const u8 = if (entry.fact_count > 0 and entry.rule_count > 0)
            "both"
        else if (entry.rule_count > 0)
            "rule"
        else
            "fact";
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

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("person(alice)");
    try engine.assertFact("person(bob)");

    const result = try handler(allocator, null);

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

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "predicates") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"total\":0") != null);
}

test "handler classifies rule-only predicate as rule type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assert("grandparent(X,Z) :- parent(X,Y), parent(Y,Z)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "grandparent") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"rule\"") != null);
}

test "handler returns valid result when args are null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
}

test "handler returns error message when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    const result = try handler(allocator, null);
    try std.testing.expect(result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "not initialized") != null);
}

test "handler classifies fact-only predicate as fact type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("animal(dog)");
    try engine.assertFact("animal(cat)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"fact\"") != null);
}

test "handler classifies predicate with facts and rules as both type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("vehicle(car)");
    try engine.assert("vehicle(X) :- motorbike(X)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"both\"") != null);
}

test "handler includes accurate clause count in schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("color(red)");
    try engine.assertFact("color(blue)");
    try engine.assertFact("color(green)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":3") != null);
}

test "handler reports arity 0 for zero-argument predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("is_ready");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"is_ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"arity\":0") != null);
}
