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

        {
            const tmp_file = try dir.createFile(tmp_name, .{});
            defer tmp_file.close();
            const ts = std.time.timestamp();
            var hdr_buf: [64]u8 = undefined;
            const hdr = try std.fmt.bufPrint(&hdr_buf, "%% zpm snapshot {d}\n", .{ts});
            try tmp_file.writeAll(hdr);
            writeClausesToFile(allocator, engine, tmp_file) catch {};
        }

        try dir.rename(tmp_name, snapshot_name);

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, snapshot_name });
        errdefer allocator.free(full_path);

        return Snapshot{ .allocator = allocator, .name = snapshot_name, .path = full_path };
    }

    pub fn restore(self: *const Snapshot, engine: *Engine) !void {
        try engine.loadFile(self.path);
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.name);
        self.allocator.free(self.path);
    }
};

fn writeClausesToFile(allocator: std.mem.Allocator, engine: *Engine, file: std.fs.File) !void {
    var result = try engine.query(
        "current_predicate(F/A),functor(H,F,A),predicate_property(H,dynamic),clause(H,B)",
    );
    defer result.deinit();

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        seen.deinit();
    }

    for (result.solutions) |sol| {
        const h = sol.bindings.get("H") orelse continue;
        const b = sol.bindings.get("B") orelse continue;

        const head_str = term_utils.termToString(allocator, h) catch continue;
        defer allocator.free(head_str);
        const body_str = term_utils.termToString(allocator, b) catch continue;
        defer allocator.free(body_str);

        const is_fact = switch (b) {
            .atom => |s| std.mem.eql(u8, s, "true"),
            else => false,
        };

        var line_buf: [4096]u8 = undefined;
        const line = if (is_fact)
            try std.fmt.bufPrint(&line_buf, "{s}.\n", .{head_str})
        else
            try std.fmt.bufPrint(&line_buf, "{s} :- {s}.\n", .{ head_str, body_str });

        const gop = try seen.getOrPut(try allocator.dupe(u8, line));
        if (gop.found_existing) {
            allocator.free(gop.key_ptr.*);
            continue;
        }
        try file.writeAll(line);
    }
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
