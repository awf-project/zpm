const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;
const MountManifest = @import("../mounts/manifest.zig").MountManifest;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "name", "Memory name to unmount", true);
    const built = try schema.build(allocator);

    return .{
        .name = "unmount_memory",
        .description = "Unmount a named memory module from the active engine",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"name"},
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
    const name = mcp.tools.getString(args, "name") orelse return mcp.tools.ToolError.InvalidArguments;

    const reg = context.getMemoryRegistryAs(MemoryRegistry) orelse return mcp.tools.ToolError.ExecutionFailed;

    reg.unmount(name) catch |err| switch (err) {
        error.NotMounted => {
            const msg = std.fmt.allocPrint(allocator, "Memory not mounted: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory;
            return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
        },
        error.DefaultProtected => {
            return mcp.tools.errorResult(allocator, "Cannot unmount the default memory") catch return mcp.tools.ToolError.OutOfMemory;
        },
        // The remaining MemoryError variants are never returned by unmount().
        error.NotFound,
        error.AlreadyMounted,
        error.AlreadyExists,
        error.ReadOnly,
        error.Ambiguous,
        error.InvalidName,
        => return mcp.tools.ToolError.ExecutionFailed,
    };

    if (context.getMountManifestAs(MountManifest)) |manifest| {
        manifest.removeEntry(name);
        manifest.write() catch return mcp.tools.ToolError.ExecutionFailed;
    }

    const msg = std.fmt.allocPrint(allocator, "Memory unmounted: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "unmount_memory tool returns correct structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    try std.testing.expectEqualStrings("unmount_memory", t.name);
}

test "unmount_memory handler unmounts mounted memory" {
    const Engine = @import("../prolog/engine.zig").Engine;

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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.mount("mounted_memory", dir_path, .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "mounted_memory" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "unmount_memory handler returns error when unmounting default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "default" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "unmount_memory handler returns error for non-mounted memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "not_mounted" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "unmount_memory handler with null args returns InvalidArguments" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "unmount_memory handler with missing name returns InvalidArguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "unmount_memory handler returns ExecutionFailed when registry unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "test_memory" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "unmount_memory handler removes entry from manifest on success" {
    const Engine = @import("../prolog/engine.zig").Engine;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const manifest_path = try std.fs.path.join(allocator, &.{ dir_path, "mounts.json" });

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.mount("test_mem", dir_path, .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var manifest = try MountManifest.init(std.testing.io, std.testing.allocator, manifest_path);
    defer manifest.deinit();
    try manifest.addEntry(.{
        .name = "test_mem",
        .path = dir_path,
        .scope = .project,
        .mode = .rw,
    });
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "test_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 0), manifest.entries.items.len);
}

test "unmount_memory handler with no manifest in context succeeds without writing manifest" {
    const Engine = @import("../prolog/engine.zig").Engine;

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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.mount("test_mem", dir_path, .project, .rw, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    context.clearMountManifest();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "test_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "unmount_memory of default still fails with DefaultProtected and manifest is unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var manifest = try MountManifest.init(std.testing.io, std.testing.allocator, "/tmp/nonexistent/mounts.json");
    defer manifest.deinit();
    try manifest.addEntry(.{
        .name = "default",
        .path = "/tmp/default",
        .scope = .project,
        .mode = .rw,
    });
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "default" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);
    try std.testing.expectEqualStrings("default", manifest.entries.items[0].name);
}
