const std = @import("std");
const engine_mod = @import("../prolog/engine.zig");
const term_utils = @import("term_utils");
const Engine = engine_mod.Engine;

extern "c" fn fflush(stream: ?*anyopaque) c_int;

var staging_counter = std.atomic.Value(u32).init(0);

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,

    pub fn generate(allocator: std.mem.Allocator, engine: *Engine, dir_path: []const u8, name: []const u8, io: std.Io) !Snapshot {
        const snapshot_name = try std.fmt.allocPrint(allocator, "{s}.pl", .{name});
        errdefer allocator.free(snapshot_name);

        const tmp_name = try std.fmt.allocPrint(
            allocator,
            "{s}.tmp-{d}-{d}",
            .{ snapshot_name, std.c.getpid(), staging_counter.fetchAdd(1, .monotonic) },
        );
        defer allocator.free(tmp_name);

        const tmp_path = try std.fs.path.join(allocator, &.{ dir_path, tmp_name });
        defer allocator.free(tmp_path);

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, snapshot_name });
        errdefer allocator.free(full_path);

        var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer dir.close(io);

        // Rename only after both writes succeed; drop the tmp on failure so
        // a half-written file is never promoted to final.
        {
            const tmp_file = try dir.createFile(io, tmp_name, .{});
            var close_tmp = true;
            defer if (close_tmp) tmp_file.close(io);
            writeClausesToFile(allocator, engine, tmp_file, io) catch |err| {
                tmp_file.close(io);
                close_tmp = false;
                dir.deleteFile(io, tmp_name) catch {};
                return err;
            };
        }

        validateCandidate(tmp_path, io) catch |err| {
            dir.deleteFile(io, tmp_name) catch {};
            return err;
        };

        std.Io.Dir.rename(dir, tmp_name, dir, snapshot_name, io) catch |err| {
            dir.deleteFile(io, tmp_name) catch {};
            return err;
        };

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

fn validateCandidate(path: []const u8, io: std.Io) !void {
    const engine = try Engine.init(.{}, io);
    defer engine.deinit();
    try engine.loadFile(path);
}

fn writeClausesToFile(allocator: std.mem.Allocator, engine: *Engine, file: std.Io.File, io: std.Io) !void {
    const ts = blk: {
        var _ts: std.posix.timespec = undefined;
        _ = std.c.clock_gettime(std.posix.CLOCK.REALTIME, &_ts);
        break :blk _ts.sec;
    };
    var hdr_buf: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "%% zpm snapshot {d}\n", .{ts});
    try file.writeStreamingAll(io, hdr);

    const dump = try engine.dumpDynamicPredicates(allocator);
    defer allocator.free(dump);

    var it = engine.iterateDeclaredDynamic();
    while (it.next()) |entry| {
        var dir_buf: [256]u8 = undefined;
        const directive = try std.fmt.bufPrint(&dir_buf, ":- dynamic({s}).", .{entry.key_ptr.*});
        if (std.mem.indexOf(u8, dump, directive) == null) {
            try file.writeStreamingAll(io, directive);
            try file.writeStreamingAll(io, "\n");
        }
    }
    try file.writeStreamingAll(io, dump);
}

pub fn list(allocator: std.mem.Allocator, dir_path: []const u8, io: std.Io) ![][]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
        return try allocator.alloc([]const u8, 0);
    };
    defer dir.close(io);

    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |n| allocator.free(n);
        results.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pl")) continue;
        try results.append(allocator, try allocator.dupe(u8, entry.name));
    }

    return try results.toOwnedSlice(allocator);
}

/// Test-only fd capture for verifying that failed candidate validation does
/// not disclose persisted content or its staging location. This lives here
/// rather than importing prolog/capture.zig because that module is already
/// owned by the engine module in the production import graph.
const TestOutputCapture = struct {
    allocator: std.mem.Allocator,
    out_path: [:0]u8,
    err_path: [:0]u8,
    saved_out: c_int,
    saved_err: c_int,
    out_fd: std.posix.fd_t,
    err_fd: std.posix.fd_t,
    ended: bool = false,

    fn begin(allocator: std.mem.Allocator, dir_path: []const u8) !TestOutputCapture {
        const out_path = try std.fmt.allocPrintSentinel(allocator, "{s}/captured.stdout", .{dir_path}, 0);
        errdefer allocator.free(out_path);
        const err_path = try std.fmt.allocPrintSentinel(allocator, "{s}/captured.stderr", .{dir_path}, 0);
        errdefer allocator.free(err_path);

        _ = fflush(null);
        const saved_out = std.c.dup(std.posix.STDOUT_FILENO);
        if (saved_out == -1) return error.Unexpected;
        errdefer _ = std.c.close(saved_out);
        const saved_err = std.c.dup(std.posix.STDERR_FILENO);
        if (saved_err == -1) return error.Unexpected;
        errdefer _ = std.c.close(saved_err);

        const out_raw = std.c.open(out_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
        if (out_raw == -1) return error.Unexpected;
        const out_fd: std.posix.fd_t = @intCast(out_raw);
        errdefer _ = std.c.close(out_fd);
        const err_raw = std.c.open(err_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
        if (err_raw == -1) return error.Unexpected;
        const err_fd: std.posix.fd_t = @intCast(err_raw);
        errdefer _ = std.c.close(err_fd);

        if (std.c.dup2(out_fd, std.posix.STDOUT_FILENO) == -1) return error.Unexpected;
        errdefer _ = std.c.dup2(saved_out, std.posix.STDOUT_FILENO);
        if (std.c.dup2(err_fd, std.posix.STDERR_FILENO) == -1) return error.Unexpected;
        errdefer _ = std.c.dup2(saved_err, std.posix.STDERR_FILENO);

        return .{ .allocator = allocator, .out_path = out_path, .err_path = err_path, .saved_out = saved_out, .saved_err = saved_err, .out_fd = out_fd, .err_fd = err_fd };
    }

    fn end(self: *TestOutputCapture) void {
        if (self.ended) return;
        self.ended = true;
        _ = fflush(null);
        _ = std.c.dup2(self.saved_out, std.posix.STDOUT_FILENO);
        _ = std.c.dup2(self.saved_err, std.posix.STDERR_FILENO);
        _ = std.c.close(self.saved_out);
        _ = std.c.close(self.saved_err);
        _ = std.c.close(self.out_fd);
        _ = std.c.close(self.err_fd);
    }

    fn read(self: *const TestOutputCapture, io: std.Io) !struct { stdout: []u8, stderr: []u8 } {
        return .{
            .stdout = try std.Io.Dir.cwd().readFileAlloc(io, self.out_path, self.allocator, .limited(8192)),
            .stderr = try std.Io.Dir.cwd().readFileAlloc(io, self.err_path, self.allocator, .limited(8192)),
        };
    }

    fn deinit(self: *TestOutputCapture) void {
        _ = std.c.unlink(self.out_path.ptr);
        _ = std.c.unlink(self.err_path.ptr);
        self.allocator.free(self.out_path);
        self.allocator.free(self.err_path);
    }
};

test "generate creates snapshot file with correct name in persistence directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var snap = try Snapshot.generate(arena.allocator(), engine, dir_path, "kb_snap", std.testing.io);
    defer snap.deinit();

    try std.testing.expectEqualStrings("kb_snap.pl", snap.name);
    _ = try tmp.dir.statFile(std.testing.io, "kb_snap.pl", .{});
}

test "generate snapshot path is within persistence directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var snap = try Snapshot.generate(arena.allocator(), engine, dir_path, "kb_snap", std.testing.io);
    defer snap.deinit();

    try std.testing.expect(std.mem.startsWith(u8, snap.path, dir_path));
    try std.testing.expect(std.mem.endsWith(u8, snap.path, "kb_snap.pl"));
}

test "list returns only .pl files and excludes non-snapshot files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    (try tmp.dir.createFile(std.testing.io, "snap1.pl", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "snap2.pl", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "journal.wal", .{})).close(std.testing.io);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const snapshots = try list(arena.allocator(), dir_path, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), snapshots.len);
}

test "restore loads snapshot file into engine without error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var snap = try Snapshot.generate(arena.allocator(), engine, dir_path, "restore_snap", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
    defer engine2.deinit();

    try snap.restore(engine2);
}

test "list returns empty slice for empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const snapshots = try list(arena.allocator(), dir_path, std.testing.io);

    try std.testing.expectEqual(@as(usize, 0), snapshots.len);
}

test "save+restore round-trips rule with conjunction body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("parent(alice, bob)");
    try engine.assertFact("parent(bob, carol)");
    try engine.loadString(":- dynamic(grandparent/2).\n");
    try engine.assertFact("(grandparent(X, Z) :- parent(X, Y), parent(Y, Z))");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "test", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("grandparent(alice, C)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len == 1);
}

test "save+restore round-trips quoted atoms with spaces and uppercase" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.loadString(":- dynamic(feature_spec/3).\n");
    try engine.assertFact("feature_spec(f013, 'Tag-Triggered Release Workflows', 'M')");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "quoted", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("feature_spec(f013, Title, Size)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len == 1);
}

test "save+restore preserves dynamic: assertz after restore succeeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.loadString(":- dynamic(task_status/2).\n");
    try engine.assertFact("task_status(f012, complete)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "dyn", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
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
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("demo_item(alpha, 1, active)");
    try engine.assertFact("demo_item(beta, 2, active)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "replace", std.testing.io);
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
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("feature_spec(f013, 'Tag-Triggered Release Workflows', backlog)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "rt_quoted", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
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
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("depends_on(foo(bar, baz), [x, y])");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "rt_nested", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
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
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("note(bug, 'He said \"hi\"')");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "rt_esc", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
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
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    // No explicit :- dynamic. The engine must emit it on first assertFact.
    try engine.assertFact("task_status(f020, draft)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "static_repro", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
    defer engine2.deinit();
    try snap.restore(engine2);

    // Must NOT raise permission_error(modify, static_procedure).
    try engine2.assertFact("task_status(f021, in_progress)");

    var result = try engine2.query("task_status(F, S)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.solutions.len);
}

test "static-after-load: assertFact-retractall-assertFact sanity" {
    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try engine.assertFact("widget(a)");
    try engine.retractAll("widget(_)");
    try engine.assertFact("widget(b)");

    var result = try engine.query("widget(X)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.solutions.len);
    try std.testing.expectEqualStrings("b", result.solutions[0].bindings.get("X").?.atom);
}

test "snapshot file starts with %% zpm snapshot header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "hdr_test", std.testing.io);
    defer snap.deinit();

    const content = try tmp.dir.readFileAlloc(std.testing.io, "hdr_test.pl", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.startsWith(u8, content, "%% zpm snapshot "));
}

test "snapshot file contains :- dynamic directive for each predicate from declared_dynamic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("fact_a(1)");
    try engine.assertFact("fact_b(x, y)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "directives_test", std.testing.io);
    defer snap.deinit();

    const content = try tmp.dir.readFileAlloc(std.testing.io, "directives_test.pl", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, ":- dynamic(fact_a/1)."));
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, ":- dynamic(fact_b/2)."));
}

test "snapshot file emits :- dynamic directives before first clause" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("user_item(alpha, 1)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "order_test", std.testing.io);
    defer snap.deinit();

    const content = try tmp.dir.readFileAlloc(std.testing.io, "order_test.pl", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(content);

    const directive_pos = std.mem.indexOf(u8, content, ":- dynamic(user_item/2).") orelse
        return error.DirectiveMissing;
    const clause_pos = std.mem.indexOf(u8, content, "user_item(alpha") orelse
        return error.ClauseMissing;

    try std.testing.expect(directive_pos < clause_pos);
}

test "restore makes four feature/3 facts queryable (US2 acceptance)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("feature(f001, 'Mcp Server', complete)");
    try engine.assertFact("feature(f002, 'Prolog Engine', complete)");
    try engine.assertFact("feature(f003, 'Persistence', complete)");
    try engine.assertFact("feature(f019, 'Fix Retract', planned)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "us2_test", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
    defer engine2.deinit();
    try snap.restore(engine2);

    var result = try engine2.query("feature(F, _, _)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.solutions.len);
}

test "restore makes feature/3 schema count=4 via clause introspection (US2 schema acceptance)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("feature(f001, 'Mcp Server', complete)");
    try engine.assertFact("feature(f002, 'Prolog Engine', complete)");
    try engine.assertFact("feature(f003, 'Persistence', complete)");
    try engine.assertFact("feature(f019, 'Fix Retract', planned)");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "us2_schema_test", std.testing.io);
    defer snap.deinit();

    const engine2 = try Engine.init(.{}, std.testing.io);
    defer engine2.deinit();
    try snap.restore(engine2);

    var schema_result = try engine2.query("clause(feature(_,_,_), true)");
    defer schema_result.deinit();
    try std.testing.expectEqual(@as(usize, 4), schema_result.solutions.len);

    var query_result = try engine2.query("feature(F, _, _)");
    defer query_result.deinit();
    try std.testing.expectEqual(@as(usize, 4), query_result.solutions.len);
}

test "generate propagates dump error and leaves no final snapshot file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // simulateHandleFailure makes dumpDynamicPredicates return QueryFailed.
    var engine = try Engine.init(.{}, std.testing.io);
    engine.simulateHandleFailure();
    defer engine.deinit();

    const result = Snapshot.generate(std.testing.allocator, engine, dir_path, "should_not_exist", std.testing.io);
    try std.testing.expectError(engine_mod.EngineError.QueryFailed, result);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "should_not_exist.pl", .{}));
    {
        var entries = tmp.dir.iterate();
        while (try entries.next(std.testing.io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, "should_not_exist.pl.tmp"));
        }
    }
}

test "generate allocation failure never replaces an existing snapshot" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("replacement(value)");

    const original = "original snapshot bytes\n";
    var observed_failure = false;
    for (0..16) |fail_index| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "atomic.pl", .data = original });

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const result = Snapshot.generate(failing.allocator(), engine, dir_path, "atomic", std.testing.io);
        if (result) |snapshot_value| {
            var snapshot = snapshot_value;
            snapshot.deinit();
        } else |_| {
            observed_failure = true;
            const preserved = try tmp.dir.readFileAlloc(std.testing.io, "atomic.pl", std.testing.allocator, .limited(8192));
            defer std.testing.allocator.free(preserved);
            try std.testing.expectEqualStrings(original, preserved);
        }
        var entries = tmp.dir.iterate();
        while (try entries.next(std.testing.io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, "atomic.pl.tmp"));
        }
    }
    try std.testing.expect(observed_failure);
}

test "snapshot rejects malformed dynamic predicate indicators" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "malformed.pl",
        .data = ":- dynamic(broken(/1).\n",
    });
    const malformed_path = try tmp.dir.realPathFileAlloc(std.testing.io, "malformed.pl", std.testing.allocator);
    defer std.testing.allocator.free(malformed_path);

    var loader = try Engine.init(.{}, std.testing.io);
    defer loader.deinit();
    try std.testing.expectError(engine_mod.EngineError.LoadFailed, loader.loadFile(malformed_path));

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("stable(value)");

    var original = try Snapshot.generate(std.testing.allocator, engine, dir_path, "existing", std.testing.io);
    defer original.deinit();
    const original_bytes = try tmp.dir.readFileAlloc(std.testing.io, "existing.pl", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(original_bytes);

    const malformed_key = try engine.allocator.dupe(u8, "broken(/1");
    engine.declared_dynamic.put(malformed_key, {}) catch |err| {
        engine.allocator.free(malformed_key);
        return err;
    };

    var capture = try TestOutputCapture.begin(std.testing.allocator, dir_path);
    defer capture.deinit();
    defer capture.end();

    try std.testing.expectError(
        engine_mod.EngineError.LoadFailed,
        Snapshot.generate(std.testing.allocator, engine, dir_path, "absent", std.testing.io),
    );

    capture.end();
    const output = try capture.read(std.testing.io);
    defer std.testing.allocator.free(output.stdout);
    defer std.testing.allocator.free(output.stderr);
    inline for ([_][]const u8{ "broken(/1", "stable(value)", dir_path, ".tmp" }) |sensitive| {
        try std.testing.expect(std.mem.indexOf(u8, output.stdout, sensitive) == null);
        try std.testing.expect(std.mem.indexOf(u8, output.stderr, sensitive) == null);
    }

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "absent.pl", .{}));
    {
        var entries = tmp.dir.iterate();
        while (try entries.next(std.testing.io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, "absent.pl.tmp"));
        }
    }

    try std.testing.expectError(
        engine_mod.EngineError.LoadFailed,
        Snapshot.generate(std.testing.allocator, engine, dir_path, "existing", std.testing.io),
    );
    {
        var entries = tmp.dir.iterate();
        while (try entries.next(std.testing.io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, "existing.pl.tmp"));
        }
    }

    const preserved_bytes = try tmp.dir.readFileAlloc(std.testing.io, "existing.pl", std.testing.allocator, .limited(8192));
    defer std.testing.allocator.free(preserved_bytes);
    try std.testing.expectEqualSlices(u8, original_bytes, preserved_bytes);
}

test "snapshot round-trip preserves separator-bearing fact arguments in a fresh engine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("adr(parser, accepted, 'https://example.test/std::fs/head :- body')");
    try engine.assertFact("impl_note(parser, 'std::fs', 'head :- body')");
    try engine.assertFact("resolved(parser, 'https://example.test/a:b')");
    try engine.assertFact("seg:foo('module:value :- body')");

    var snap = try Snapshot.generate(std.testing.allocator, engine, dir_path, "separators", std.testing.io);
    defer snap.deinit();

    const content = try tmp.dir.readFileAlloc(std.testing.io, "separators.pl", std.testing.allocator, .limited(16 * 1024));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, ":- dynamic(adr/3)."));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, ":- dynamic(impl_note/3)."));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, ":- dynamic(resolved/2)."));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, ":- dynamic(seg:foo/1)."));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, content, ":- dynamic(adr(parser"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, content, ":- dynamic(impl_note(parser"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, content, ":- dynamic(resolved(parser"));

    var restored = try Engine.init(.{}, std.testing.io);
    defer restored.deinit();
    try snap.restore(restored);

    var adr = try restored.query("adr(parser, accepted, 'https://example.test/std::fs/head :- body')");
    defer adr.deinit();
    try std.testing.expectEqual(@as(usize, 1), adr.solutions.len);

    var impl_note = try restored.query("impl_note(parser, 'std::fs', 'head :- body')");
    defer impl_note.deinit();
    try std.testing.expectEqual(@as(usize, 1), impl_note.solutions.len);

    var resolved = try restored.query("resolved(parser, 'https://example.test/a:b')");
    defer resolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), resolved.solutions.len);

    try restored.assertFact("adr(snapshot, accepted, 'post:restore :- mutable')");
    var after_assert = try restored.query("adr(_, _, _)");
    defer after_assert.deinit();
    try std.testing.expectEqual(@as(usize, 2), after_assert.solutions.len);
}
