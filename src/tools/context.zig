const std = @import("std");
const Engine = @import("../prolog/engine.zig").Engine;
const mcp = @import("mcp");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

/// True when `name` is a bare lowercase Prolog atom (matches the segment-name
/// grammar). Inlined rather than imported from validation.zig to avoid a module
/// aliasing conflict when context.zig is compiled into several test modules.
fn isBareAtom(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

// Process-global handler state. The MCP server runs a single STDIO transport on
// one thread, so these are read and written without synchronization by design.
var g_engine: ?*Engine = null;
var persistence_manager: ?*anyopaque = null;
var memory_registry: ?*anyopaque = null;
var kb_dir: ?[]const u8 = null;
var mount_manifest: ?*anyopaque = null;

pub fn setEngine(e: *Engine) void {
    g_engine = e;
}

pub fn clearEngine() void {
    g_engine = null;
}

pub fn getEngine() ?*Engine {
    return g_engine;
}

pub fn setPersistenceManager(pm: *anyopaque) void {
    persistence_manager = pm;
}

pub fn clearPersistenceManager() void {
    persistence_manager = null;
}

pub fn getPersistenceManagerAs(comptime T: type) ?*T {
    const pm = persistence_manager orelse return null;
    return @ptrCast(@alignCast(pm));
}

pub fn setMemoryRegistry(reg: *anyopaque) void {
    memory_registry = reg;
}

pub fn clearMemoryRegistry() void {
    memory_registry = null;
}

pub fn getMemoryRegistryAs(comptime T: type) ?*T {
    const mr = memory_registry orelse return null;
    return @ptrCast(@alignCast(mr));
}

pub fn setMountManifest(mf: *anyopaque) void {
    mount_manifest = mf;
}

pub fn clearMountManifest() void {
    mount_manifest = null;
}

pub fn getMountManifestAs(comptime T: type) ?*T {
    const mm = mount_manifest orelse return null;
    return @ptrCast(@alignCast(mm));
}

pub fn setKbDir(dir: []const u8) void {
    kb_dir = dir;
}

pub fn getKbDir() ?[]const u8 {
    return kb_dir;
}

pub fn clearKbDir() void {
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

/// Resolve the engine backing a memory: the global engine for the default
/// memory, or the segment's dedicated engine for a mounted name. Returns null
/// if the global engine is unset or the named segment is not mounted.
pub fn getEngineForMemory(memory_name: []const u8) ?*Engine {
    if (isDefaultMemory(memory_name)) return g_engine;
    const reg = getMemoryRegistryAs(MemoryRegistry) orelse return null;
    const entry = reg.getMounted(memory_name) orelse return null;
    return entry.engine;
}

/// Resolve the PersistenceManager for `memory_name`.
///
/// For named (non-default) memories, returns the segment's PM from the
/// MemoryRegistry. For the default memory, returns the global PM from
/// `getPersistenceManagerAs`. Returns null if neither is available.
///
/// This is the canonical PM-resolution pattern shared by save_snapshot and
/// restore_snapshot. See `context.default_memory_name` for the bypass rationale.
pub fn resolvePersistenceManager(memory_name: []const u8) ?*PersistenceManager {
    const reg = getMemoryRegistryAs(MemoryRegistry);
    if (reg) |r| {
        if (!isDefaultMemory(memory_name)) {
            if (r.getMounted(memory_name)) |entry| return &entry.pm;
        }
    }
    return getPersistenceManagerAs(PersistenceManager);
}

pub const RoutedGoal = struct {
    /// The memory the goal targets. "default" when no recognised prefix.
    memory_name: []const u8,
    /// The goal with any recognised `mod:` prefix stripped — to run against the
    /// segment's own engine, where clauses live UNQUALIFIED (B001 / zpm #54).
    goal: []const u8,
};

/// Interpret a leading `mod:` prefix on a goal as a cross-memory selector.
///
/// Module-qualified goals (`feature_auth:task_status(X)`) used to resolve in a
/// single shared engine; with per-segment engines they instead route to the
/// named segment's engine and run unqualified there. The prefix is only treated
/// as a memory selector when `mod` is an actually-mounted segment — otherwise
/// the colon belongs to the term itself (operators, dict syntax) and the goal
/// is left untouched against the default engine.
///
/// Returns slices into `goal`; no allocation.
pub fn routeGoalByModule(goal: []const u8) RoutedGoal {
    const colon = std.mem.indexOfScalar(u8, goal, ':') orelse
        return .{ .memory_name = default_memory_name, .goal = goal };

    const prefix = std.mem.trim(u8, goal[0..colon], " \t");
    // A valid module selector is a bare lowercase atom — reject quoted atoms,
    // empty prefixes, and anything that is not a mounted segment.
    if (!isBareAtom(prefix))
        return .{ .memory_name = default_memory_name, .goal = goal };

    const reg = getMemoryRegistryAs(MemoryRegistry) orelse
        return .{ .memory_name = default_memory_name, .goal = goal };
    if (reg.getMounted(prefix) == null)
        return .{ .memory_name = default_memory_name, .goal = goal };

    return .{ .memory_name = prefix, .goal = std.mem.trim(u8, goal[colon + 1 ..], " \t") };
}

pub const ResolvedMemory = struct {
    memory_name: []const u8,
    pm: ?*PersistenceManager,
    engine: ?*Engine,
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
                return .{ .resolved = .{ .memory_name = memory_name, .pm = &entry.pm, .engine = entry.engine } };
            }
        }
        const msg = std.fmt.allocPrint(allocator, "Memory not mounted: {s}", .{memory_name}) catch return mcp.tools.ToolError.OutOfMemory;
        defer allocator.free(msg);
        return .{ .tool_result = mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory };
    }
    return .{ .resolved = .{ .memory_name = memory_name, .pm = getPersistenceManagerAs(PersistenceManager), .engine = g_engine } };
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

test "setMemoryRegistry stores and retrieves registry pointer" {
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

test "routeGoalByModule leaves unprefixed goal on default" {
    clearMemoryRegistry();
    const r = routeGoalByModule("task_status(X, done)");
    try std.testing.expectEqualStrings("default", r.memory_name);
    try std.testing.expectEqualStrings("task_status(X, done)", r.goal);
}

test "routeGoalByModule ignores prefix when segment is not mounted" {
    clearMemoryRegistry();
    const r = routeGoalByModule("feature_auth:task_status(X)");
    try std.testing.expectEqualStrings("default", r.memory_name);
    try std.testing.expectEqualStrings("feature_auth:task_status(X)", r.goal);
}

test "routeGoalByModule routes a mounted-segment prefix to that segment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.mount("feature_auth", base, .project, .rw, std.testing.io);
    setMemoryRegistry(@ptrCast(&reg));
    defer clearMemoryRegistry();

    const r = routeGoalByModule("feature_auth:task_status(X, done)");
    try std.testing.expectEqualStrings("feature_auth", r.memory_name);
    try std.testing.expectEqualStrings("task_status(X, done)", r.goal);
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
