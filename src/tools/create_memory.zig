const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;
const MemoryScope = @import("../memory/registry.zig").MemoryScope;
const MemoryMode = @import("../memory/registry.zig").MemoryMode;
const isValidAtomName = @import("tool_validation").isValidAtomName;
const manifest_mod = @import("../mounts/manifest.zig");
const MountManifest = manifest_mod.MountManifest;
const parseScope = manifest_mod.parseScope;

// libc env mutators; std.c does not expose them in Zig 0.15.x but we link libc.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("name", "Memory name (lowercase, alphanumeric with underscores)", true);
    _ = try schema.addString("scope", "Memory scope: \"project\" or \"global\" (default: \"project\")", false);
    const built = try schema.build();

    return .{
        .name = "create_memory",
        .description = "Create a new named memory module with an isolated Prolog namespace",
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

/// Recursively create an absolute directory path. Idempotent on
/// `PathAlreadyExists`. If a parent is missing (`FileNotFound`), walks up,
/// creates the parent, then retries. Used by `resolveGlobalPath` so a synthetic
/// `$HOME` (in tests) or a freshly-provisioned account (no `~/.local/share`)
/// produces a working `zpm/kb/` chain without the caller having to pre-create
/// intermediate directories.
fn ensureDirAbsolute(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            try ensureDirAbsolute(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
}

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

    const kb_dir = try std.fmt.allocPrint(allocator, "{s}/zpm/kb", .{base});
    defer allocator.free(kb_dir);
    try ensureDirAbsolute(kb_dir);

    return std.fmt.allocPrint(allocator, "{s}/zpm/kb/{s}", .{ base, name });
}

fn writeManifestEntry(
    allocator: std.mem.Allocator,
    manifest: *MountManifest,
    name: []const u8,
    disk_path: []const u8,
    scope: MemoryScope,
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
        .mode = .rw,
    }) catch |err| switch (err) {
        error.OutOfMemory => return mcp.tools.ToolError.OutOfMemory,
        else => return mcp.tools.ToolError.ExecutionFailed,
    };

    manifest.write() catch return mcp.tools.ToolError.ExecutionFailed;
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const name = mcp.tools.getString(args, "name") orelse return mcp.tools.ToolError.InvalidArguments;
    if (!isValidAtomName(name)) {
        const msg = std.fmt.allocPrint(allocator, "Invalid memory name: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    }
    const reg = context.getMemoryRegistryAs(MemoryRegistry) orelse return mcp.tools.ToolError.ExecutionFailed;
    const kb = context.getKbDir() orelse return mcp.tools.ToolError.ExecutionFailed;

    const scope_str = mcp.tools.getString(args, "scope") orelse "project";
    const scope = parseScope(scope_str) orelse {
        const msg = std.fmt.allocPrint(allocator, "Invalid scope: {s}", .{scope_str}) catch return mcp.tools.ToolError.OutOfMemory;
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    const disk_path = switch (scope) {
        .project => std.fmt.allocPrint(allocator, "{s}/{s}", .{ kb, name }) catch return mcp.tools.ToolError.OutOfMemory,
        .global => resolveGlobalPath(allocator, name) catch return mcp.tools.ToolError.ExecutionFailed,
    };
    defer allocator.free(disk_path);

    reg.create(name, disk_path) catch |err| {
        const msg = switch (err) {
            error.AlreadyExists => std.fmt.allocPrint(allocator, "Memory already exists: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory,
            error.InvalidName => std.fmt.allocPrint(allocator, "Invalid memory name: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory,
            else => return mcp.tools.ToolError.ExecutionFailed,
        };
        return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
    };

    if (context.getMountManifestAs(MountManifest)) |manifest_ptr| {
        writeManifestEntry(allocator, manifest_ptr, name, disk_path, scope) catch |err| {
            std.fs.deleteTreeAbsolute(disk_path) catch {};
            return err;
        };
    }

    const msg = std.fmt.allocPrint(allocator, "Memory created: {s}", .{name}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

test "create_memory tool returns correct structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    try std.testing.expectEqualStrings("create_memory", t.name);
}

test "create_memory handler with valid name returns success text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();
    context.setKbDir(dir_path);
    defer context.clearKbDir();
    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "my_memory" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
}

test "create_memory handler with invalid name returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "my-memory" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
}

test "create_memory handler with null args returns InvalidArguments" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "create_memory handler with missing name returns InvalidArguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "create_memory handler returns ExecutionFailed when registry unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearMemoryRegistry();
    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "test_memory" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "create_memory handler with scope=project adds entry to manifest with relative path .zpm/kb/<name>" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create the .zpm/kb/ directory structure so reg.create can make subdirs inside it
    try tmp.dir.makePath(".zpm/kb");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = try tmp.dir.realpath(".", &path_buf);

    // kb_dir is the absolute path; project root is its dirname parent (.zpm is inside it)
    const kb_dir = try std.fmt.allocPrint(allocator, "{s}/.zpm/kb", .{project_root});

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/mounts.json", .{project_root});
    var manifest = try MountManifest.init(std.testing.allocator, manifest_path);
    defer manifest.deinit();

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    context.setKbDir(kb_dir);
    defer context.clearKbDir();

    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "my_memory" });
    try obj.put("scope", .{ .string = "project" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    // Verify the manifest entry stores a project-relative path, not the absolute disk_path
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);
    try std.testing.expectEqualStrings(".zpm/kb/my_memory", manifest.entries.items[0].path);
}

test "create_memory handler with scope=global resolves path under XDG_DATA_HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    // Isolate XDG_DATA_HOME to the tmp dir so the test is hermetic
    const xdg_c = try allocator.dupeZ(u8, dir_path);
    _ = setenv("XDG_DATA_HOME", xdg_c.ptr, 1);
    defer _ = unsetenv("XDG_DATA_HOME");

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    context.setKbDir(dir_path);
    defer context.clearKbDir();

    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "global_mem" });
    try obj.put("scope", .{ .string = "global" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
}

test "create_memory handler with scope=global falls back to HOME when XDG_DATA_HOME unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    // Save and override HOME, unset XDG_DATA_HOME — fully hermetic
    const orig_home = std.posix.getenv("HOME");
    var orig_home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const saved_home: ?[]const u8 = if (orig_home) |h| blk: {
        @memcpy(orig_home_buf[0..h.len], h);
        break :blk orig_home_buf[0..h.len];
    } else null;

    _ = unsetenv("XDG_DATA_HOME");
    const home_c = try allocator.dupeZ(u8, dir_path);
    _ = setenv("HOME", home_c.ptr, 1);
    defer {
        if (saved_home) |h| {
            const restore = allocator.dupeZ(u8, h) catch null;
            if (restore) |r| _ = setenv("HOME", r.ptr, 1);
        } else {
            _ = unsetenv("HOME");
        }
    }

    // resolveGlobalPath now creates parents recursively via ensureDirAbsolute,
    // so the synthetic HOME does not need .local/share pre-created.

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    context.setKbDir(dir_path);
    defer context.clearKbDir();

    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "fallback_mem" });
    try obj.put("scope", .{ .string = "global" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
}

test "create_memory handler with no manifest in context succeeds without writing (degraded mode)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    context.setKbDir(dir_path);
    defer context.clearKbDir();

    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "degraded_mem" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);
}

test "create_memory handler returns ExecutionFailed when manifest write fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    context.setKbDir(dir_path);
    defer context.clearKbDir();

    // Point manifest at a non-existent subdirectory so manifest.write() returns WriteError
    const bad_manifest_path = try std.fmt.allocPrint(allocator, "{s}/no_such_subdir/mounts.json", .{dir_path});
    var manifest = try MountManifest.init(std.testing.allocator, bad_manifest_path);
    defer manifest.deinit();

    context.setMountManifest(@ptrCast(&manifest));
    defer context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "fail_mem" });
    const args = std.json.Value{ .object = obj };

    // reg.create succeeds (disk_path is inside dir_path which exists);
    // manifest.write() then fails because no_such_subdir/ does not exist → ExecutionFailed
    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "create_memory handler with unknown scope returns error result with message 'Invalid scope: <value>'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var registry = MemoryRegistry.init(std.testing.allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    context.setKbDir(dir_path);
    defer context.clearKbDir();

    context.clearMountManifest();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", .{ .string = "test_mem" });
    try obj.put("scope", .{ .string = "invalid_scope" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings("Invalid scope: invalid_scope", result.content[0].text.text);
}
