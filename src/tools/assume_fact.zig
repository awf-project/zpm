const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;
const nowSeconds = @import("../persistence/wal.zig").nowSeconds;
const validation = @import("tool_validation");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;
const Engine = @import("../prolog/engine.zig").Engine;
pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "fact", "The Prolog fact to assert under the assumption", true);
    _ = try schema.addString(allocator, "assumption", "The assumption name (lowercase, alphanumeric with underscores)", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

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

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;
    const assumption = mcp.tools.getString(args, "assumption") orelse return mcp.tools.ToolError.InvalidArguments;

    if (!validation.isValidAtomName(assumption)) return mcp.tools.ToolError.InvalidArguments;

    if (fact.len == 0) {
        return mcp.tools.errorResult(allocator, "assume_fact: fact must not be empty") catch return mcp.tools.ToolError.OutOfMemory;
    }
    if (std.mem.indexOf(u8, fact, ":-") != null) {
        return mcp.tools.errorResult(allocator, "assume_fact: fact must not contain rule syntax") catch return mcp.tools.ToolError.OutOfMemory;
    }

    const mem = switch (try context.resolveWritableMemory(allocator, args)) {
        .tool_result => |r| return r,
        .resolved => |m| m,
    };
    const target_pm = mem.pm;

    const engine = mem.engine orelse return mcp.tools.ToolError.ExecutionFailed;

    const justification = std.fmt.allocPrint(allocator, "tms_justification({s}, {s})", .{ fact, assumption }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(justification);

    // Check idempotency first so the journal mirrors the engine ops —
    // assertz appends, so journaling unconditionally would double the
    // justification at replay time.
    const already_justified = blk: {
        var qr = engine.query(justification) catch break :blk false;
        defer qr.deinit();
        break :blk qr.solutions.len > 0;
    };

    engine.assertFact(fact) catch {
        const msg = std.fmt.allocPrint(allocator, "assume_fact: failed to assert fact: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (!already_justified) {
        engine.assertFact(justification) catch return mcp.tools.ToolError.ExecutionFailed;
    }

    if (target_pm) |pm| {
        const ts = nowSeconds();
        pm.journalMutation(JournalEntry{ .timestamp = ts, .clause = fact }) catch return mcp.tools.ToolError.ExecutionFailed;
        if (!already_justified) {
            pm.journalMutation(JournalEntry{ .timestamp = ts, .clause = justification }) catch return mcp.tools.ToolError.ExecutionFailed;
        }
    }

    const msg = std.fmt.allocPrint(allocator, "Assumed: {s} under assumption '{s}'", .{ fact, assumption }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "handler asserts fact under assumption and returns confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "deployed(app, prod)" });
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "deployed(app, prod)") != null);
}

test "handler is idempotent when same fact and assumption are asserted twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "active(service)" });
    try obj.put(allocator, "assumption", .{ .string = "default_state" });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);
    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when fact key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when assumption key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "deployed(app, prod)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when fact is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "" });
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns InvalidArguments when assumption name starts with uppercase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "deployed(app, prod)" });
    try obj.put(allocator, "assumption", .{ .string = "BadName" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when fact contains rule syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "foo(X) :- bar(X)" });
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
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
    try obj.put(allocator, "fact", .{ .string = "likes(alice, bob)" });
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler journals fact and tms_justification as atomic group to WAL" {
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
    try obj.put(allocator, "fact", .{ .string = "deployed(app, prod)" });
    try obj.put(allocator, "assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [2048]u8 = undefined;
    const content = try tmp.dir.readFile(std.testing.io, "journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "deployed(app, prod)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "tms_justification") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "baseline") != null);
}

test "assume_fact.handler with named memory asserts qualified fact and journals to memory PM" {
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

    const test_seg_path = try std.fmt.allocPrint(allocator, "{s}/test_seg", .{dir_path});
    defer allocator.free(test_seg_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, test_seg_path, .default_dir);

    var test_seg_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, test_seg_path, .{});
    defer test_seg_dir.close(std.testing.io);
    var kfile = try test_seg_dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer kfile.close(std.testing.io);
    try kfile.writeStreamingAll(std.testing.io, ":- module(test_seg, []).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("test_seg", test_seg_path, .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "assumption_test(scenario)" });
    try obj.put(allocator, "assumption", .{ .string = "test_context" });
    try obj.put(allocator, "memory", .{ .string = "test_seg" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    // The fact lives UNQUALIFIED in the segment's dedicated engine (B001 / #54).
    const seg = registry.getMounted("test_seg").?;
    var qr = try seg.engine.query("assumption_test(scenario).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);

    var jcontent_buf: [2048]u8 = undefined;
    const jcontent = try tmp.dir.readFile(std.testing.io, "test_seg/journal.wal", &jcontent_buf);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "assumption_test(scenario)") != null);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "tms_justification") != null);
}

test "assume_fact.handler without memory param asserts unqualified fact and journals to default PM" {
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

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "config_option(debug, enabled)" });
    try obj.put(allocator, "assumption", .{ .string = "user_settings" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    var qr = try engine.query("config_option(debug, enabled).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);

    var jcontent_buf: [2048]u8 = undefined;
    const jcontent = try tmp.dir.readFile(std.testing.io, "journal.wal", &jcontent_buf);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "config_option(debug, enabled)") != null);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "tms_justification") != null);
}
