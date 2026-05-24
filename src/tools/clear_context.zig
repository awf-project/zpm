const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const wal = @import("../persistence/wal.zig");
const JournalEntry = wal.JournalEntry;
const Engine = @import("../prolog/engine.zig").Engine;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "category", "A Prolog term pattern passed directly to retractall/1. Use wildcards for each argument: 'task_status(_, _)' for arity 2, 'module(_)' for arity 1. A bare functor name without parentheses matches only a 0-arity predicate.", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "clear_context",
        .description = "Retract all Prolog facts matching a given term pattern (invokes retractall/1). The pattern must be a full Prolog term with wildcards for argument positions, e.g. 'module(_)' or 'task_status(_, _)' — not just the functor name.",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"category"},
        },
        .annotations = .{
            .readOnlyHint = false,
            .destructiveHint = true,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const category = mcp.tools.getString(args, "category") orelse return mcp.tools.ToolError.InvalidArguments;
    if (category.len == 0) return mcp.tools.errorResult(allocator, "Category must not be empty") catch return mcp.tools.ToolError.OutOfMemory;

    const mem = switch (try context.resolveWritableMemory(allocator, args)) {
        .tool_result => |r| return r,
        .resolved => |m| m,
    };
    const memory_name = mem.memory_name;
    const target_pm = mem.pm;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const qualified = context.qualifyClause(allocator, memory_name, category) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(qualified);

    engine.retractAll(qualified) catch return mcp.tools.ToolError.ExecutionFailed;

    if (target_pm) |pm| {
        pm.journalMutation(JournalEntry{ .timestamp = blk: {
            var _ts: std.posix.timespec = undefined;
            _ = std.c.clock_gettime(std.posix.CLOCK.REALTIME, &_ts);
            break :blk _ts.sec;
        }, .op = .retractall, .clause = qualified }) catch return mcp.tools.ToolError.ExecutionFailed;
    }
    const msg = std.fmt.allocPrint(allocator, "Cleared: {s}", .{category}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "handler retracts all matching facts and returns confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("color(red).");
    try engine.assertFact("color(green).");
    try engine.assertFact("color(blue).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "category", .{ .string = "color(_)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "color(_)") != null);
}

test "handler journals cleared category to WAL when persistence manager is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();
    try engine.assertFact("color(red).");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "category", .{ .string = "color(_)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [1024]u8 = undefined;
    const content = try tmp.dir.readFile(std.testing.io, "journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "color(_)") != null);
}

test "handler succeeds when no facts match category" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "category", .{ .string = "nonexistent(_)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when category key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when category is empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "category", .{ .string = "" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "category", .{ .string = "role(_, _)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
