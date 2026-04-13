const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const Term = engine_mod.Term;

pub const tool = mcp.tools.Tool{
    .name = "retract_assumption",
    .description = "Retract a named assumption and remove facts that have no remaining justifications",
    .annotations = .{
        .readOnlyHint = false,
        .destructiveHint = true,
        .idempotentHint = true,
    },
    .handler = handler,
};

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

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const assumption = mcp.tools.getString(args, "assumption") orelse return mcp.tools.ToolError.InvalidArguments;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const query_str = std.fmt.allocPrint(allocator, "tms_justification(F,{s})", .{assumption}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(query_str);

    var qr = engine.query(query_str) catch {
        const msg = std.fmt.allocPrint(allocator, "Retracted assumption '{s}': 0 facts affected", .{assumption}) catch return mcp.tools.ToolError.OutOfMemory;
        defer allocator.free(msg);
        return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };
    defer qr.deinit();

    var fact_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (fact_strings.items) |s| allocator.free(s);
        fact_strings.deinit(allocator);
    }

    for (qr.solutions) |solution| {
        const fact_term = solution.bindings.get("F") orelse continue;
        const fact_str = termToString(allocator, fact_term) catch continue;
        fact_strings.append(allocator, fact_str) catch {
            allocator.free(fact_str);
            continue;
        };
    }

    const retract_pattern = std.fmt.allocPrint(allocator, "tms_justification(_,{s})", .{assumption}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(retract_pattern);
    engine.retractAll(retract_pattern) catch {};

    var removed_count: usize = 0;
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
            removed_count += 1;
        }
    }

    const msg = std.fmt.allocPrint(allocator, "Retracted assumption '{s}': {d} fact(s) removed", .{ assumption, removed_count }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler retracts assumption and removes unjustified fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "baseline") != null);
}

test "handler preserves fact when other justification exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("active(service).");
    try engine.assertFact("tms_justification(active(service), assumption_a).");
    try engine.assertFact("tms_justification(active(service), assumption_b).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "assumption_a" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler is idempotent when assumption does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "nonexistent" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when assumption key is missing" {
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
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
