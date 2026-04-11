const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");

pub const tool = mcp.tools.Tool{
    .name = "verify_consistency",
    .description = "Check the knowledge base for integrity violations by querying integrity_violation/N predicates",
    .annotations = .{
        .readOnlyHint = true,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;
    const scope = mcp.tools.getString(args, "scope");

    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| allocator.free(v);
        violations.deinit(allocator);
    }

    const query_str = if (scope) |s|
        std.fmt.allocPrint(allocator, "integrity_violation_{s}(X)", .{s}) catch return mcp.tools.ToolError.OutOfMemory
    else
        allocator.dupe(u8, "integrity_violation(X)") catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(query_str);

    var query_result = engine.query(query_str) catch {
        const json = buildViolationsJson(allocator, violations.items) catch return mcp.tools.ToolError.OutOfMemory;
        defer allocator.free(json);
        return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer query_result.deinit();

    for (query_result.solutions) |sol| {
        const x_term = sol.bindings.get("X") orelse continue;
        const term_str = termToStr(allocator, x_term) catch continue;
        violations.append(allocator, term_str) catch {
            allocator.free(term_str);
            return mcp.tools.ToolError.OutOfMemory;
        };
    }

    const json = buildViolationsJson(allocator, violations.items) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json);
    return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
}

fn termToStr(allocator: std.mem.Allocator, term: engine_mod.Term) ![]const u8 {
    return switch (term) {
        .atom => |s| allocator.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .variable => |s| allocator.dupe(u8, s),
        .list => |items| blk: {
            var aw: std.io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            const w = &aw.writer;
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                const s = try termToStr(allocator, item);
                defer allocator.free(s);
                try w.writeAll(s);
            }
            try w.writeByte(']');
            break :blk aw.toOwnedSlice();
        },
        .compound => |c| blk: {
            var aw: std.io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            const w = &aw.writer;
            try w.writeAll(c.functor);
            try w.writeByte('(');
            for (c.args, 0..) |arg, i| {
                if (i > 0) try w.writeByte(',');
                const s = try termToStr(allocator, arg);
                defer allocator.free(s);
                try w.writeAll(s);
            }
            try w.writeByte(')');
            break :blk aw.toOwnedSlice();
        },
    };
}

fn buildViolationsJson(allocator: std.mem.Allocator, violations: []const []const u8) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"violations\":[");
    for (violations, 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(v, .{}, w);
    }
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

const Engine = engine_mod.Engine;

test "handler returns violations when integrity rule fires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("risky(deploy_v3)");
    try engine.assert("integrity_violation(X) :- risky(X)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "violations") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "deploy_v3") != null);
}

test "handler returns empty violations when no integrity rules defined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("some_fact(value)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "violations") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[]") != null or
        std.mem.indexOf(u8, text, "\"violations\":[]") != null);
}

test "handler returns empty violations when rules exist but no facts violate them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assert("integrity_violation(X) :- risky(X), approved(X)");
    try engine.assertFact("risky(a)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "violations") != null);
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

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    const result = handler(allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler filters violations by scope when scope arg provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("risky(access_key)");
    try engine.assert("integrity_violation(X) :- risky(X)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("scope", .{ .string = "deployment" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "access_key") == null);
}

test "handler returns violations when scope matches rule head" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("risky(deploy_v3)");
    try engine.assert("integrity_violation_deployment(X) :- risky(X)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("scope", .{ .string = "deployment" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "deploy_v3") != null);
}
