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

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8, snapshot_dir_path: []const u8) !PersistenceManager {
        const owned = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned);
        const owned_snap = try allocator.dupe(u8, snapshot_dir_path);
        errdefer allocator.free(owned_snap);

        var dir = std.fs.openDirAbsolute(owned, .{}) catch blk: {
            std.fs.makeDirAbsolute(owned) catch {
                return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = null, .status = .degraded };
            };
            break :blk std.fs.openDirAbsolute(owned, .{}) catch {
                return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = null, .status = .degraded };
            };
        };
        dir.close();

        if (std.fs.openDirAbsolute(owned_snap, .{})) |snap_dir| {
            var d = snap_dir;
            d.close();
        } else |_| {
            std.fs.makeDirAbsolute(owned_snap) catch {};
        }

        const wal_or_err = WriteAheadLog.init(allocator, owned);
        const wal = wal_or_err catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {
                return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = null, .status = .degraded };
            },
            else => return err,
        };

        return .{ .allocator = allocator, .dir_path = owned, .snapshot_dir_path = owned_snap, .wal = wal, .status = .active };
    }

    pub fn restore(self: *PersistenceManager, engine: *Engine) !void {
        if (self.status != .active) return;

        const snaps = try snapshot_mod.list(self.allocator, self.snapshot_dir_path);
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

    pub fn saveSnapshot(self: *PersistenceManager, engine: *Engine, name: []const u8) !void {
        if (self.status != .active) return;
        var snap = try snapshot_mod.Snapshot.generate(self.allocator, engine, self.snapshot_dir_path, name);
        defer snap.deinit();
        if (self.wal) |*w| {
            try w.rotate();
            self.cleanArchivedWals();
        }
    }

    fn cleanArchivedWals(self: *PersistenceManager) void {
        var dir = std.fs.openDirAbsolute(self.dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "journal.")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wal")) continue;
            // Keep the active journal.wal, delete archived journal.*.wal
            if (std.mem.eql(u8, entry.name, "journal.wal")) continue;
            dir.deleteFile(entry.name) catch {};
        }
    }

    pub fn restoreSnapshot(self: *PersistenceManager, engine: *Engine, name: []const u8) !void {
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
        return snapshot_mod.list(allocator, self.snapshot_dir_path);
    }

    pub fn getStatus(self: *const PersistenceManager) PersistenceStatus {
        return self.status;
    }
};

test "init with valid directory returns active manager" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, manager.getStatus());
}

test "init with non-writable path returns degraded manager" {
    var manager = try PersistenceManager.init(std.testing.allocator, "/proc/no_write_access_zpm", "/proc/no_write_access_zpm");
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.degraded, manager.getStatus());
}

test "journalMutation records entry when manager is active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer manager.deinit();

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);
}

test "journalMutation is no-op when manager is degraded" {
    var manager = try PersistenceManager.init(std.testing.allocator, "/proc/no_write_access_zpm", "/proc/no_write_access_zpm");
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.degraded, manager.getStatus());
    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);
}

test "listSnapshots returns snapshot filenames in persistence directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    (try tmp.dir.createFile("kb1.pl", .{})).close();
    (try tmp.dir.createFile("kb2.pl", .{})).close();
    (try tmp.dir.createFile("journal.wal", .{})).close();

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
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
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, manager.getStatus());

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try manager.saveSnapshot(engine, "kb_snap");

    _ = try tmp.dir.statFile("kb_snap.pl");
}

test "init with separate data and snapshot directories stores both paths" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
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
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    (try kb_tmp.dir.createFile("kb1.pl", .{})).close();

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
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
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
    defer manager.deinit();

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try manager.saveSnapshot(engine, "test_snap");

    _ = try kb_tmp.dir.statFile("test_snap.pl");
}

test "getStatus returns active for valid directory and degraded for non-writable path" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    var active = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
    defer active.deinit();
    try std.testing.expectEqual(PersistenceStatus.active, active.getStatus());

    var degraded = try PersistenceManager.init(std.testing.allocator, "/nonexistent/path/zpm_test", kb_dir);
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
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    // Place a snapshot .pl file in the snapshot dir (kb_dir)
    try kb_tmp.dir.writeFile(.{ .sub_path = "backup.pl", .data = "restored_fact(hello).\n" });

    const engine = try Engine.init(.{});
    defer engine.deinit();

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
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
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf);

    var manager = try PersistenceManager.init(std.testing.allocator, "/nonexistent/path/zpm_test", kb_dir);
    defer manager.deinit();
    try std.testing.expectEqual(PersistenceStatus.degraded, manager.getStatus());

    const engine = try Engine.init(.{});
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
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    try kb_tmp.dir.writeFile(.{ .sub_path = "mysnap.pl", .data = "snap_loaded(yes).\n" });

    const engine = try Engine.init(.{});
    defer engine.deinit();

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
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
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    // std.testing.allocator detects leaks automatically
    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
    manager.deinit();
}

test "restore propagates loadFile error for corrupt snapshot" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var kb_tmp = std.testing.tmpDir(.{});
    defer kb_tmp.cleanup();

    var path_buf1: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir = try data_tmp.dir.realpath(".", &path_buf1);
    const kb_dir = try kb_tmp.dir.realpath(".", &path_buf2);

    // Corrupt snapshot — unterminated quoted atom triggers Trealla parse error.
    try kb_tmp.dir.writeFile(.{ .sub_path = "broken.pl", .data = "bad(unclosed\n" });

    const engine = try Engine.init(.{});
    defer engine.deinit();

    var manager = try PersistenceManager.init(std.testing.allocator, data_dir, kb_dir);
    defer manager.deinit();

    // With the fix, restore must bubble the load error rather than silently
    // leaving an empty KB. The previous `engine.loadFile(...) catch {}` made
    // boot succeed against a corrupt snapshot.
    try std.testing.expectError(
        @import("../prolog/engine.zig").EngineError.LoadFailed,
        manager.restore(engine),
    );
}
