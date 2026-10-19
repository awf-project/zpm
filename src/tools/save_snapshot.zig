const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "name", "The name for the snapshot file", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "save_snapshot",
        .description = "Persist the current Prolog knowledge base to a named snapshot file",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"name"},
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
    const name = mcp.tools.getString(args, "name") orelse return mcp.tools.ToolError.InvalidArguments;

    const memory_name = context.resolveMemoryName(args);
    const engine = context.getEngineForMemory(memory_name) orelse return mcp.tools.ToolError.ExecutionFailed;

    const target_pm = context.resolvePersistenceManager(memory_name) orelse
        return mcp.tools.ToolError.ExecutionFailed;

    target_pm.saveSnapshot(engine, name) catch return mcp.tools.ToolError.ExecutionFailed;

    const msg = std.fmt.allocPrint(allocator, "Snapshot '{s}' saved successfully.", .{name}) catch
        return mcp.tools.ToolError.ExecutionFailed;
    defer allocator.free(msg);

    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "save_snapshot tool retains existing parameters and additionally advertises optional memory" {
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
    try std.testing.expectEqualStrings("The name for the snapshot file", name_object.get("description").?.string);
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

test "handler saves snapshot and returns confirmation when engine and persistence manager are active" {
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
    try obj.put(allocator, "name", .{ .string = "test_snap" });
    try obj.put(allocator, "memory", .{ .string = "default" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "test_snap") != null);
}

test "handler saves named-memory snapshot through that memory persistence manager" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "named", .default_dir);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const default_dir = path_buf[0..default_len];
    const named_len = try tmp.dir.realPathFile(std.testing.io, "named", &path_buf);
    const named_dir = path_buf[0..named_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var default_pm = try PersistenceManager.init(std.testing.allocator, default_dir, default_dir, std.testing.io);
    defer default_pm.deinit();
    context.setPersistenceManager(&default_pm);
    defer context.clearPersistenceManager();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("snapshot_memory", named_dir, .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "named_snap" });
    try obj.put(allocator, "memory", .{ .string = "snapshot_memory" });
    const args = std.json.Value{ .object = obj };
    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    _ = try tmp.dir.statFile(std.testing.io, "named/named_snap.pl", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "named_snap.pl", .{}));
}

test "handler returns ExecutionFailed for unavailable named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "missing_snap" });
    try obj.put(allocator, "memory", .{ .string = "missing_memory" });
    const args = std.json.Value{ .object = obj };

    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, handler(null, std.testing.io, allocator, args));
}

test "handler returns ExecutionFailed when default persistence manager is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();
    context.clearPersistenceManager();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "no_manager_snap" });
    try obj.put(allocator, "memory", .{ .string = "default" });
    const args = std.json.Value{ .object = obj };

    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, handler(null, std.testing.io, allocator, args));
}

test "handler creates snapshot file on disk" {
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
    try obj.put(allocator, "name", .{ .string = "disk_snap" });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);

    _ = try tmp.dir.statFile(std.testing.io, "disk_snap.pl", .{});
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
