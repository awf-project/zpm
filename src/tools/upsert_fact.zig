const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const wal = @import("../persistence/wal.zig");
const JournalEntry = wal.JournalEntry;

pub const tool = mcp.tools.Tool{
    .name = "upsert_fact",
    .description = "Insert or replace a Prolog fact in the knowledge base. Retracts all existing clauses matching the same functor and first argument, then asserts the new fact. Succeeds even if no prior fact exists.",
    .annotations = .{
        .readOnlyHint = false,
        .destructiveHint = true,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;

    if (std.mem.indexOf(u8, fact, ":-") != null) {
        return mcp.tools.errorResult(allocator, "fact must not contain rule syntax") catch return mcp.tools.ToolError.OutOfMemory;
    }

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const pattern = buildUpsertPattern(allocator, fact) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(pattern);

    engine.retractAll(pattern) catch return mcp.tools.ToolError.ExecutionFailed;
    engine.assertFact(fact) catch return mcp.tools.ToolError.ExecutionFailed;

    if (context.getPersistenceManagerAs(PersistenceManager)) |pm| {
        const ts = std.time.timestamp();
        pm.journalMutation(JournalEntry{ .timestamp = ts, .op = .retractall, .clause = pattern }) catch {};
        pm.journalMutation(JournalEntry{ .timestamp = ts, .clause = fact }) catch {};
    }

    const msg = std.fmt.allocPrint(allocator, "Upserted: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

// Build a retractAll pattern matching same functor and first argument.
// "foo(a, b, c)" -> "foo(a, _, _)"
// "foo(a)"       -> "foo(a)"
// "atom"         -> "atom"
fn buildUpsertPattern(allocator: std.mem.Allocator, fact: []const u8) ![]const u8 {
    var stripped = std.mem.trimRight(u8, fact, " \t\n\r");
    if (stripped.len > 0 and stripped[stripped.len - 1] == '.') stripped = stripped[0 .. stripped.len - 1];

    const paren_pos = std.mem.indexOf(u8, stripped, "(") orelse {
        return allocator.dupe(u8, stripped);
    };

    var depth: usize = 0;
    var first_comma: ?usize = null;
    var arity: usize = 1;
    var i: usize = paren_pos;
    while (i < stripped.len) : (i += 1) {
        switch (stripped[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) break;
            },
            ',' => if (depth == 1) {
                if (first_comma == null) first_comma = i;
                arity += 1;
            },
            else => {},
        }
    }

    const sep = first_comma orelse return allocator.dupe(u8, stripped);

    var pattern: std.ArrayList(u8) = .empty;
    errdefer pattern.deinit(allocator);
    try pattern.appendSlice(allocator, stripped[0..sep]);
    for (1..arity) |_| {
        try pattern.appendSlice(allocator, ", _");
    }
    try pattern.append(allocator, ')');
    return pattern.toOwnedSlice(allocator);
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler inserts fact when no prior matching fact exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deploy_status(app1, running)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    var qr = try engine.query("deploy_status(app1, X).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "handler replaces existing fact with same functor and first argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("deploy_status(app1, running).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deploy_status(app1, stopped)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    var qr = try engine.query("deploy_status(app1, X).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when fact contains rule syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deploy_status(app1, X) :- active(X)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deploy_status(app1, running)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler journals retractAll pattern and new fact as atomic group to WAL" {
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
    try obj.put("fact", .{ .string = "deploy_status(app1, running)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [2048]u8 = undefined;
    const content = try tmp.dir.readFile("journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "deploy_status(app1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "deploy_status(app1, running)") != null);
}
