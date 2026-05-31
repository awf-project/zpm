const std = @import("std");
const Engine = @import("../prolog/engine.zig").Engine;
const WriteAheadLog = @import("wal.zig").WriteAheadLog;
const JournalEntry = @import("wal.zig").JournalEntry;
const snapshot_mod = @import("snapshot.zig");

pub const PersistenceStatus = enum {
    active,
    degraded,
    disabled,
};

pub const PersistenceManager = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    snapshot_dir_path: []const u8,
    wal: ?WriteAheadLog,
    status: PersistenceStatus,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8, snapshot_dir_path: []const u8, io: std.Io) !PersistenceManager {
        const owned = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned);
        const owned_snap = try allocator.dupe(u8, snapshot_dir_path);
        errdefer allocator.free(owned_snap);

        var dir = std.Io.Dir.openDirAbsolute(io, owned, .{}) catch blk: {
            std.Io.Dir.cwd().createDir(io, owned, .default_dir) catch {
                return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = null, .status = .degraded, .io = io };
            };
            break :blk std.Io.Dir.openDirAbsolute(io, owned, .{}) catch {
                return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = null, .status = .degraded, .io = io };
            };
        };
        dir.close(io);

        if (std.Io.Dir.openDirAbsolute(io, owned_snap, .{})) |snap_dir| {
            var d = snap_dir;
            d.close(io);
        } else |_| {
            std.Io.Dir.cwd().createDir(io, owned_snap, .default_dir) catch {};
        }

        const wal_or_err = WriteAheadLog.init(allocator, owned, io);
        const wal = wal_or_err catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {
                return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = null, .status = .degraded, .io = io };
            },
            else => return err,
        };

        return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = wal, .status = .active, .io = io };
    }

    pub fn restore(self: *PersistenceManager, engine: *Engine) !void {
        if (self.status != .active) return;

        const snaps = try snapshot_mod.list(self.allocator, self.snapshot_dir_path, self.io);
        defer {
            for (snaps) |s| self.allocator.free(s);
            self.allocator.free(snaps);
        }
        if (snaps.len > 0) {
            std.mem.sort([]const u8, snaps, {}, struct {
                fn cmp(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.cmp);
            // Take the last (newest by lexicographic/timestamp order)
            const latest = snaps[snaps.len - 1];
            const snap_path = try std.fs.path.join(self.allocator, &.{ self.snapshot_dir_path, latest });
            defer self.allocator.free(snap_path);
            // Corrupt snapshot fails boot; recovery is `rm -rf .zpm/kb/`.
            try engine.loadFile(snap_path);
        }

        if (self.wal) |*w| try w.replay(engine);
    }

    pub fn deinit(self: *PersistenceManager) void {
        if (self.wal) |*w| w.deinit();
        self.allocator.free(self.dir_path);
        self.allocator.free(self.snapshot_dir_path);
    }

    pub fn journalMutation(self: *PersistenceManager, entry: JournalEntry) !void {
        if (self.wal) |*w| try w.append(entry);
    }

    /// Journal multiple entries atomically — either all land in the WAL or
    /// none do. Use this for multi-step mutations like `retract_assumption`
    /// to prevent replay reconstructing a half-applied intermediate state.
    pub fn journalMutations(self: *PersistenceManager, entries: []const JournalEntry) !void {
        if (self.wal) |*w| try w.appendBatch(entries);
    }

    pub fn saveSnapshot(self: *PersistenceManager, engine: *Engine, name: []const u8) !void {
        if (self.status != .active) return;
        // Guard: for per-segment PMs, snapshot_dir_path == disk_path (the same
        // directory that holds knowledge.pl). A snapshot named "knowledge" would
        // produce knowledge.pl and silently overwrite the segment's base file on
        // the next write cycle. Reject names that, after appending ".pl", would
        // collide with knowledge.pl regardless of which PM variant is in use.
        if (std.mem.eql(u8, name, "knowledge") or std.mem.eql(u8, name, "knowledge.pl")) {
            return error.InvalidName;
        }
        var snap = try snapshot_mod.Snapshot.generate(self.allocator, engine, self.snapshot_dir_path, name, self.io);
        defer snap.deinit();
        if (self.wal) |*w| {
            try w.rotate();
            self.cleanArchivedWals();
        }
    }

    fn cleanArchivedWals(self: *PersistenceManager) void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "journal.")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
            // Keep the active journal.wal, delete archived journal.*.wal
            if (std.mem.eql(u8, entry.name, "journal.wal")) continue;
            dir.deleteFile(self.io, entry.name) catch {};
        }
    }

    pub fn restoreSnapshot(self: *PersistenceManager, engine: *Engine, name: []const u8) !void {
        // Mirror the save guard: "knowledge" would resolve to knowledge.pl which
        // is the segment base file, not a user snapshot.
        if (std.mem.eql(u8, name, "knowledge") or std.mem.eql(u8, name, "knowledge.pl")) {
            return error.InvalidName;
        }
        const snap_name = if (std.mem.endsWith(u8, name, ".pl"))
            try self.allocator.dupe(u8, name)
        else
            try std.fmt.allocPrint(self.allocator, "{s}.pl", .{name});
        defer self.allocator.free(snap_name);
        const snap_path = try std.fs.path.join(self.allocator, &.{ self.snapshot_dir_path, snap_name });
        defer self.allocator.free(snap_path);
        // Mirrors Snapshot.restore: pl_consult is additive, so wipe first.
        try engine.resetUserKnowledge();
        try engine.loadFile(snap_path);
    }

    pub fn listSnapshots(self: *PersistenceManager, allocator: std.mem.Allocator) ![][]const u8 {
        return snapshot_mod.list(allocator, self.snapshot_dir_path, self.io);
    }

    pub fn getStatus(self: *const PersistenceManager) PersistenceStatus {
        return self.status;
    }
};

test "init with valid directory returns active manager" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, manager.getStatus());
}

test "init with non-writable path returns degraded manager" {
    var manager = try PersistenceManager.init(std.testing.allocator, "/proc/no_write_access_zpm", "/proc/no_write_access_zpm", std.testing.io);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.degraded, manager.getStatus());
}

test "journalMutation records entry when manager is active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer manager.deinit();

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);
}

test "journalMutation is no-op when manager is degraded" {
    var manager = try PersistenceManager.init(std.testing.allocator, "/proc/no_write_access_zpm", "/proc/no_write_access_zpm", std.testing.io);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.degraded, manager.getStatus());
    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);
}

test "journalMutations batches WAL entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer manager.deinit();

    const entries = [_]JournalEntry{
        .{ .timestamp = 1715000000, .op = .retractall, .clause = "tms_justification(_,alpha)" },
        .{ .timestamp = 1715000000, .op = .retractall, .clause = "tms_justification(_,beta)" },
    };
    try manager.journalMutations(&entries);

    var content_buf: [1024]u8 = undefined;
    const content = try tmp.dir.readFile(std.testing.io, "journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "beta") != null);

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len != 0) line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "listSnapshots returns snapshot filenames in persistence directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    (try tmp.dir.createFile(std.testing.io, "kb1.pl", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "kb2.pl", .{})).close(std.testing.io);
    (try tmp.dir.createFile(std.testing.io, "journal.wal", .{})).close(std.testing.io);

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer manager.deinit();

    const snaps = try manager.listSnapshots(std.testing.allocator);
    defer {
        for (snaps) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(snaps);
    }

    try std.testing.expectEqual(@as(usize, 2), snaps.len);
}

test "saveSnapshot creates snapshot file and rotates WAL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path, std.testing.io);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, manager.getStatus());

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try manager.saveSnapshot(engine, "kb_snap");

    _ = try tmp.dir.statFile(std.testing.io, "kb_snap.pl", .{});
}

test "init with separate data and snapshot directories stores both paths" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, manager.getStatus());
    try std.testing.expectEqualStrings(data_dir, manager.dir_path);
    try std.testing.expectEqualStrings(kb_dir, manager.snapshot_dir_path);
}

test "listSnapshots reads from snapshot_dir_path not dir_path" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    (try kb_tmp.dir.createFile(std.testing.io, "kb1.pl", .{})).close(std.testing.io);

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    defer manager.deinit();

    const snaps = try manager.listSnapshots(std.testing.allocator);
    defer {
        for (snaps) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(snaps);
    }

    try std.testing.expectEqual(@as(usize, 1), snaps.len);
}

test "saveSnapshot writes to snapshot_dir_path not dir_path" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    defer manager.deinit();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try manager.saveSnapshot(engine, "test_snap");

    _ = try kb_tmp.dir.statFile(std.testing.io, "test_snap.pl", .{});
}

test "getStatus returns active for valid directory and degraded for non-writable path" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    var active = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    defer active.deinit();
    try std.testing.expectEqual(PersistenceStatus.active, active.getStatus());

    var degraded = try PersistenceManager.init(std.testing.allocator, "/nonexistent/path/zpm_test", kb_dir, std.testing.io);
    defer degraded.deinit();
    try std.testing.expectEqual(PersistenceStatus.degraded, degraded.getStatus());
}

test "restore loads latest snapshot from snapshot_dir_path and replays WAL" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    // Place a snapshot .pl file in the snapshot dir (kb_dir)
    try kb_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "backup.pl", .data = "restored_fact(hello).\n" });

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    defer manager.deinit();

    try manager.restore(engine);

    // Verify the snapshot was loaded into the engine
    var result = try engine.query("restored_fact(X)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len > 0);
}

test "restore is no-op when manager is degraded" {
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const kb_dir = path_buf[0..kb_dir_len];

    var manager = try PersistenceManager.init(std.testing.allocator, "/nonexistent/path/zpm_test", kb_dir, std.testing.io);
    defer manager.deinit();
    try std.testing.expectEqual(PersistenceStatus.degraded, manager.getStatus());

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    // Should return without error (no-op)
    try manager.restore(engine);
}

test "restoreSnapshot loads snapshot from snapshot_dir_path" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    try kb_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mysnap.pl", .data = "snap_loaded(yes).\n" });

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    defer manager.deinit();

    try manager.restoreSnapshot(engine, "mysnap");

    var result = try engine.query("snap_loaded(X)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len > 0);
}

test "deinit frees dir_path and snapshot_dir_path without leak" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    // std.testing.allocator detects leaks automatically
    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    manager.deinit();
}

test "restore propagates loadFile error for corrupt snapshot" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir_len = try data_tmp.dir.realPathFile(std.testing.io, ".", &path_buf1);
    const data_dir = path_buf1[0..data_dir_len];
    const kb_dir_len = try kb_tmp.dir.realPathFile(std.testing.io, ".", &path_buf2);
    const kb_dir = path_buf2[0..kb_dir_len];

    // Corrupt snapshot — unterminated quoted atom triggers Trealla parse error.
    try kb_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "broken.pl", .data = "bad(unclosed\n" });

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir, std.testing.io);
    defer manager.deinit();

    // With the fix, restore must bubble the load error rather than silently
    // leaving an empty KB. The previous `engine.loadFile(...) catch {}` made
    // boot succeed against a corrupt snapshot.
    try std.testing.expectError(
        @import("../prolog/engine.zig").EngineError.LoadFailed,
        manager.restore(engine),
    );
}
