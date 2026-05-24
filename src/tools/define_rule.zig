const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;
const Engine = @import("../prolog/engine.zig").Engine;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "head", "The head of the Prolog rule (e.g. 'grandparent(X, Z)')", true);
    _ = try schema.addString(allocator, "body", "The body of the Prolog rule (e.g. 'parent(X, Y), parent(Y, Z)')", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "define_rule",
        .description = "Assert a Prolog rule into the knowledge base",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{ "head", "body" },
        },
        .annotations = .{
            .readOnlyHint = false,
            .destructiveHint = false,
            .idempotentHint = false,
        },
        .handler = handler,
    };
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const head = mcp.tools.getString(args, "head") orelse return mcp.tools.ToolError.InvalidArguments;
    if (head.len == 0) return mcp.tools.errorResult(allocator, "Head must not be empty") catch return mcp.tools.ToolError.OutOfMemory;
    const body = mcp.tools.getString(args, "body") orelse return mcp.tools.ToolError.InvalidArguments;
    if (body.len == 0) return mcp.tools.errorResult(allocator, "Body must not be empty") catch return mcp.tools.ToolError.OutOfMemory;

    const mem = switch (try context.resolveWritableMemory(allocator, args)) {
        .tool_result => |r| return r,
        .resolved => |m| m,
    };
    const memory_name = mem.memory_name;
    const target_pm = mem.pm;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;
    const rule = std.fmt.allocPrint(allocator, "{s} :- {s}", .{ head, body }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(rule);

    const qualified_rule = context.qualifyClause(allocator, memory_name, rule) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(qualified_rule);

    engine.assert(qualified_rule) catch {
        const msg = std.fmt.allocPrint(allocator, "Failed to assert: {s} :- {s}", .{ head, body }) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (target_pm) |pm| {
        pm.journalMutation(JournalEntry{ .timestamp = blk: {
            var _ts: std.posix.timespec = undefined;
            _ = std.c.clock_gettime(std.posix.CLOCK.REALTIME, &_ts);
            break :blk _ts.sec;
        }, .clause = qualified_rule }) catch return mcp.tools.ToolError.ExecutionFailed;
    }
    const msg = std.fmt.allocPrint(allocator, "Asserted: {s} :- {s}", .{ head, body }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "handler asserts valid rule and returns confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "head", .{ .string = "mortal(X)" });
    try obj.put(allocator, "body", .{ .string = "human(X)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "mortal(X)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "human(X)") != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when head key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "body", .{ .string = "human(X)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when body key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "head", .{ .string = "mortal(X)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler journals rule to WAL when persistence manager is active" {
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

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "head", .{ .string = "mortal(X)" });
    try obj.put(allocator, "body", .{ .string = "human(X)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [1024]u8 = undefined;
    const content = try tmp.dir.readFile(std.testing.io, "journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "mortal(X)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "human(X)") != null);
}

test "handler returns error result for invalid Prolog syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "head", .{ .string = "123invalid" });
    try obj.put(allocator, "body", .{ .string = "also invalid!!" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(result.is_error);
}

test "handler returns error result when head is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "head", .{ .string = "" });
    try obj.put(allocator, "body", .{ .string = "human(X)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(result.is_error);
}

test "handler returns error result when body is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "head", .{ .string = "mortal(X)" });
    try obj.put(allocator, "body", .{ .string = "" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(result.is_error);
}
