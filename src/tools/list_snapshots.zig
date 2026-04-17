const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;

pub const tool = mcp.tools.Tool{
    .name = "list_snapshots",
    .description = "List all available Prolog knowledge base snapshots",
    .inputSchema = .{},
    .annotations = .{
        .readOnlyHint = true,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = args;

    const pm = context.getPersistenceManagerAs(PersistenceManager) orelse return mcp.tools.ToolError.ExecutionFailed;

    const snaps = pm.listSnapshots(allocator) catch return mcp.tools.ToolError.ExecutionFailed;
    defer {
        for (snaps) |s| allocator.free(s);
        allocator.free(snaps);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "Snapshots: [") catch return mcp.tools.ToolError.ExecutionFailed;
    for (snaps, 0..) |s, i| {
        if (i > 0) buf.appendSlice(allocator, ", ") catch return mcp.tools.ToolError.ExecutionFailed;
        buf.appendSlice(allocator, s) catch return mcp.tools.ToolError.ExecutionFailed;
    }
    buf.append(allocator, ']') catch return mcp.tools.ToolError.ExecutionFailed;

    const msg = buf.toOwnedSlice(allocator) catch return mcp.tools.ToolError.ExecutionFailed;

    return mcp.tools.ToolResult{
        .is_error = false,
        .content = &.{.{ .text = .{ .text = msg } }},
    };
}

test "handler returns empty snapshot list when no snapshots exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    const result = try handler(allocator, null);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("Snapshots: []", result.content[0].text.text);
}

test "handler lists saved snapshots by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    // Create a snapshot file so listSnapshots can find it
    try tmp.dir.writeFile(.{ .sub_path = "alpha.pl", .data = "" });

    const result = try handler(allocator, null);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "alpha") != null);
}

test "handler returns ExecutionFailed when no persistence manager is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearPersistenceManager();

    const result = handler(allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
