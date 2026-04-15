const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const wal = @import("../persistence/wal.zig");
const JournalEntry = wal.JournalEntry;

pub const tool = mcp.tools.Tool{
    .name = "update_fact",
    .description = "Atomically replace an existing Prolog fact in the knowledge base (retract old_fact, assert new_fact). Returns an error if old_fact is not found, leaving the knowledge base unchanged.",
    .annotations = .{
        .readOnlyHint = false,
        .destructiveHint = true,
        .idempotentHint = false,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const old_fact = mcp.tools.getString(args, "old_fact") orelse return mcp.tools.ToolError.InvalidArguments;
    const new_fact = mcp.tools.getString(args, "new_fact") orelse return mcp.tools.ToolError.InvalidArguments;

    if (std.mem.indexOf(u8, new_fact, ":-") != null) {
        return mcp.tools.errorResult(allocator, "new_fact must not contain rule syntax") catch return mcp.tools.ToolError.OutOfMemory;
    }

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    engine.retractFact(old_fact) catch {
        const msg = std.fmt.allocPrint(allocator, "No matching clause for: {s}", .{old_fact}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    engine.assertFact(new_fact) catch return mcp.tools.ToolError.ExecutionFailed;

    if (context.getPersistenceManagerAs(PersistenceManager)) |pm| {
        const ts = std.time.timestamp();
        pm.journalMutation(JournalEntry{ .timestamp = ts, .op = .retract, .clause = old_fact }) catch {};
        pm.journalMutation(JournalEntry{ .timestamp = ts, .clause = new_fact }) catch {};
    }

    const msg = std.fmt.allocPrint(allocator, "Updated: {s}", .{new_fact}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler atomically retracts old fact and asserts new fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("server(alpha, v1).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("old_fact", .{ .string = "server(alpha, v1)" });
    try obj.put("new_fact", .{ .string = "server(alpha, v2)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "server(alpha, v2)") != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when new_fact key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("old_fact", .{ .string = "server(alpha, v1)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when old_fact does not exist and does not assert new_fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("old_fact", .{ .string = "server(ghost, v0)" });
    try obj.put("new_fact", .{ .string = "server(ghost, v1)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);

    // new_fact must NOT have been asserted
    var qr = try engine.query("server(ghost, _).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 0), qr.solutions.len);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("old_fact", .{ .string = "server(alpha, v1)" });
    try obj.put("new_fact", .{ .string = "server(alpha, v2)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler returns error result when new_fact contains rule syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("old_fact", .{ .string = "server(alpha, v1)" });
    try obj.put("new_fact", .{ .string = "server(X, v2) :- active(X)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler journals old_fact and new_fact as atomic group to WAL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("server(alpha, v1).");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("old_fact", .{ .string = "server(alpha, v1)" });
    try obj.put("new_fact", .{ .string = "server(alpha, v2)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [2048]u8 = undefined;
    const content = try tmp.dir.readFile("journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "server(alpha, v1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "server(alpha, v2)") != null);
}
