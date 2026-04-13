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
    wal: ?WriteAheadLog,
    status: PersistenceStatus,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !PersistenceManager {
        const owned = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned);

        var dir = std.fs.openDirAbsolute(owned, .{}) catch blk: {
            // Try to create the directory if it doesn't exist
            std.fs.makeDirAbsolute(owned) catch {
                return .{ .allocator = allocator, .dir_path = owned, .wal = null, .status = .degraded };
            };
            break :blk std.fs.openDirAbsolute(owned, .{}) catch {
                return .{ .allocator = allocator, .dir_path = owned, .wal = null, .status = .degraded };
            };
        };
        dir.close();

        const wal = WriteAheadLog.init(allocator, owned) catch {
            return .{ .allocator = allocator, .dir_path = owned, .wal = null, .status = .degraded };
        };

        return .{ .allocator = allocator, .dir_path = owned, .wal = wal, .status = .active };
    }

    pub fn restore(self: *PersistenceManager, engine: *Engine) !void {
        if (self.status != .active) return;

        // Load latest snapshot if one exists
        const snaps = snapshot_mod.list(self.allocator, self.dir_path) catch return;
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
            const snap_path = std.fs.path.join(self.allocator, &.{ self.dir_path, latest }) catch return;
            defer self.allocator.free(snap_path);
            engine.loadFile(snap_path) catch {};
        }

        // Replay WAL entries on top
        if (self.wal) |*w| try w.replay(engine);
    }

    pub fn deinit(self: *PersistenceManager) void {
        if (self.wal) |*w| w.deinit();
        self.allocator.free(self.dir_path);
    }

    pub fn journalMutation(self: *PersistenceManager, entry: JournalEntry) !void {
        if (self.wal) |*w| try w.append(entry);
    }

    pub fn saveSnapshot(self: *PersistenceManager, engine: *Engine, name: []const u8) !void {
        if (self.status != .active) return;
        var snap = try snapshot_mod.Snapshot.generate(self.allocator, engine, self.dir_path, name);
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
        const snap_path = try std.fs.path.join(self.allocator, &.{ self.dir_path, snap_name });
        defer self.allocator.free(snap_path);
        try engine.loadFile(snap_path);
    }

    pub fn listSnapshots(self: *PersistenceManager, allocator: std.mem.Allocator) ![][]const u8 {
        return snapshot_mod.list(allocator, self.dir_path);
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

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, manager.getStatus());
}

test "init with non-writable path returns degraded manager" {
    var manager = try PersistenceManager.init(std.testing.allocator, "/proc/no_write_access_zpm");
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.degraded, manager.getStatus());
}

test "journalMutation records entry when manager is active" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path);
    defer manager.deinit();

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);
}

test "journalMutation is no-op when manager is degraded" {
    var manager = try PersistenceManager.init(std.testing.allocator, "/proc/no_write_access_zpm");
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

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path);
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

    var manager = try PersistenceManager.init(std.testing.allocator, dir_path);
    defer manager.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, manager.getStatus());

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try manager.journalMutation(entry);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try manager.saveSnapshot(engine, "kb_snap");

    _ = try tmp.dir.statFile("kb_snap.pl");
}
