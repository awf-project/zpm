const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;
const Engine = @import("../prolog/engine.zig").Engine;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("fact", "A Prolog fact to assert (e.g. 'parent(tom, bob)')", true);
    _ = try schema.addString("memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build();

    return .{
        .name = "remember_fact",
        .description = "Assert a Prolog fact into the knowledge base",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"fact"},
        },
        .annotations = .{
            .readOnlyHint = false,
            .destructiveHint = false,
            .idempotentHint = false,
        },
        .handler = handler,
    };
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;
    if (fact.len == 0) return mcp.tools.errorResult(allocator, "Fact must not be empty") catch return mcp.tools.ToolError.OutOfMemory;

    const mem = switch (try context.resolveWritableMemory(allocator, args)) {
        .tool_result => |r| return r,
        .resolved => |m| m,
    };
    const memory_name = mem.memory_name;
    const target_pm = mem.pm;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const qualified = context.qualifyClause(allocator, memory_name, fact) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(qualified);

    engine.assertFact(qualified) catch {
        const msg = std.fmt.allocPrint(allocator, "Failed to assert: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (target_pm) |pm| {
        pm.journalMutation(JournalEntry{ .timestamp = std.time.timestamp(), .clause = qualified }) catch return mcp.tools.ToolError.ExecutionFailed;
    }
    if (std.fmt.allocPrint(allocator, "zpm_source({s}, interactive).", .{fact}) catch null) |sc| {
        defer allocator.free(sc);
        engine.assertFact(sc) catch {};
    }
    const msg = std.fmt.allocPrint(allocator, "Asserted: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "handler asserts valid fact and returns confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "user_prefers(dark_mode)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "user_prefers(dark_mode)") != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when fact key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when fact is empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler journals mutation to WAL when persistence manager is active" {
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
    try obj.put("fact", .{ .string = "logged(event)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [1024]u8 = undefined;
    const content = try tmp.dir.readFile("journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "logged(event)") != null);
}

test "handler asserts zpm_source interactive attribution alongside fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "feature_enabled(dark_mode)" });
    const args = std.json.Value{ .object = obj };

    _ = try handler(allocator, args);

    var qr = try engine.query("zpm_source(feature_enabled(dark_mode), S)");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
    const s_term = qr.solutions[0].bindings.get("S") orelse return error.TestUnexpectedNull;
    const source = switch (s_term) {
        .atom => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("interactive", source);
}

test "handler returns ExecutionFailed when journal write fails" {
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

    // Swap the WAL fd for a read-only /dev/null so writeAll fails.
    if (pm.wal) |*w| {
        w.file.close();
        w.file = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .read_only });
    }

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "journal_fail_fact(x)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);

    // The engine assertion succeeded before the journal write failed, so the
    // fact is present in the engine (safe data loss on restart, not corruption).
    var qr = try engine.query("journal_fail_fact(x).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "handler returns error result for invalid Prolog syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "not_valid_prolog(((" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(result.is_error);
}

test "remember_fact.handler with named memory asserts qualified fact and journals to memory PM" {
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

    const feature_path = try std.fmt.allocPrint(allocator, "{s}/feature_auth", .{dir_path});
    defer allocator.free(feature_path);
    try std.fs.makeDirAbsolute(feature_path);

    var feature_dir = try std.fs.openDirAbsolute(feature_path, .{});
    defer feature_dir.close();
    var kfile = try feature_dir.createFile("knowledge.pl", .{});
    defer kfile.close();
    try kfile.writeAll(":- module(feature_auth, []).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("feature_auth", feature_path, .project, .rw, engine);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "enabled(darkmode)" });
    try obj.put("memory", .{ .string = "feature_auth" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    var qr = try engine.query("feature_auth:enabled(darkmode).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);

    var jcontent_buf: [2048]u8 = undefined;
    const jcontent = try tmp.dir.readFile("feature_auth/journal.wal", &jcontent_buf);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "feature_auth:enabled(darkmode)") != null);
}

test "remember_fact.handler without memory param asserts unqualified fact and journals to default PM" {
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

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "user_preference(theme, light)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    var qr = try engine.query("user_preference(theme, light).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);

    var jcontent_buf: [1024]u8 = undefined;
    const jcontent = try tmp.dir.readFile("journal.wal", &jcontent_buf);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "user_preference(theme, light)") != null);
}

test "remember_fact.handler with read-only memory returns error with read-only message" {
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

    const ro_path = try std.fmt.allocPrint(allocator, "{s}/ro_mem", .{dir_path});
    defer allocator.free(ro_path);
    try std.fs.makeDirAbsolute(ro_path);

    var ro_dir = try std.fs.openDirAbsolute(ro_path, .{});
    defer ro_dir.close();
    var kfile = try ro_dir.createFile("knowledge.pl", .{});
    defer kfile.close();
    try kfile.writeAll(":- module(ro_mem, []).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("ro_mem", ro_path, .project, .ro, engine);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("fact", .{ .string = "protected(data)" });
    try obj.put("memory", .{ .string = "ro_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "read-only") != null);
}
