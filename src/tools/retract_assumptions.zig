const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const Term = engine_mod.Term;

pub const tool = mcp.tools.Tool{
    .name = "retract_assumptions",
    .description = "Retract all assumptions matching a glob-style pattern with full propagation semantics",
    .annotations = .{
        .readOnlyHint = false,
        .destructiveHint = true,
        .idempotentHint = true,
    },
    .handler = handler,
};

fn globMatch(pattern: []const u8, str: []const u8) bool {
    if (pattern.len == 0) return str.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (i <= str.len) : (i += 1) {
            if (globMatch(pattern[1..], str[i..])) return true;
        }
        return false;
    }
    if (str.len == 0) return false;
    if (pattern[0] == '?' or pattern[0] == str[0]) {
        return globMatch(pattern[1..], str[1..]);
    }
    return false;
}

fn termToString(allocator: std.mem.Allocator, term: Term) ![]u8 {
    return switch (term) {
        .atom => |s| allocator.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .variable => |s| allocator.dupe(u8, s),
        .compound => |c| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, c.functor);
            try buf.append(allocator, '(');
            for (c.args, 0..) |arg, i| {
                if (i > 0) try buf.append(allocator, ',');
                const arg_str = try termToString(allocator, arg);
                defer allocator.free(arg_str);
                try buf.appendSlice(allocator, arg_str);
            }
            try buf.append(allocator, ')');
            return buf.toOwnedSlice(allocator);
        },
        .list => |items| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try buf.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                const item_str = try termToString(allocator, item);
                defer allocator.free(item_str);
                try buf.appendSlice(allocator, item_str);
            }
            try buf.append(allocator, ']');
            return buf.toOwnedSlice(allocator);
        },
    };
}

fn retractAssumption(allocator: std.mem.Allocator, engine: *engine_mod.Engine, assumption: []const u8) !void {
    const query_str = try std.fmt.allocPrint(allocator, "tms_justification(F,{s})", .{assumption});
    defer allocator.free(query_str);

    var fact_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (fact_strings.items) |s| allocator.free(s);
        fact_strings.deinit(allocator);
    }

    var qr = engine.query(query_str) catch {
        const retract_empty = try std.fmt.allocPrint(allocator, "tms_justification(_,{s})", .{assumption});
        defer allocator.free(retract_empty);
        engine.retractAll(retract_empty) catch {};
        return;
    };
    defer qr.deinit();

    for (qr.solutions) |solution| {
        const fact_term = solution.bindings.get("F") orelse continue;
        const fact_str = termToString(allocator, fact_term) catch continue;
        fact_strings.append(allocator, fact_str) catch {
            allocator.free(fact_str);
            continue;
        };
    }

    const retract_pattern = try std.fmt.allocPrint(allocator, "tms_justification(_,{s})", .{assumption});
    defer allocator.free(retract_pattern);
    engine.retractAll(retract_pattern) catch {};

    for (fact_strings.items) |fact_str| {
        const check_query = std.fmt.allocPrint(allocator, "tms_justification({s},_)", .{fact_str}) catch continue;
        defer allocator.free(check_query);

        const has_other = blk: {
            var check_qr = engine.query(check_query) catch break :blk false;
            defer check_qr.deinit();
            break :blk check_qr.solutions.len > 0;
        };

        if (!has_other) {
            engine.retractAll(fact_str) catch {};
        }
    }
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const pattern = mcp.tools.getString(args, "pattern") orelse return mcp.tools.ToolError.InvalidArguments;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    var matching: std.ArrayList([]u8) = .empty;
    defer {
        for (matching.items) |s| allocator.free(s);
        matching.deinit(allocator);
    }

    var list_qr = engine.query("tms_justification(_,A)") catch {
        const msg = std.fmt.allocPrint(allocator, "Retracted pattern '{s}': 0 assumption(s) removed", .{pattern}) catch return mcp.tools.ToolError.OutOfMemory;
        defer allocator.free(msg);
        return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer list_qr.deinit();

    for (list_qr.solutions) |solution| {
        const a_term = solution.bindings.get("A") orelse continue;
        const a_str = termToString(allocator, a_term) catch continue;
        defer allocator.free(a_str);

        if (!globMatch(pattern, a_str)) continue;

        var already = false;
        for (matching.items) |existing| {
            if (std.mem.eql(u8, existing, a_str)) {
                already = true;
                break;
            }
        }
        if (already) continue;

        const owned = allocator.dupe(u8, a_str) catch continue;
        matching.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }

    for (matching.items) |assumption| {
        retractAssumption(allocator, engine, assumption) catch {};
    }

    const msg = std.fmt.allocPrint(allocator, "Retracted pattern '{s}': {d} assumption(s) removed", .{ pattern, matching.items.len }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler retracts all assumptions matching pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), session1_a1).");
    try engine.assertFact("running(service).");
    try engine.assertFact("tms_justification(running(service), session1_a2).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("pattern", .{ .string = "session1_*" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "session1_*") != null);
}

test "handler only retracts assumptions matching pattern, not others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), session1_a1).");
    try engine.assertFact("active(svc).");
    try engine.assertFact("tms_justification(active(svc), session2_a1).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("pattern", .{ .string = "session1_*" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler is idempotent when pattern matches no assumptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("pattern", .{ .string = "nonexistent_*" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when pattern key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
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
    try obj.put("pattern", .{ .string = "session1_*" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
