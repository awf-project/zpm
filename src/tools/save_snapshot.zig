const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;

pub const tool = mcp.tools.Tool{
    .name = "save_snapshot",
    .description = "Persist the current Prolog knowledge base to a named snapshot file",
    .annotations = .{
        .readOnlyHint = false,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const obj = if (args) |a| switch (a) {
        .object => |o| o,
        else => return mcp.tools.ToolError.InvalidArguments,
    } else return mcp.tools.ToolError.InvalidArguments;

    const name_val = obj.get("name") orelse return mcp.tools.ToolError.InvalidArguments;
    const name = switch (name_val) {
        .string => |s| s,
        else => return mcp.tools.ToolError.InvalidArguments,
    };

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;
    const pm = context.getPersistenceManagerAs(PersistenceManager) orelse return mcp.tools.ToolError.ExecutionFailed;

    pm.saveSnapshot(engine, name) catch return mcp.tools.ToolError.ExecutionFailed;

    const msg = std.fmt.allocPrint(allocator, "Snapshot '{s}' saved successfully.", .{name}) catch
        return mcp.tools.ToolError.ExecutionFailed;

    return mcp.tools.ToolResult{
        .is_error = false,
        .content = &.{.{ .text = .{ .text = msg } }},
    };
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when name key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler saves snapshot and returns confirmation when engine and persistence manager are active" {
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

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "test_snap" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "test_snap") != null);
}

test "handler creates snapshot file on disk" {
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

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "disk_snap" });
    const args = std.json.Value{ .object = obj };

    _ = try handler(allocator, args);

    _ = try tmp.dir.statFile("disk_snap.pl");
}

test "handler returns ExecutionFailed when no engine is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "no_engine_snap" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
