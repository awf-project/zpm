const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("fact", "The Prolog fact to assert under the assumption", true);
    _ = try schema.addString("assumption", "The assumption name (lowercase, alphanumeric with underscores)", true);
    const built = try schema.build();

    return .{
        .name = "assume_fact",
        .description = "Assert a Prolog fact under a named assumption for truth maintenance tracking",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{ "fact", "assumption" },
        },
        .annotations = .{
            .readOnlyHint = false,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;
    const assumption = mcp.tools.getString(args, "assumption") orelse return mcp.tools.ToolError.InvalidArguments;

    if (assumption.len == 0 or !std.ascii.isLower(assumption[0])) return mcp.tools.ToolError.InvalidArguments;
    for (assumption[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return mcp.tools.ToolError.InvalidArguments;
    }

    if (fact.len == 0) {
        return mcp.tools.errorResult(allocator, "assume_fact: fact must not be empty") catch return mcp.tools.ToolError.OutOfMemory;
    }
    if (std.mem.indexOf(u8, fact, ":-") != null) {
        return mcp.tools.errorResult(allocator, "assume_fact: fact must not contain rule syntax") catch return mcp.tools.ToolError.OutOfMemory;
    }

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    engine.assertFact(fact) catch {
        const msg = std.fmt.allocPrint(allocator, "assume_fact: failed to assert fact: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    const justification = std.fmt.allocPrint(allocator, "tms_justification({s}, {s})", .{ fact, assumption }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(justification);

    const already_justified = blk: {
        var qr = engine.query(justification) catch break :blk false;
        defer qr.deinit();
        break :blk qr.solutions.len > 0;
    };

    if (!already_justified) {
        engine.assertFact(justification) catch return mcp.tools.ToolError.ExecutionFailed;
    }

    if (context.getPersistenceManagerAs(PersistenceManager)) |pm| {
        const ts = std.time.timestamp();
        pm.journalMutation(JournalEntry{ .timestamp = ts, .clause = fact }) catch {};
        pm.journalMutation(JournalEntry{ .timestamp = ts, .clause = justification }) catch {};
    }

    const msg = std.fmt.allocPrint(allocator, "Assumed: {s} under assumption '{s}'", .{ fact, assumption }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler asserts fact under assumption and returns confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deployed(app, prod)" });
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "deployed(app, prod)") != null);
}

test "handler is idempotent when same fact and assumption are asserted twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "active(service)" });
    try obj.put("assumption", .{ .string = "default_state" });
    const args = std.json.Value{ .object = obj };

    _ = try handler(allocator, args);
    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when fact key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when assumption key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deployed(app, prod)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when fact is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "" });
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns InvalidArguments when assumption name starts with uppercase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deployed(app, prod)" });
    try obj.put("assumption", .{ .string = "BadName" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when fact contains rule syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "foo(X) :- bar(X)" });
    try obj.put("assumption", .{ .string = "baseline" });
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
    try obj.put("fact", .{ .string = "likes(alice, bob)" });
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler journals fact and tms_justification as atomic group to WAL" {
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

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "deployed(app, prod)" });
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [2048]u8 = undefined;
    const content = try tmp.dir.readFile("journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "deployed(app, prod)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "tms_justification") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "baseline") != null);
}
