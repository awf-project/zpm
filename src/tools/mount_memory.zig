const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const mem_registry = @import("../memory/registry.zig");
const MemoryRegistry = mem_registry.MemoryRegistry;
const MemoryMode = mem_registry.MemoryMode;
const MemoryScope = mem_registry.MemoryScope;
const Engine = @import("../prolog/engine.zig").Engine;
const manifest_mod = @import("../mounts/manifest.zig");
const MountManifest = manifest_mod.MountManifest;
const parseScope = manifest_mod.parseScope;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("name", "Memory name to mount", true);
    _ = try schema.addString("mode", "Mount mode: rw or ro (default: rw)", false);
    _ = try schema.addString("scope", "Memory scope: \"project\" or \"global\" (default: \"project\")", false);
    const built = try schema.build();

    return .{
        .name = "mount_memory",
        .description = "Mount an existing named memory module into the active engine",
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

/// Read-only global path resolution: returns `{base}/zpm/kb/{name}` without
/// creating any directory. Used by mount_memory to locate an EXISTING global
/// memory; create_memory has its own resolver that creates dirs.
fn resolveGlobalPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const base = blk: {
        if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
            if (xdg.len > 0) break :blk try allocator.dupe(u8, xdg);
        }
        if (std.posix.getenv("HOME")) |home| {
            break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share", .{home});
        }
        return error.HomeNotSet;
    };
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/zpm/kb/{s}", .{ base, name });
}

fn writeManifestEntry(
    allocator: std.mem.Allocator,
    manifest: *MountManifest,
    name: []const u8,
    disk_path: []const u8,
    scope: MemoryScope,
    mode: MemoryMode,
) mcp.tools.ToolError!void {
    const path = switch (scope) {
        .project => try std.fmt.allocPrint(allocator, ".zpm/kb/{s}", .{name}),
        .global => try allocator.dupe(u8, disk_path),
    };
    defer allocator.free(path);

    manifest.addEntry(.{
        .name = name,
        .path = path,
        .scope = scope,
        .mode = mode,
    }) catch |err| switch (err) {
        error.OutOfMemory => return mcp.tools.ToolError.OutOfMemory,
        else => return mcp.tools.ToolError.ExecutionFailed,
    };

    manifest.write() catch return mcp.tools.ToolError.ExecutionFailed;
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse return mcp.tools.ToolError.InvalidArguments;
    const mode_str = mcp.tools.getString(args, "mode") orelse "rw";
    const mode: MemoryMode = if (std.mem.eql(u8, mode_str, "ro")) .ro else .rw;

    const scope_str = mcp.tools.getString(args, "scope") orelse "project";
    const scope = parseScope(scope_str) orelse {
        const msg = std.fmt.allocPrint(allocator, "Invalid scope: {s}", .{scope_str}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    const reg = context.getMemoryRegistryAs(MemoryRegistry) orelse return mcp.tools.ToolError.ExecutionFailed;
    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const disk_path = switch (scope) {
        .project => blk: {
            const kb = context.getKbDir() orelse return mcp.tools.ToolError.ExecutionFailed;
            break :blk std.fmt.allocPrint(allocator, "{s}/{s}", .{ kb, name }) catch return mcp.tools.ToolError.OutOfMemory;
        },
        .global => resolveGlobalPath(allocator, name) catch return mcp.tools.ToolError.ExecutionFailed,
    };
    defer allocator.free(disk_path);

    std.fs.accessAbsolute(disk_path, .{}) catch {
        const msg = std.fmt.allocPrint(allocator, "Memory directory not found: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    reg.mount(name, disk_path, scope, mode, engine) catch |err| {
        const msg = switch (err) {
            error.AlreadyMounted => std.fmt.allocPrint(allocator, "Memory already mounted: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory,
            else => std.fmt.allocPrint(allocator, "Failed to mount memory: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory,
        };
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (context.getMountManifestAs(MountManifest)) |manifest| {
        writeManifestEntry(allocator, manifest, name, disk_path, scope, mode) catch |err| {
            reg.unmount(name) catch {};
            return err;
        };
    }

    const msg = std.fmt.allocPrint(allocator, "Memory mounted: {s} ({s})", .{ name, mode_str }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "mount_memory tool returns correct structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    try std.testing.expectEqualStrings("mount_memory", t.name);
}

test "mount_memory handler with valid name mounts memory" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    try tmp.dir.makeDir("mount_mem");
    var sub = try tmp.dir.openDir("mount_mem", .{});
    defer sub.close();
    var kf = try sub.createFile("knowledge.pl", .{});
    defer kf.close();
    try kf.writeAll(":- module(mount_mem, []).\n");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "mount_mem" });
    try obj.put("mode", .{ .string = "rw" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
}

test "mount_memory handler returns error for already-mounted memory" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    try tmp.dir.makeDir("dup_mem");
    var sub = try tmp.dir.openDir("dup_mem", .{});
    defer sub.close();
    var kf = try sub.createFile("knowledge.pl", .{});
    defer kf.close();
    try kf.writeAll(":- module(dup_mem, []).\n");

    try registry.mount("dup_mem", try std.fmt.allocPrint(allocator, "{s}/dup_mem", .{dir_path}), .project, .rw, engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "dup_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "mount_memory handler returns error for non-existent memory" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "nonexistent_memory" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "mount_memory handler with null args returns InvalidArguments" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "mount_memory handler with missing name returns InvalidArguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "mount_memory handler returns ExecutionFailed when registry unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearMemoryRegistry();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "test_memory" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "mount_memory handler writes entry to manifest with the supplied mode" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    var manifest_path_buf: [std.fs.max_path_bytes + 20]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/mounts.json", .{dir_path});
    var manifest = try MountManifest.init(std.testing.allocator, manifest_path);
    defer manifest.deinit();
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    try tmp.dir.makeDir("mani_mem");
    var sub = try tmp.dir.openDir("mani_mem", .{});
    defer sub.close();
    var kf = try sub.createFile("knowledge.pl", .{});
    defer kf.close();
    try kf.writeAll(":- module(mani_mem, []).\n");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "mani_mem" });
    try obj.put("mode", .{ .string = "rw" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);
    const entry = manifest.findEntry("mani_mem");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryMode.rw, entry.?.mode);
}

test "mount_memory handler with mode=ro persists mode=ro in the manifest entry" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    var manifest_path_buf: [std.fs.max_path_bytes + 20]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/mounts.json", .{dir_path});
    var manifest = try MountManifest.init(std.testing.allocator, manifest_path);
    defer manifest.deinit();
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    try tmp.dir.makeDir("mani_ro_mem");
    var sub = try tmp.dir.openDir("mani_ro_mem", .{});
    defer sub.close();
    var kf = try sub.createFile("knowledge.pl", .{});
    defer kf.close();
    try kf.writeAll(":- module(mani_ro_mem, []).\n");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "mani_ro_mem" });
    try obj.put("mode", .{ .string = "ro" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
    const entry = manifest.findEntry("mani_ro_mem");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryMode.ro, entry.?.mode);
}

test "mount_memory handler re-mounting an already-manifest-listed memory updates mode and does NOT duplicate" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    var manifest_path_buf: [std.fs.max_path_bytes + 20]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/mounts.json", .{dir_path});
    var manifest = try MountManifest.init(std.testing.allocator, manifest_path);
    defer manifest.deinit();

    try manifest.addEntry(.{
        .name = "dup_mani",
        .path = ".zpm/kb/dup_mani",
        .scope = .project,
        .mode = .rw,
    });
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    try tmp.dir.makeDir("dup_mani");
    var sub = try tmp.dir.openDir("dup_mani", .{});
    defer sub.close();
    var kf = try sub.createFile("knowledge.pl", .{});
    defer kf.close();
    try kf.writeAll(":- module(dup_mani, []).\n");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "dup_mani" });
    try obj.put("mode", .{ .string = "ro" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);
    const entry = manifest.findEntry("dup_mani");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryMode.ro, entry.?.mode);
}

test "mount_memory handler with no manifest in context succeeds without writing manifest" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();
    context.clearMountManifest();

    try tmp.dir.makeDir("no_mani_mem");
    var sub = try tmp.dir.openDir("no_mani_mem", .{});
    defer sub.close();
    var kf = try sub.createFile("knowledge.pl", .{});
    defer kf.close();
    try kf.writeAll(":- module(no_mani_mem, []).\n");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "no_mani_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
}

// libc env mutators; std.c does not expose them in Zig 0.15.x but we link libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "mount_memory handler with scope=global resolves path under XDG_DATA_HOME and stores absolute path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    // Pre-create the global memory layout under the synthetic XDG_DATA_HOME
    try tmp.dir.makePath("zpm/kb/glob_mem");
    var glob_sub = try tmp.dir.openDir("zpm/kb/glob_mem", .{});
    defer glob_sub.close();
    var glob_kf = try glob_sub.createFile("knowledge.pl", .{});
    defer glob_kf.close();
    try glob_kf.writeAll(":- module(glob_mem, []).\n");

    const xdg_c = try allocator.dupeZ(u8, dir_path);
    _ = setenv("XDG_DATA_HOME", xdg_c.ptr, 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    var manifest_path_buf: [std.fs.max_path_bytes + 20]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/mounts.json", .{dir_path});
    var manifest = try MountManifest.init(std.testing.allocator, manifest_path);
    defer manifest.deinit();
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "glob_mem" });
    try obj.put("scope", .{ .string = "global" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    const entry = manifest.findEntry("glob_mem");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryScope.global, entry.?.scope);
    // Path stored is absolute (under the synthetic XDG_DATA_HOME)
    try std.testing.expect(std.mem.startsWith(u8, entry.?.path, dir_path));
    try std.testing.expect(std.mem.endsWith(u8, entry.?.path, "/zpm/kb/glob_mem"));
}

test "mount_memory handler with scope=global returns error when global directory does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    // Synthetic XDG_DATA_HOME with NO zpm/kb/<name> created — accessAbsolute should fail
    const xdg_c = try allocator.dupeZ(u8, dir_path);
    _ = setenv("XDG_DATA_HOME", xdg_c.ptr, 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();
    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "absent_global" });
    try obj.put("scope", .{ .string = "global" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "mount_memory handler with unknown scope returns error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "any" });
    try obj.put("scope", .{ .string = "bogus" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}
