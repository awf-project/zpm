const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "list_snapshots",
        .description = "List all available Prolog knowledge base snapshots",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{},
        },
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const memory_name = context.resolveMemoryName(args);
    const reg = context.getMemoryRegistryAs(MemoryRegistry);
    var target_pm: ?*PersistenceManager = null;
    if (reg) |r| {
        // See `context.default_memory_name` for the bypass rationale.
        if (!context.isDefaultMemory(memory_name)) {
            if (r.getMounted(memory_name)) |entry| target_pm = &entry.pm;
        }
    }
    if (target_pm == null) target_pm = context.getPersistenceManagerAs(PersistenceManager);
    if (target_pm == null) return mcp.tools.ToolError.ExecutionFailed;

    const snaps = target_pm.?.listSnapshots(allocator) catch return mcp.tools.ToolError.ExecutionFailed;
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

    return mcp.tools.textResult(allocator, buf.items) catch return mcp.tools.ToolError.OutOfMemory;
}

test "list_snapshots tool is an allocator-backed builder with optional string memory and exact description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const built_tool = try tool(arena.allocator());
    const schema = built_tool.inputSchema orelse return error.MissingSchema;
    const properties = schema.properties orelse return error.MissingProperties;
    const properties_object = switch (properties) {
        .object => |object| object,
        else => return error.UnexpectedPropertiesType,
    };
    const memory = properties_object.get("memory") orelse return error.MissingMemoryProperty;
    const memory_object = switch (memory) {
        .object => |object| object,
        else => return error.UnexpectedMemoryPropertyType,
    };

    try std.testing.expectEqualStrings("list_snapshots", built_tool.name);
    try std.testing.expectEqualStrings("string", memory_object.get("type").?.string);
    try std.testing.expectEqualStrings(
        "Target memory segment (optional, defaults to default memory)",
        memory_object.get("description").?.string,
    );
    for (schema.required orelse &.{}) |required| {
        try std.testing.expect(!std.mem.eql(u8, required, "memory"));
    }
}

test "handler returns empty snapshot list when no snapshots exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    const result = try handler(null, std.testing.io, allocator, null);
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
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    // Create a snapshot file so listSnapshots can find it
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "alpha.pl", .data = "" });

    const result = try handler(null, std.testing.io, allocator, null);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "alpha") != null);
}

test "handler lists snapshots from the explicitly named memory persistence manager" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "named", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "default_only.pl", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "named/named_only.pl", .data = "" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    var default_pm = try PersistenceManager.init(std.testing.allocator, path_buf[0..default_len], path_buf[0..default_len], std.testing.io);
    defer default_pm.deinit();
    context.setPersistenceManager(&default_pm);
    defer context.clearPersistenceManager();

    const named_len = try tmp.dir.realPathFile(std.testing.io, "named", &path_buf);
    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("snapshot_memory", path_buf[0..named_len], .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "snapshot_memory" });
    const result = try handler(null, std.testing.io, allocator, .{ .object = obj });

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "named_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "default_only") == null);
}

test "handler falls back to the default persistence manager for an unknown memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "named", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "default_only.pl", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "named/named_only.pl", .data = "" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const default_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    var default_pm = try PersistenceManager.init(std.testing.allocator, path_buf[0..default_len], path_buf[0..default_len], std.testing.io);
    defer default_pm.deinit();
    context.setPersistenceManager(&default_pm);
    defer context.clearPersistenceManager();

    const named_len = try tmp.dir.realPathFile(std.testing.io, "named", &path_buf);
    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("snapshot_memory", path_buf[0..named_len], .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "unknown_memory" });
    const result = try handler(null, std.testing.io, allocator, .{ .object = obj });

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "default_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "named_only") == null);
}

test "handler returns ExecutionFailed when no persistence manager is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearPersistenceManager();

    const result = handler(null, std.testing.io, allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
