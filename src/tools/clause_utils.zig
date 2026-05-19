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
