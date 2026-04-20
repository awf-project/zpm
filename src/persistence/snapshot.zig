const std = @import("std");
const engine_mod = @import("../prolog/engine.zig");
const term_utils = @import("term_utils");
const Engine = engine_mod.Engine;

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,

    pub fn generate(allocator: std.mem.Allocator, engine: *Engine, dir_path: []const u8, name: []const u8) !Snapshot {
        const snapshot_name = try std.fmt.allocPrint(allocator, "{s}.pl", .{name});
        errdefer allocator.free(snapshot_name);

        const tmp_name = try std.fmt.allocPrint(allocator, "{s}.tmp", .{snapshot_name});
        defer allocator.free(tmp_name);

        var dir = try std.fs.openDirAbsolute(dir_path, .{});
        defer dir.close();

        // Rename only after both writes succeed; drop the tmp on failure so
        // a half-written file is never promoted to final.
        {
            const tmp_file = try dir.createFile(tmp_name, .{});
            var close_tmp = true;
            defer if (close_tmp) tmp_file.close();
            const ts = std.time.timestamp();
            var hdr_buf: [64]u8 = undefined;
            const hdr = try std.fmt.bufPrint(&hdr_buf, "%% zpm snapshot {d}\n", .{ts});
            tmp_file.writeAll(hdr) catch |err| {
                tmp_file.close();
                close_tmp = false;
                dir.deleteFile(tmp_name) catch {};
                return err;
            };
            writeClausesToFile(allocator, engine, tmp_file) catch |err| {
                tmp_file.close();
                close_tmp = false;
                dir.deleteFile(tmp_name) catch {};
                return err;
            };
        }

        try dir.rename(tmp_name, snapshot_name);

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, snapshot_name });
        errdefer allocator.free(full_path);

        return Snapshot{ .allocator = allocator, .name = snapshot_name, .path = full_path };
    }

    pub fn restore(self: *const Snapshot, engine: *Engine) !void {
        // pl_consult is additive; wipe user clauses first so restore replaces
        // rather than merges. `:- dynamic(F/A)` declarations stay in effect.
        try engine.resetUserKnowledge();
        try engine.loadFile(self.path);
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.name);
        self.allocator.free(self.path);
    }
};

fn writeClausesToFile(allocator: std.mem.Allocator, engine: *Engine, file: std.fs.File) !void {
    const dump = try engine.dumpDynamicPredicates(allocator);
    defer allocator.free(dump);

    try file.writeAll("%% zpm snapshot\n");
    try file.writeAll(dump);
}

pub fn list(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch {
        return try allocator.alloc([]const u8, 0);
    };
    defer dir.close();

    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |n| allocator.free(n);
        results.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pl")) continue;
        try results.append(allocator, try allocator.dupe(u8, entry.name));
    }

    return try results.toOwnedSlice(allocator);
}

test "generate creates snapshot file with correct name in persistence directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var snap = try Snapshot.generate(arena.allocator(), engine, dir_path, "kb_snap");
    defer snap.deinit();

    try std.testing.expectEqualStrings("kb_snap.pl", snap.name);
    _ = try tmp.dir.statFile("kb_snap.pl");
}

test "generate snapshot path is within persistence directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var snap = try Snapshot.generate(arena.allocator(), engine, dir_path, "kb_snap");
    defer snap.deinit();

    try std.testing.expect(std.mem.startsWith(u8, snap.path, dir_path));
    try std.testing.expect(std.mem.endsWith(u8, snap.path, "kb_snap.pl"));
}

test "list returns only .pl files and excludes non-snapshot files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    (try tmp.dir.createFile("snap1.pl", .{})).close();
    (try tmp.dir.createFile("snap2.pl", .{})).close();
    (try tmp.dir.createFile("journal.wal", .{})).close();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const snapshots = try list(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 2), snapshots.len);
}

test "restore loads snapshot file into engine without error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var snap = try Snapshot.generate(arena.allocator(), engine, dir_path, "restore_snap");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();

    try snap.restore(engine2);
}

test "list returns empty slice for empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const snapshots = try list(arena.allocator(), dir_path);

    try std.testing.expectEqual(@as(usize, 0), snapshots.len);
}

test "save+restore round-trips rule with conjunction body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.assertFact("parent(alice, bob)");
    try engine.assertFact("parent(bob, carol)");
    try engine.loadString(":- dynamic(grandparent/2).\n");
    try engine.assertFact("(grandparent(X, Z) :- parent(X, Y), parent(Y, Z))");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "test");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("grandparent(alice, C)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len == 1);
}

test "save+restore round-trips quoted atoms with spaces and uppercase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.loadString(":- dynamic(feature_spec/3).\n");
    try engine.assertFact("feature_spec(f013, 'Tag-Triggered Release Workflows', 'M')");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "quoted");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("feature_spec(f013, Title, Size)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len == 1);
}

test "save+restore preserves dynamic: assertz after restore succeeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.loadString(":- dynamic(task_status/2).\n");
    try engine.assertFact("task_status(f012, complete)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "dyn");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();
    try snap.restore(engine2);

    // Should NOT raise permission_error(modify, static_procedure).
    try engine2.assertFact("task_status(f016, in_progress)");

    var result = try engine2.query("task_status(F, S)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len == 2);
}

test "restore replaces KB instead of appending (no duplicates on same engine)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.assertFact("demo_item(alpha, 1, active)");
    try engine.assertFact("demo_item(beta, 2, active)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "replace");
    defer snap.deinit();

    // Restore onto the same live engine — must replace, not append.
    try snap.restore(engine);

    var result = try engine.query("demo_item(N, P, S)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.solutions.len);

    try engine.assertFact("demo_item(gamma, 3, postrestore)");
    var result2 = try engine.query("demo_item(N, P, S)");
    defer result2.deinit();
    try std.testing.expectEqual(@as(usize, 3), result2.solutions.len);
}

test "round-trip preserves multi-word quoted atoms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.assertFact("feature_spec(f013, 'Tag-Triggered Release Workflows', backlog)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "rt_quoted");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("feature_spec(f013, Title, backlog)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.solutions.len);
    const title = result.solutions[0].bindings.get("Title").?;
    try std.testing.expectEqualStrings("Tag-Triggered Release Workflows", title.atom);
}

test "round-trip preserves nested compound with embedded list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.assertFact("depends_on(foo(bar, baz), [x, y])");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "rt_nested");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("depends_on(foo(bar, baz), L)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.solutions.len);
    const l = result.solutions[0].bindings.get("L").?;
    try std.testing.expect(l == .list);
    try std.testing.expectEqual(@as(usize, 2), l.list.len);
    try std.testing.expectEqualStrings("x", l.list[0].atom);
    try std.testing.expectEqualStrings("y", l.list[1].atom);
}

test "round-trip preserves atom containing escaped double quotes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    try engine.assertFact("note(bug, 'He said \"hi\"')");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "rt_esc");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("note(bug, Msg)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.solutions.len);
    const msg = result.solutions[0].bindings.get("Msg").?;
    try std.testing.expectEqualStrings("He said \"hi\"", msg.atom);
}

test "static-after-load: assertFact same functor after restore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{});
    defer engine.deinit();
    // No explicit :- dynamic. The engine must emit it on first assertFact.
    try engine.assertFact("task_status(f020, draft)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "static_repro");
    defer snap.deinit();

    const engine2 = try Engine.init(.{});
    defer engine2.deinit();
    try snap.restore(engine2);

    // Must NOT raise permission_error(modify, static_procedure).
    try engine2.assertFact("task_status(f021, in_progress)");

    var result = try engine2.query("task_status(F, S)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.solutions.len);
}

test "static-after-load: assertFact-retractall-assertFact sanity" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("widget(a)");
    try engine.retractAll("widget(_)");
    try engine.assertFact("widget(b)");

    var result = try engine.query("widget(X)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.solutions.len);
    try std.testing.expectEqualStrings("b", result.solutions[0].bindings.get("X").?.atom);
}

test "generate propagates dump error and leaves no final snapshot file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    // simulateHandleFailure makes dumpDynamicPredicates return QueryFailed.
    var engine = try Engine.init(.{});
    engine.simulateHandleFailure();
    defer engine.deinit();

    const result = Snapshot.generate(std.testing.allocator, engine, dir_path, "should_not_exist");
    try std.testing.expectError(engine_mod.EngineError.QueryFailed, result);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("should_not_exist.pl"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("should_not_exist.pl.tmp"));
}
