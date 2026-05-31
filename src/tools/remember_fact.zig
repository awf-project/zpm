const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;
const nowSeconds = @import("../persistence/wal.zig").nowSeconds;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;
const Engine = @import("../prolog/engine.zig").Engine;
pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "fact", "A Prolog fact to assert (e.g. 'parent(tom, bob)')", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

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

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;
    if (fact.len == 0) return mcp.tools.errorResult(allocator, "Fact must not be empty") catch return mcp.tools.ToolError.OutOfMemory;

    const mem = switch (try context.resolveWritableMemory(allocator, args)) {
        .tool_result => |r| return r,
        .resolved => |m| m,
    };
    const target_pm = mem.pm;

    const engine = mem.engine orelse return mcp.tools.ToolError.ExecutionFailed;

    engine.assertFact(fact) catch {
        const msg = std.fmt.allocPrint(allocator, "Failed to assert: {s}", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (target_pm) |pm| {
        pm.journalMutation(JournalEntry{ .timestamp = nowSeconds(), .clause = fact }) catch return mcp.tools.ToolError.ExecutionFailed;
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

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "user_prefers(dark_mode)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "user_prefers(dark_mode)") != null);
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

test "handler journals mutation to WAL when persistence manager is active" {
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
    try obj.put(allocator, "fact", .{ .string = "logged(event)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [1024]u8 = undefined;
    const content = try tmp.dir.readFile(std.testing.io, "journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "logged(event)") != null);
}

test "handler asserts zpm_source interactive attribution alongside fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "feature_enabled(dark_mode)" });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);

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

    // Swap the WAL fd for a read-only /dev/null so writeAll fails.
    if (pm.wal) |*w| {
        w.file.close(std.testing.io);
        w.file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_only });
    }

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "journal_fail_fact(x)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
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

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "not_valid_prolog(((" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(result.is_error);
}

test "remember_fact.handler with named memory asserts qualified fact and journals to memory PM" {
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

    const feature_path = try std.fmt.allocPrint(allocator, "{s}/feature_auth", .{dir_path});
    defer allocator.free(feature_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, feature_path, .default_dir);

    var feature_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, feature_path, .{});
    defer feature_dir.close(std.testing.io);
    var kfile = try feature_dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer kfile.close(std.testing.io);
    try kfile.writeStreamingAll(std.testing.io, ":- module(feature_auth, []).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("feature_auth", feature_path, .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "enabled(darkmode)" });
    try obj.put(allocator, "memory", .{ .string = "feature_auth" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    // Fact lives UNQUALIFIED in the segment's dedicated engine (B001 / #54).
    const seg = registry.getMounted("feature_auth").?;
    var qr = try seg.engine.query("enabled(darkmode).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);

    var jcontent_buf: [2048]u8 = undefined;
    const jcontent = try tmp.dir.readFile(std.testing.io, "feature_auth/journal.wal", &jcontent_buf);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "enabled(darkmode)") != null);
}

test "remember_fact.handler without memory param asserts unqualified fact and journals to default PM" {
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
    try obj.put(allocator, "fact", .{ .string = "user_preference(theme, light)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);

    var qr = try engine.query("user_preference(theme, light).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);

    var jcontent_buf: [1024]u8 = undefined;
    const jcontent = try tmp.dir.readFile(std.testing.io, "journal.wal", &jcontent_buf);
    try std.testing.expect(std.mem.indexOf(u8, jcontent, "user_preference(theme, light)") != null);
}

test "remember_fact.handler with read-only memory returns error with read-only message" {
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

    const ro_path = try std.fmt.allocPrint(allocator, "{s}/ro_mem", .{dir_path});
    defer allocator.free(ro_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, ro_path, .default_dir);

    var ro_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, ro_path, .{});
    defer ro_dir.close(std.testing.io);
    var kfile = try ro_dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer kfile.close(std.testing.io);
    try kfile.writeStreamingAll(std.testing.io, ":- module(ro_mem, []).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("ro_mem", ro_path, .project, .ro, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "protected(data)" });
    try obj.put(allocator, "memory", .{ .string = "ro_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "read-only") != null);
}
