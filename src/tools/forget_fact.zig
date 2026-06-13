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
    _ = try schema.addString(allocator, "fact", "The Prolog fact to retract (e.g. 'parent(tom, bob)')", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "forget_fact",
        .description = "Retract a Prolog fact from the knowledge base",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"fact"},
        },
        .annotations = .{
            .readOnlyHint = false,
            .destructiveHint = true,
            .idempotentHint = false,
        },
        .handler = handler,
    };
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;
    if (fact.len == 0) return mcp.tools.errorResult(allocator, "Fact must not be empty") catch return mcp.tools.ToolError.OutOfMemory;

    const mem = switch (try context.resolveWritableMemory(allocator, args)) {
        .tool_result => |r| return r,
        .resolved => |m| m,
    };
    const target_pm = mem.pm;

    const engine = mem.engine orelse return mcp.tools.ToolError.ExecutionFailed;

    engine.retractFact(fact) catch {
        const msg = std.fmt.allocPrint(allocator, "No matching clause for: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (target_pm) |pm| {
        pm.journalMutation(JournalEntry{ .timestamp = wal.nowSeconds(), .op = .retract, .clause = fact }) catch return mcp.tools.ToolError.ExecutionFailed;
    }
    const msg = std.fmt.allocPrint(allocator, "Retracted: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "handler retracts existing fact and returns confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("role(alice, admin).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "role(alice, admin)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "role(alice, admin)") != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when fact key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when fact is empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler journals retraction to WAL when persistence manager is active" {
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
    try engine.assertFact("session(active).");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "session(active)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [1024]u8 = undefined;
    const content = try tmp.dir.readFile(std.testing.io, "journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "session(active)") != null);
}

test "handler returns error result when fact does not exist in knowledge base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "role(nobody, ghost)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns ExecutionFailed when journal write fails" {
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
    try engine.assertFact("journal_fail_forget(x).");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    // Force the next journal append to fail: replace journal.wal with a
    // directory so the per-append O_WRONLY open returns IsDir. Robust even when
    // tests run as root (a read-only file would still be writable).
    if (pm.wal) |_| {
        try tmp.dir.deleteFile(std.testing.io, "journal.wal");
        try tmp.dir.createDir(std.testing.io, "journal.wal", .default_dir);
    }

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "journal_fail_forget(x)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);

    // The engine retraction succeeded before the journal write failed, so the
    // fact is absent from the engine (safe data loss on restart, not corruption).
    var qr = try engine.query("journal_fail_forget(x).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 0), qr.solutions.len);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "role(alice, admin)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
