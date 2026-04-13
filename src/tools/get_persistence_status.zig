const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;

pub const tool = mcp.tools.Tool{
    .name = "get_persistence_status",
    .description = "Query the health and status of the persistence subsystem",
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

    const status_str = switch (pm.getStatus()) {
        .active => "active",
        .degraded => "degraded",
        .disabled => "disabled",
    };

    const journal_size = blk: {
        var dir = std.fs.openDirAbsolute(pm.dir_path, .{}) catch break :blk @as(u64, 0);
        defer dir.close();
        const stat = dir.statFile("journal.wal") catch break :blk @as(u64, 0);
        break :blk stat.size;
    };

    const snaps = pm.listSnapshots(allocator) catch null;
    defer if (snaps) |s| {
        for (s) |item| allocator.free(item);
        allocator.free(s);
    };
    const last_snap: []const u8 = if (snaps) |s| (if (s.len > 0) s[s.len - 1] else "none") else "none";

    const msg = std.fmt.allocPrint(allocator, "status: {s}\ndir: {s}\nlast_snapshot: {s}\njournal_size: {d} bytes", .{
        status_str, pm.dir_path, last_snap, journal_size,
    }) catch return mcp.tools.ToolError.ExecutionFailed;

    return mcp.tools.ToolResult{
        .is_error = false,
        .content = &.{.{ .text = .{ .text = msg } }},
    };
}

const Engine = @import("../prolog/engine.zig").Engine;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;

test "handler returns status report with key fields when persistence manager is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    const result = try handler(allocator, null);
    try std.testing.expect(!result.is_error);

    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "active") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, dir_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "none") != null);
}

test "handler reports non-zero journal size after entries are written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path);
    defer pm.deinit();

    try pm.journalMutation(JournalEntry{ .timestamp = 1713000000, .clause = "fact(status_test)" });
    try pm.journalMutation(JournalEntry{ .timestamp = 1713000001, .clause = "fact(status_test2)" });

    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    const result = try handler(allocator, null);
    try std.testing.expect(!result.is_error);

    const text = result.content[0].text.text;
    // Response must NOT report "0 bytes" or "0 entries" — journal has data
    try std.testing.expect(std.mem.indexOf(u8, text, "0 bytes") == null);
}

test "handler returns ExecutionFailed when no persistence manager is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearPersistenceManager();

    const result = handler(allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
