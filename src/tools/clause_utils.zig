const std = @import("std");
const engine_mod = @import("../prolog/engine.zig");

// Returns true for names to skip during KB introspection: empty/$-prefixed (Trealla internals),
// module-qualified (contain `:``), or ZPM infrastructure (tms_justification, zpm_source, portray).
pub fn isBuiltin(name: []const u8) bool {
    if (name.len == 0) return true;
    if (name[0] == '$') return true;
    if (std.mem.indexOf(u8, name, ":") != null) return true;
    if (std.mem.eql(u8, name, "tms_justification")) return true;
    if (std.mem.eql(u8, name, "zpm_source")) return true;
    if (std.mem.eql(u8, name, "portray")) return true;
    return false;
}

pub fn isISOOperator(name: []const u8, arity: i64) bool {
    const Entry = struct { name: []const u8, arity: i64 };
    const operators = [_]Entry{
        .{ .name = "=", .arity = 2 },
        .{ .name = ",", .arity = 2 },
        .{ .name = ";", .arity = 2 },
        .{ .name = "is", .arity = 2 },
        .{ .name = "->", .arity = 2 },
        .{ .name = "\\=", .arity = 2 },
        .{ .name = "==", .arity = 2 },
        .{ .name = "\\==", .arity = 2 },
        .{ .name = "=..", .arity = 2 },
        .{ .name = "@<", .arity = 2 },
        .{ .name = "@>", .arity = 2 },
        .{ .name = "@=<", .arity = 2 },
        .{ .name = "@>=", .arity = 2 },
        .{ .name = "<", .arity = 2 },
        .{ .name = ">", .arity = 2 },
        .{ .name = "=<", .arity = 2 },
        .{ .name = ">=", .arity = 2 },
        .{ .name = "+", .arity = 2 },
        .{ .name = "-", .arity = 2 },
        .{ .name = "*", .arity = 2 },
        .{ .name = "/", .arity = 2 },
        .{ .name = ":-", .arity = 2 },
        .{ .name = ":-", .arity = 1 },
        .{ .name = "\\+", .arity = 1 },
        .{ .name = "!", .arity = 0 },
    };
    for (operators) |op| {
        if (std.mem.eql(u8, name, op.name) and arity == op.arity) return true;
    }
    return false;
}

pub fn buildClauseQuery(allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) ![]u8 {
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

/// Like buildClauseQuery but uses named arg variables A0, A1, ... instead of _.
/// The caller can then retrieve A0..An-1 from the solution bindings to reconstruct
/// the concrete head with actual argument values.
pub fn buildClauseQueryNamed(allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) ![]u8 {
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
            try w.print("A{d}", .{i});
        }
        try w.writeByte(')');
    }
    try w.writeByte(',');
    try w.writeAll(body);
    try w.writeByte(')');
    return aw.toOwnedSlice();
}

pub fn predicateKind(fact_count: usize, rule_count: usize) []const u8 {
    if (fact_count > 0 and rule_count > 0) return "both";
    if (rule_count > 0) return "rule";
    return "fact";
}

pub fn countClauses(engine: *engine_mod.Engine, allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) !usize {
    const query_str = try buildClauseQuery(allocator, name, arity, body);
    defer allocator.free(query_str);
    var result = try engine.query(query_str);
    defer result.deinit();
    return result.solutions.len;
}

test "buildClauseQuery arity 2" {
    const result = try buildClauseQuery(std.testing.allocator, "foo", 2, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(_,_),Body)", result);
}

test "buildClauseQueryNamed arity 2" {
    const result = try buildClauseQueryNamed(std.testing.allocator, "foo", 2, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(A0,A1),Body)", result);
}

test "buildClauseQueryNamed arity 0 omits parens" {
    const result = try buildClauseQueryNamed(std.testing.allocator, "foo", 0, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo,Body)", result);
}

test "buildClauseQueryNamed arity 1" {
    const result = try buildClauseQueryNamed(std.testing.allocator, "foo", 1, "true");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(A0),true)", result);
}

test "buildClauseQuery arity 0 omits parens" {
    const result = try buildClauseQuery(std.testing.allocator, "foo", 0, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo,Body)", result);
}

test "buildClauseQuery arity 1" {
    const result = try buildClauseQuery(std.testing.allocator, "foo", 1, "true");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(_),true)", result);
}

test "isBuiltin empty string" {
    try std.testing.expect(isBuiltin(""));
}

test "isBuiltin dollar-prefixed" {
    try std.testing.expect(isBuiltin("$foo"));
}

test "isBuiltin module-qualified" {
    try std.testing.expect(isBuiltin("mod:goal"));
}

test "isBuiltin tms_justification" {
    try std.testing.expect(isBuiltin("tms_justification"));
}

test "isBuiltin zpm_source" {
    try std.testing.expect(isBuiltin("zpm_source"));
}

test "isBuiltin portray" {
    try std.testing.expect(isBuiltin("portray"));
}

test "isBuiltin regular atom returns false" {
    try std.testing.expect(!isBuiltin("parent"));
}

test "isISOOperator =/2 returns true" {
    try std.testing.expect(isISOOperator("=", 2));
}

test "isISOOperator ,/2 returns true" {
    try std.testing.expect(isISOOperator(",", 2));
}

test "isISOOperator is/2 returns true" {
    try std.testing.expect(isISOOperator("is", 2));
}

test "isISOOperator !/0 returns true" {
    try std.testing.expect(isISOOperator("!", 0));
}

test "isISOOperator task_status/2 returns false" {
    try std.testing.expect(!isISOOperator("task_status", 2));
}

test "isISOOperator =/3 returns false" {
    try std.testing.expect(!isISOOperator("=", 3));
}

test "isISOOperator ;/2 returns true" {
    try std.testing.expect(isISOOperator(";", 2));
}

test "isISOOperator ->/2 returns true" {
    try std.testing.expect(isISOOperator("->", 2));
}

test "isISOOperator \\=/2 returns true" {
    try std.testing.expect(isISOOperator("\\=", 2));
}

test "isISOOperator ==/2 returns true" {
    try std.testing.expect(isISOOperator("==", 2));
}

test "isISOOperator \\==/2 returns true" {
    try std.testing.expect(isISOOperator("\\==", 2));
}

test "isISOOperator =../2 returns true" {
    try std.testing.expect(isISOOperator("=..", 2));
}

test "isISOOperator @</2 returns true" {
    try std.testing.expect(isISOOperator("@<", 2));
}

test "isISOOperator @>/2 returns true" {
    try std.testing.expect(isISOOperator("@>", 2));
}

test "isISOOperator @=</2 returns true" {
    try std.testing.expect(isISOOperator("@=<", 2));
}

test "isISOOperator @>=/2 returns true" {
    try std.testing.expect(isISOOperator("@>=", 2));
}

test "isISOOperator </2 returns true" {
    try std.testing.expect(isISOOperator("<", 2));
}

test "isISOOperator >/2 returns true" {
    try std.testing.expect(isISOOperator(">", 2));
}

test "isISOOperator =</2 returns true" {
    try std.testing.expect(isISOOperator("=<", 2));
}

test "isISOOperator >=/2 returns true" {
    try std.testing.expect(isISOOperator(">=", 2));
}

test "isISOOperator +/2 returns true" {
    try std.testing.expect(isISOOperator("+", 2));
}

test "isISOOperator -/2 returns true" {
    try std.testing.expect(isISOOperator("-", 2));
}

test "isISOOperator */2 returns true" {
    try std.testing.expect(isISOOperator("*", 2));
}

test "isISOOperator //2 returns true" {
    try std.testing.expect(isISOOperator("/", 2));
}

test "isISOOperator :-/2 returns true" {
    try std.testing.expect(isISOOperator(":-", 2));
}

test "isISOOperator :-/1 returns true" {
    try std.testing.expect(isISOOperator(":-", 1));
}

test "isISOOperator \\+/1 returns true" {
    try std.testing.expect(isISOOperator("\\+", 1));
}

test "isISOOperator is/1 returns false" {
    try std.testing.expect(!isISOOperator("is", 1));
}

test "isISOOperator feature_status/2 returns false" {
    try std.testing.expect(!isISOOperator("feature_status", 2));
}

test "predicateKind returns fact when only facts" {
    try std.testing.expectEqualStrings("fact", predicateKind(0, 0));
    try std.testing.expectEqualStrings("fact", predicateKind(5, 0));
}

test "predicateKind returns rule when only rules" {
    try std.testing.expectEqualStrings("rule", predicateKind(0, 3));
}

test "predicateKind returns both when facts and rules exist" {
    try std.testing.expectEqualStrings("both", predicateKind(2, 1));
}

test "countClauses returns correct count for asserted facts" {
    const engine = try engine_mod.Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("foo(1).");
    try engine.assertFact("foo(2).");
    try engine.assertFact("foo(3).");

    const count = try countClauses(engine, std.testing.allocator, "foo", 1, "true");
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "countClauses returns zero when no clauses match" {
    const engine = try engine_mod.Engine.init(.{});
    defer engine.deinit();

    const count = try countClauses(engine, std.testing.allocator, "nonexistent", 1, "true");
    try std.testing.expectEqual(@as(usize, 0), count);
}
