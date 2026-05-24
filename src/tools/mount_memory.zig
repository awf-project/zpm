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
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "name", "Memory name to mount", true);
    _ = try schema.addString(allocator, "mode", "Mount mode: rw or ro (default: rw)", false);
    _ = try schema.addString(allocator, "scope", "Memory scope: \"project\" or \"global\" (default: \"project\")", false);
    const built = try schema.build(allocator);

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
        if (std.c.getenv("XDG_DATA_HOME")) |xdg_raw| {
            const xdg = std.mem.span(xdg_raw);
            if (xdg.len > 0) break :blk try allocator.dupe(u8, xdg);
        }
        if (std.c.getenv("HOME")) |home_raw| {
            const home = std.mem.span(home_raw);
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

pub fn handler(_: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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

    {
        var check_dir = std.Io.Dir.openDirAbsolute(io, disk_path, .{}) catch {
            const msg = std.fmt.allocPrint(allocator, "Memory directory not found: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory;
            return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
        };
        check_dir.close(io);
    }

    const already_mounted = blk: {
        reg.mount(name, disk_path, scope, mode, engine, io) catch |err| switch (err) {
            error.AlreadyMounted => break :blk true,
            else => {
                const msg = std.fmt.allocPrint(allocator, "Failed to mount memory: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory;
                return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
            },
        };
        break :blk false;
    };

    if (!already_mounted) {
        if (context.getMountManifestAs(MountManifest)) |manifest| {
            writeManifestEntry(allocator, manifest, name, disk_path, scope, mode) catch |err| {
                reg.unmount(name) catch {};
                return err;
            };
        }
    }

    // Report the *effective* mode. When already-mounted, the segment keeps its
    // original mode regardless of what the caller passed — surfacing the
    // request's mode would mislead clients into thinking they changed it.
    const effective_mode_str = if (already_mounted) blk: {
        const entry = reg.getMounted(name) orelse break :blk mode_str;
        break :blk @tagName(entry.mode);
    } else mode_str;

    const msg = std.fmt.allocPrint(allocator, "Memory mounted: {s} ({s})", .{ name, effective_mode_str }) catch return mcp.tools.ToolError.OutOfMemory;
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
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    try tmp.dir.createDir(std.testing.io, "mount_mem", .default_dir);
    var sub = try tmp.dir.openDir(std.testing.io, "mount_mem", .{});
    defer sub.close(std.testing.io);
    var kf = try sub.createFile(std.testing.io, "knowledge.pl", .{});
    defer kf.close(std.testing.io);
    try kf.writeStreamingAll(std.testing.io, ":- module(mount_mem, []).\n");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "mount_mem" });
    try obj.put(allocator, "mode", .{ .string = "rw" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "mount_memory handler is idempotent for already-mounted memory" {
    // mount_memory is idempotent: mounting an already-mounted segment returns
    // success (exit 0) instead of an error.  This matches the semantics exposed
    // by `zpm memory create` which writes a manifest entry that causes the
    // segment to be auto-mounted on the next CLI invocation; a subsequent
    // explicit `zpm memory mount` must therefore not fail.
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();
    context.clearMountManifest();

    try tmp.dir.createDir(std.testing.io, "dup_mem", .default_dir);
    var sub = try tmp.dir.openDir(std.testing.io, "dup_mem", .{});
    defer sub.close(std.testing.io);
    var kf = try sub.createFile(std.testing.io, "knowledge.pl", .{});
    defer kf.close(std.testing.io);
    try kf.writeStreamingAll(std.testing.io, ":- module(dup_mem, []).\n");

    try registry.mount("dup_mem", try std.fmt.allocPrint(allocator, "{s}/dup_mem", .{dir_path}), .project, .rw, engine, std.testing.io);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "dup_mem" });
    const args = std.json.Value{ .object = obj };

    // Second mount must succeed (idempotent), not return is_error=true.
    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "mount_memory handler returns error for non-existent memory" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "nonexistent_memory" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "mount_memory handler with null args returns InvalidArguments" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "mount_memory handler with missing name returns InvalidArguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "mount_memory handler returns ExecutionFailed when registry unavailable" {
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

test "mount_memory handler writes entry to manifest with the supplied mode" {
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

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();

    var manifest_path_buf: [std.fs.max_path_bytes + 20]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "{s}/mounts.json", .{dir_path});
    var manifest = try MountManifest.init(std.testing.io, std.testing.allocator, manifest_path);
    defer manifest.deinit();
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    try tmp.dir.createDir(std.testing.io, "mani_mem", .default_dir);
    var sub = try tmp.dir.openDir(std.testing.io, "mani_mem", .{});
    defer sub.close(std.testing.io);
    var kf = try sub.createFile(std.testing.io, "knowledge.pl", .{});
    defer kf.close(std.testing.io);
    try kf.writeStreamingAll(std.testing.io, ":- module(mani_mem, []).\n");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "mani_mem" });
    try obj.put(allocator, "mode", .{ .string = "rw" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
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
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
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
    var manifest = try MountManifest.init(std.testing.io, std.testing.allocator, manifest_path);
    defer manifest.deinit();
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    try tmp.dir.createDir(std.testing.io, "mani_ro_mem", .default_dir);
    var sub = try tmp.dir.openDir(std.testing.io, "mani_ro_mem", .{});
    defer sub.close(std.testing.io);
    var kf = try sub.createFile(std.testing.io, "knowledge.pl", .{});
    defer kf.close(std.testing.io);
    try kf.writeStreamingAll(std.testing.io, ":- module(mani_ro_mem, []).\n");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "mani_ro_mem" });
    try obj.put(allocator, "mode", .{ .string = "ro" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
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
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
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
    var manifest = try MountManifest.init(std.testing.io, std.testing.allocator, manifest_path);
    defer manifest.deinit();

    try manifest.addEntry(.{
        .name = "dup_mani",
        .path = ".zpm/kb/dup_mani",
        .scope = .project,
        .mode = .rw,
    });
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    try tmp.dir.createDir(std.testing.io, "dup_mani", .default_dir);
    var sub = try tmp.dir.openDir(std.testing.io, "dup_mani", .{});
    defer sub.close(std.testing.io);
    var kf = try sub.createFile(std.testing.io, "knowledge.pl", .{});
    defer kf.close(std.testing.io);
    try kf.writeStreamingAll(std.testing.io, ":- module(dup_mani, []).\n");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "dup_mani" });
    try obj.put(allocator, "mode", .{ .string = "ro" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
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
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
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

    try tmp.dir.createDir(std.testing.io, "no_mani_mem", .default_dir);
    var sub = try tmp.dir.openDir(std.testing.io, "no_mani_mem", .{});
    defer sub.close(std.testing.io);
    var kf = try sub.createFile(std.testing.io, "knowledge.pl", .{});
    defer kf.close(std.testing.io);
    try kf.writeStreamingAll(std.testing.io, ":- module(no_mani_mem, []).\n");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "no_mani_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
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
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Pre-create the global memory layout under the synthetic XDG_DATA_HOME
    try tmp.dir.createDirPath(std.testing.io, "zpm/kb/glob_mem");
    var glob_sub = try tmp.dir.openDir(std.testing.io, "zpm/kb/glob_mem", .{});
    defer glob_sub.close(std.testing.io);
    var glob_kf = try glob_sub.createFile(std.testing.io, "knowledge.pl", .{});
    defer glob_kf.close(std.testing.io);
    try glob_kf.writeStreamingAll(std.testing.io, ":- module(glob_mem, []).\n");

    const xdg_c = try allocator.dupeZ(u8, dir_path);
    _ = setenv("XDG_DATA_HOME", xdg_c.ptr, 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    const engine = try Engine.init(.{}, std.testing.io);
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
    var manifest = try MountManifest.init(std.testing.io, std.testing.allocator, manifest_path);
    defer manifest.deinit();
    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "glob_mem" });
    try obj.put(allocator, "scope", .{ .string = "global" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
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
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    // Synthetic XDG_DATA_HOME with NO zpm/kb/<name> created — accessAbsolute should fail
    const xdg_c = try allocator.dupeZ(u8, dir_path);
    _ = setenv("XDG_DATA_HOME", xdg_c.ptr, 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    const engine = try Engine.init(.{}, std.testing.io);
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

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "absent_global" });
    try obj.put(allocator, "scope", .{ .string = "global" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "mount_memory handler with unknown scope returns error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "name", .{ .string = "any" });
    try obj.put(allocator, "scope", .{ .string = "bogus" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}
