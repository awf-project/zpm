const std = @import("std");
const posix = std.posix;
const Engine = @import("../prolog/engine.zig").Engine;
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;
const project = @import("../project.zig");
const context = @import("../tools/context.zig");
const manifest_mod = @import("../mounts/manifest.zig");
const MountManifest = manifest_mod.MountManifest;
const ManifestEntry = manifest_mod.ManifestEntry;

/// Silence libc stdout for the duration of a call. Trealla's pl_create()
/// writes a banner directly via libc, so we dup2 /dev/null over fd 1 around
/// it. Two syscalls (open + dup) beats a tmpfile round-trip.
fn silenceStdout() !posix.fd_t {
    const saved = try posix.dup(posix.STDOUT_FILENO);
    errdefer posix.close(saved);
    const null_fd = try posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer posix.close(null_fd);
    try posix.dup2(null_fd, posix.STDOUT_FILENO);
    return saved;
}

fn restoreStdout(saved: posix.fd_t) void {
    posix.dup2(saved, posix.STDOUT_FILENO) catch {};
    posix.close(saved);
}

/// Aggregate of long-lived resources returned by `initBootstrap`.
///
/// **Caller contract** — `initBootstrap` returns `Context` BY VALUE so only the
/// caller holds a stable address for these fields. Each MCP/CLI entry point
/// MUST wire the live pointers into the global tool-context slots before
/// invoking any tool handler:
///
///   context.setEngine(ctx.engine);
///   context.setPersistenceManager(@ptrCast(&ctx.pm));
///   context.setMemoryRegistry(@ptrCast(&ctx.registry));
///   context.setMountManifest(@ptrCast(&ctx.manifest));
///   context.setKbDir(ctx.paths.kb_dir);
///
/// Forgetting any of these — and `setMountManifest` in particular — does NOT
/// fail loudly: the affected handlers silently fall back to degraded mode
/// (`reg.create`/`mount`/`unmount` succeed in-memory but the manifest is never
/// written). See `wireContext` in `src/cli/memory.zig:35` and the equivalent
/// blocks in `src/cli/serve.zig` and `src/cli/tool_command.zig` for canonical
/// wiring; new entry points must follow the same pattern.
pub const Context = struct {
    engine: *Engine,
    pm: PersistenceManager,
    registry: MemoryRegistry,
    manifest: MountManifest,
    paths: project.ProjectPaths,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Context) void {
        self.registry.deinit();
        self.pm.deinit();
        self.engine.deinit();
        self.manifest.deinit();
        self.paths.deinit();
    }
};

/// Scan .zpm/kb/ for subdirectories and return a populated MountManifest.
/// Always includes "default" as entry #0. Does NOT call registry.mount.
fn migrateToManifest(allocator: std.mem.Allocator, paths: project.ProjectPaths) !MountManifest {
    var manifest = try MountManifest.init(allocator, paths.manifest_path);
    errdefer manifest.deinit();

    try manifest.addEntry(.{
        .name = "default",
        .path = ".zpm/kb/default",
        .scope = .project,
        .mode = .rw,
    });

    var kb = std.fs.openDirAbsolute(paths.kb_dir, .{ .iterate = true }) catch return manifest;
    defer kb.close();
    var iter = kb.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "default")) continue;
        const rel_path = std.fmt.allocPrint(allocator, ".zpm/kb/{s}", .{entry.name}) catch continue;
        defer allocator.free(rel_path);
        manifest.addEntry(.{
            .name = entry.name,
            .path = rel_path,
            .scope = .project,
            .mode = .rw,
        }) catch |err| switch (err) {
            error.InvalidName => continue,
            else => return err,
        };
    }

    return manifest;
}

/// Rename the existing manifest to mounts.json.corrupt-<unix_ts> for postmortem.
fn preserveCorrupt(paths: project.ProjectPaths) !void {
    const ts = std.time.timestamp();
    var corrupt_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const corrupt_path = try std.fmt.bufPrint(
        &corrupt_buf,
        "{s}.corrupt-{d}",
        .{ paths.manifest_path, ts },
    );
    try std.fs.renameAbsolute(paths.manifest_path, corrupt_path);
}

/// Initialize the long-lived resources for a single zpm invocation.
///
/// Returns a `Context` by value; see `Context`'s doc for the **caller wiring
/// contract** (you MUST publish the manifest / registry / pm / kb_dir / engine
/// into the global tool-context slots before invoking any handler — bootstrap
/// cannot do it itself because only the caller holds the stable address).
pub fn initBootstrap(allocator: std.mem.Allocator) anyerror!Context {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const paths = try project.discover(allocator, cwd);
    errdefer paths.deinit();

    std.fs.makeDirAbsolute(paths.data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(paths.kb_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const saved_stdout = silenceStdout() catch null;
    const engine = Engine.init(.{}) catch |err| {
        if (saved_stdout) |fd| restoreStdout(fd);
        return err;
    };
    if (saved_stdout) |fd| restoreStdout(fd);
    errdefer engine.deinit();
    context.setEngine(engine);
    errdefer context.clearEngine();

    try project.loadKnowledgeBase(allocator, paths.kb_dir, engine);

    var pm = try PersistenceManager.init(allocator, paths.data_dir, paths.kb_dir);
    errdefer pm.deinit();
    try pm.restore(engine);

    const file_exists = blk: {
        const f = std.fs.openFileAbsolute(paths.manifest_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        f.close();
        break :blk true;
    };

    var did_migrate = false;
    var manifest: MountManifest = if (file_exists) blk: {
        break :blk MountManifest.read(allocator, paths.manifest_path) catch |err| switch (err) {
            error.ParseFailed, error.CorruptFile => inner: {
                preserveCorrupt(paths) catch |e| std.log.warn("failed to rename corrupt manifest: {}", .{e});
                did_migrate = true;
                break :inner try migrateToManifest(allocator, paths);
            },
            else => return err,
        };
    } else blk: {
        did_migrate = true;
        break :blk try migrateToManifest(allocator, paths);
    };
    errdefer manifest.deinit();

    if (did_migrate) {
        try manifest.write();
    }

    const zpm_dir = std.fs.path.dirname(paths.kb_dir) orelse unreachable;
    const project_root = std.fs.path.dirname(zpm_dir) orelse unreachable;

    var registry = MemoryRegistry.init(allocator);
    errdefer registry.deinit();

    for (manifest.entries.items) |entry| {
        const disk_path = switch (entry.scope) {
            .project => try std.fs.path.join(allocator, &.{ project_root, entry.path }),
            .global => try allocator.dupe(u8, entry.path),
        };
        defer allocator.free(disk_path);

        // Always create the default directory if absent.
        if (std.mem.eql(u8, entry.name, "default")) {
            std.fs.makeDirAbsolute(disk_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        // Skip entries whose path is not accessible (FR-009); keep entry in manifest.
        {
            var d = std.fs.openDirAbsolute(disk_path, .{}) catch {
                std.log.warn("skipping missing mount '{s}': path not accessible", .{entry.name});
                continue;
            };
            d.close();
        }

        registry.mount(entry.name, disk_path, entry.scope, entry.mode, engine) catch |err| {
            std.log.warn("failed to mount '{s}': {}", .{ entry.name, err });
            continue;
        };
    }

    return Context{
        .engine = engine,
        .pm = pm,
        .registry = registry,
        .manifest = manifest,
        .paths = paths,
        .allocator = allocator,
    };
}

test "initBootstrap returns Context with correct project paths" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(std.mem.endsWith(u8, ctx.paths.data_dir, "/.zpm/data"));
    try std.testing.expect(std.mem.endsWith(u8, ctx.paths.kb_dir, "/.zpm/kb"));
}

test "initBootstrap sets engine in context globals (PM is set by caller)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(context.getEngine() != null);
    // PM is deliberately not set here: it lives by value in the returned
    // Context, so only the caller has its stable address.
    try std.testing.expect(context.getPersistenceManagerAs(PersistenceManager) == null);
}

var notfound_counter = std.atomic.Value(u32).init(0);

test "initBootstrap returns NotFound when no .zpm directory exists" {
    const allocator = std.testing.allocator;

    // /tmp path avoids walking up into the repo's own .zpm/; pid+counter
    // keeps it race-free across parallel runs.
    const pid = std.c.getpid();
    const counter = notfound_counter.fetchAdd(1, .monotonic);
    var path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/zpm-test-bootstrap-notfound-{d}-{d}", .{ pid, counter });
    try std.fs.makeDirAbsolute(tmp_path);
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    try std.testing.expectError(project.ProjectError.NotFound, initBootstrap(allocator));
}

test "initBootstrap creates .zpm/kb/default directory if missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    const default_dir = try std.fmt.allocPrint(allocator, "{s}/default", .{ctx.paths.kb_dir});
    defer allocator.free(default_dir);
    var dir = try std.fs.openDirAbsolute(default_dir, .{});
    defer dir.close();
}

test "initBootstrap initializes MemoryRegistry and mounts default memory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.registry.mounted.contains("default"));
}

test "bootstrap Context includes registry field with proper deinit cleanup" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    try std.testing.expect(@TypeOf(ctx.registry) == MemoryRegistry);
    ctx.deinit();
}

test "initBootstrap on first boot scans kb_dir and writes mounts.json containing every discovered memory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");
    try tmp.dir.makeDir(".zpm/kb/feature_auth");
    {
        var sub = try tmp.dir.openDir(".zpm/kb/feature_auth", .{});
        defer sub.close();
        var kf = try sub.createFile("knowledge.pl", .{});
        defer kf.close();
        try kf.writeAll(":- module(feature_auth, []).\n");
    }

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.registry.mounted.contains("default"));
    try std.testing.expect(ctx.registry.mounted.contains("feature_auth"));

    const manifest_file = try tmp.dir.readFileAlloc(allocator, ".zpm/mounts.json", 8192);
    defer allocator.free(manifest_file);
    try std.testing.expect(std.mem.containsAtLeast(u8, manifest_file, 1, "\"default\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, manifest_file, 1, "\"feature_auth\""));
}

test "initBootstrap on second boot reads mounts.json and does NOT rescan kb_dir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");
    try tmp.dir.makeDir(".zpm/kb/listed");
    try tmp.dir.makeDir(".zpm/kb/not_in_manifest");

    const manifest_json =
        \\{
        \\  "version": 1,
        \\  "mounts": [
        \\    {
        \\      "name": "default",
        \\      "path": ".zpm/kb/default",
        \\      "scope": "project",
        \\      "mode": "rw"
        \\    },
        \\    {
        \\      "name": "listed",
        \\      "path": ".zpm/kb/listed",
        \\      "scope": "project",
        \\      "mode": "rw"
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{
        .sub_path = ".zpm/mounts.json",
        .data = manifest_json,
    });

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.registry.mounted.contains("default"));
    try std.testing.expect(ctx.registry.mounted.contains("listed"));
    try std.testing.expect(!ctx.registry.mounted.contains("not_in_manifest"));
}

test "initBootstrap skips manifest entry pointing to deleted path without panic" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    const manifest_json =
        \\{
        \\  "version": 1,
        \\  "mounts": [
        \\    {
        \\      "name": "default",
        \\      "path": ".zpm/kb/default",
        \\      "scope": "project",
        \\      "mode": "rw"
        \\    },
        \\    {
        \\      "name": "ghost",
        \\      "path": ".zpm/kb/ghost",
        \\      "scope": "project",
        \\      "mode": "rw"
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{
        .sub_path = ".zpm/mounts.json",
        .data = manifest_json,
    });

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(ctx.registry.mounted.contains("default"));
    try std.testing.expect(!ctx.registry.mounted.contains("ghost"));
}

test "initBootstrap regenerates mounts.json from migration when existing file is corrupt and preserves the bad file as mounts.json.corrupt-*" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");
    try tmp.dir.makeDir(".zpm/kb/feature_auth");

    try tmp.dir.writeFile(.{
        .sub_path = ".zpm/mounts.json",
        .data = "{not json",
    });

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    const manifest_file = try tmp.dir.readFileAlloc(allocator, ".zpm/mounts.json", 8192);
    defer allocator.free(manifest_file);
    try std.testing.expect(std.mem.containsAtLeast(u8, manifest_file, 1, "\"default\""));

    var zpm_dir = try tmp.dir.openDir(".zpm", .{ .iterate = true });
    defer zpm_dir.close();

    var iter = zpm_dir.iterate();
    var corrupt_count: usize = 0;
    while (try iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "mounts.json.corrupt-")) {
            corrupt_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), corrupt_count);
}
