const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "name", "The name of the snapshot to restore", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "restore_snapshot",
        .description = "Restore the Prolog knowledge base from a named snapshot file",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"name"},
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
    const name = mcp.tools.getString(args, "name") orelse return mcp.tools.ToolError.InvalidArguments;

    const memory_name = context.resolveMemoryName(args);
    const engine = context.getEngineForMemory(memory_name) orelse return mcp.tools.ToolError.ExecutionFailed;

    const target_pm = context.resolvePersistenceManager(memory_name) orelse
        return mcp.tools.ToolError.ExecutionFailed;

    target_pm.restoreSnapshot(engine, name) catch return mcp.tools.ToolError.ExecutionFailed;

    const msg = std.fmt.allocPrint(allocator, "Snapshot '{s}' restored successfully.", .{name}) catch
        return mcp.tools.ToolError.ExecutionFailed;
    defer allocator.free(msg);

    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

test "restore_snapshot tool preserves existing parameters and adds optional string memory with exact description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const built_tool = try tool(arena.allocator());
    const schema = built_tool.inputSchema orelse return error.MissingSchema;
    const properties = schema.properties orelse return error.MissingProperties;
    const properties_object = switch (properties) {
        .object => |object| object,
        else => return error.UnexpectedPropertiesType,
    };
    const name = properties_object.get("name") orelse return error.MissingNameProperty;
    const memory = properties_object.get("memory") orelse return error.MissingMemoryProperty;
    const name_object = switch (name) {
        .object => |object| object,
        else => return error.UnexpectedNamePropertyType,
    };
    const memory_object = switch (memory) {
        .object => |object| object,
        else => return error.UnexpectedMemoryPropertyType,
    };

    try std.testing.expectEqualStrings("string", name_object.get("type").?.string);
    try std.testing.expectEqualStrings("The name of the snapshot to restore", name_object.get("description").?.string);
    try std.testing.expectEqualStrings("string", memory_object.get("type").?.string);
    try std.testing.expectEqualStrings(
        "Target memory segment (optional, defaults to default memory)",
        memory_object.get("description").?.string,
    );
    const required = schema.required orelse return error.MissingRequiredProperties;
    try std.testing.expectEqual(@as(usize, 1), required.len);
    try std.testing.expectEqualStrings("name", required[0]);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when name key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler restores snapshot and returns confirmation when snapshot exists" {
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

    try pm.saveSnapshot(engine, "restore_test");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "restore_test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "restore_test") != null);
}

test "handler restores snapshot through the explicitly named memory persistence manager" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "named", .default_dir);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const named_len = try tmp.dir.realPathFile(std.testing.io, "named", &path_buf);

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("snapshot_memory", path_buf[0..named_len], .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    const entry = registry.getMounted("snapshot_memory").?;
    try entry.engine.assertFact("before_restore(value)");
    try entry.pm.saveSnapshot(entry.engine, "named_restore");
    try entry.engine.assertFact("after_restore(value)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "named_restore" });
    try obj.put(allocator, "memory", .{ .string = "snapshot_memory" });
    const result = try handler(null, std.testing.io, allocator, .{ .object = obj });

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "named_restore") != null);
}

test "handler returns ExecutionFailed when no engine is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "no_engine_snap" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler returns ExecutionFailed when snapshot file does not exist" {
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
    try obj.put(allocator, "name", .{ .string = "nonexistent_snap" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler returns ExecutionFailed when snapshot file is malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "malformed_snap.pl", .data = "bad(unclosed\n" });

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "malformed_snap" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
