const std = @import("std");
const Engine = @import("../prolog/engine.zig").Engine;
const mcp = @import("mcp");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

var mutex = std.Thread.Mutex{};
var engine: ?*Engine = null;
var persistence_manager: ?*anyopaque = null;
var memory_registry: ?*anyopaque = null;
var kb_dir: ?[]const u8 = null;
var mount_manifest: ?*anyopaque = null;

pub fn setEngine(e: *Engine) void {
    mutex.lock();
    defer mutex.unlock();
    engine = e;
}

pub fn clearEngine() void {
    mutex.lock();
    defer mutex.unlock();
    engine = null;
}

pub fn getEngine() ?*Engine {
    mutex.lock();
    defer mutex.unlock();
    return engine;
}

pub fn setPersistenceManager(pm: *anyopaque) void {
    mutex.lock();
    defer mutex.unlock();
    persistence_manager = pm;
}

pub fn clearPersistenceManager() void {
    mutex.lock();
    defer mutex.unlock();
    persistence_manager = null;
}

pub fn getPersistenceManagerAs(comptime T: type) ?*T {
    mutex.lock();
    defer mutex.unlock();
    const pm = persistence_manager orelse return null;
    return @ptrCast(@alignCast(pm));
}

pub fn setMemoryRegistry(reg: *anyopaque) void {
    mutex.lock();
    defer mutex.unlock();
    memory_registry = reg;
}

pub fn clearMemoryRegistry() void {
    mutex.lock();
    defer mutex.unlock();
    memory_registry = null;
}

pub fn getMemoryRegistryAs(comptime T: type) ?*T {
    mutex.lock();
    defer mutex.unlock();
    const mr = memory_registry orelse return null;
    return @ptrCast(@alignCast(mr));
}

pub fn setMountManifest(mf: *anyopaque) void {
    mutex.lock();
    defer mutex.unlock();
    mount_manifest = mf;
}

pub fn clearMountManifest() void {
    mutex.lock();
    defer mutex.unlock();
    mount_manifest = null;
}

pub fn getMountManifestAs(comptime T: type) ?*T {
    mutex.lock();
    defer mutex.unlock();
    const mm = mount_manifest orelse return null;
    return @ptrCast(@alignCast(mm));
}

pub fn setKbDir(dir: []const u8) void {
    mutex.lock();
    defer mutex.unlock();
    kb_dir = dir;
}

pub fn getKbDir() ?[]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return kb_dir;
}

pub fn clearKbDir() void {
    mutex.lock();
    defer mutex.unlock();
    kb_dir = null;
}

/// Sentinel name for the global, always-mounted default memory.
///
/// Mutations and snapshots targeting this name bypass the per-segment
/// `PersistenceManager` from the `MemoryRegistry` and route to the global PM
/// instead. This preserves consistency with `initBootstrap`, which restores
/// from the global WAL (`.zpm/data/`) and snapshot dir (`.zpm/kb/`). The
/// segment PM that the registry creates for "default" has a stale
/// `snapshot_dir` (`.zpm/kb/default/`), which is the wrong canonical location.
///
/// Any new tool that resolves a PersistenceManager from a memory name MUST
/// honor this bypass — use `isDefaultMemory(name)` to gate the registry lookup.
pub const default_memory_name = "default";

pub fn isDefaultMemory(name: []const u8) bool {
    return std.mem.eql(u8, name, default_memory_name);
}

pub fn resolveMemoryName(args: ?std.json.Value) []const u8 {
    const a = args orelse return default_memory_name;
    const obj = switch (a) {
        .object => |o| o,
        else => return default_memory_name,
    };
    const val = obj.get("memory") orelse return default_memory_name;
    return switch (val) {
        .string => |s| if (s.len == 0) default_memory_name else s,
        else => default_memory_name,
    };
}

pub fn qualifyClause(allocator: std.mem.Allocator, memory_name: []const u8, clause: []const u8) ![]const u8 {
    if (isDefaultMemory(memory_name)) return allocator.dupe(u8, clause);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ memory_name, clause });
}

pub const ResolvedMemory = struct {
    memory_name: []const u8,
    pm: ?*PersistenceManager,
};

pub const MemoryResolutionResult = union(enum) {
    resolved: ResolvedMemory,
    tool_result: mcp.tools.ToolResult,
};

pub fn resolveWritableMemory(
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
) mcp.tools.ToolError!MemoryResolutionResult {
    const memory_name = resolveMemoryName(args);
    const reg = getMemoryRegistryAs(MemoryRegistry);

    // See `default_memory_name` doc for the bypass rationale.
    if (!isDefaultMemory(memory_name)) {
        if (reg) |r| {
            if (r.getMounted(memory_name)) |entry| {
                if (entry.mode == .ro) {
                    return .{ .tool_result = mcp.tools.errorResult(allocator, "Memory is read-only") catch return mcp.tools.ToolError.OutOfMemory };
                }
                return .{ .resolved = .{ .memory_name = memory_name, .pm = &entry.pm } };
            }
        }
        const msg = std.fmt.allocPrint(allocator, "Memory not mounted: {s}", .{memory_name}) catch return mcp.tools.ToolError.OutOfMemory;
        return .{ .tool_result = mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory };
    }
    return .{ .resolved = .{ .memory_name = memory_name, .pm = getPersistenceManagerAs(PersistenceManager) } };
}

test "getEngine returns null before setEngine is called" {
    clearEngine();
    try std.testing.expectEqual(@as(?*Engine, null), getEngine());
}

test "getEngine returns engine pointer after setEngine is called" {
    clearEngine();
    defer clearEngine();
    var dummy: Engine = undefined;
    setEngine(&dummy);
    const result = getEngine();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(&dummy, result.?);
}

test "getMemoryRegistryAs returns null when clearMemoryRegistry was called" {
    clearMemoryRegistry();
    const DummyType = struct {};
    try std.testing.expectEqual(@as(?*DummyType, null), getMemoryRegistryAs(DummyType));
}

test "setMemoryRegistry stores registry pointer under mutex" {
    clearMemoryRegistry();
    defer clearMemoryRegistry();
    const DummyRegistry = struct { value: u32 };
    var dummy: DummyRegistry = .{ .value = 42 };
    setMemoryRegistry(@ptrCast(&dummy));
    const retrieved = getMemoryRegistryAs(DummyRegistry);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 42), retrieved.?.value);
}

test "getMemoryRegistryAs returns null before setMemoryRegistry is called" {
    clearMemoryRegistry();
    const DummyRegistry = struct {};
    try std.testing.expectEqual(@as(?*DummyRegistry, null), getMemoryRegistryAs(DummyRegistry));
}

test "getMemoryRegistryAs returns valid pointer after setMemoryRegistry is called" {
    clearMemoryRegistry();
    defer clearMemoryRegistry();
    const DummyRegistry = struct { id: u64 };
    var dummy: DummyRegistry = .{ .id = 999 };
    setMemoryRegistry(@ptrCast(&dummy));
    const retrieved = getMemoryRegistryAs(DummyRegistry);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(&dummy, retrieved.?);
}

test "getPersistenceManagerAs still works for backward compat" {
    clearPersistenceManager();
    defer clearPersistenceManager();
    const DummyPM = struct { count: u32 };
    var dummy: DummyPM = .{ .count = 123 };
    setPersistenceManager(@ptrCast(&dummy));
    const retrieved = getPersistenceManagerAs(DummyPM);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 123), retrieved.?.count);
}

test "resolveMemoryName returns default when args is null" {
    const result = resolveMemoryName(null);
    try std.testing.expectEqualStrings("default", result);
}

test "resolveMemoryName returns default when memory key is absent" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    const result = resolveMemoryName(parsed.value);
    try std.testing.expectEqualStrings("default", result);
}

test "resolveMemoryName returns default when memory value is empty string" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"memory\": \"\"}", .{});
    defer parsed.deinit();
    const result = resolveMemoryName(parsed.value);
    try std.testing.expectEqualStrings("default", result);
}

test "resolveMemoryName returns value when memory key is present and non-empty" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"memory\": \"feature_auth\"}", .{});
    defer parsed.deinit();
    const result = resolveMemoryName(parsed.value);
    try std.testing.expectEqualStrings("feature_auth", result);
}

test "qualifyClause returns dupe when memory_name is default" {
    const result = try qualifyClause(std.testing.allocator, "default", "fact(x)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("fact(x)", result);
}

test "qualifyClause returns prefixed clause for named memory" {
    const result = try qualifyClause(std.testing.allocator, "feature_auth", "fact(x)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("feature_auth:fact(x)", result);
}

test "resolveWritableMemory returns default PM when no args" {
    clearMemoryRegistry();
    clearPersistenceManager();
    const result = try resolveWritableMemory(std.testing.allocator, null);
    switch (result) {
        .resolved => |m| try std.testing.expectEqualStrings("default", m.memory_name),
        .tool_result => return error.UnexpectedToolResult,
    }
}

test "getMountManifestAs returns null before setMountManifest is called" {
    clearMountManifest();
    const DummyType = struct {};
    try std.testing.expectEqual(@as(?*DummyType, null), getMountManifestAs(DummyType));
}

test "getMountManifestAs returns null after clearMountManifest" {
    clearMountManifest();
    defer clearMountManifest();
    const DummyManifest = struct { value: u32 };
    var dummy: DummyManifest = .{ .value = 1 };
    setMountManifest(@ptrCast(&dummy));
    clearMountManifest();
    try std.testing.expectEqual(@as(?*DummyManifest, null), getMountManifestAs(DummyManifest));
}

test "setMountManifest then getMountManifestAs returns valid typed pointer" {
    clearMountManifest();
    defer clearMountManifest();
    const DummyManifest = struct { value: u32 };
    var dummy: DummyManifest = .{ .value = 42 };
    setMountManifest(@ptrCast(&dummy));
    const retrieved = getMountManifestAs(DummyManifest);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 42), retrieved.?.value);
}

test "resolveWritableMemory returns error for unmounted non-default memory" {
    clearMemoryRegistry();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    setMemoryRegistry(@ptrCast(&reg));
    defer clearMemoryRegistry();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"memory\": \"nonexistent\"}", .{});
    defer parsed.deinit();

    const result = try resolveWritableMemory(allocator, parsed.value);
    switch (result) {
        .tool_result => |r| try std.testing.expect(r.is_error),
        .resolved => return error.UnexpectedResolved,
    }
}
