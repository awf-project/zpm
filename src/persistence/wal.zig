const std = @import("std");
const Engine = @import("../prolog/engine.zig").Engine;

pub const Operation = enum {
    assert,
    retract,
    retractall,

    pub fn tag(self: Operation) []const u8 {
        return switch (self) {
            .assert => "assert",
            .retract => "retract",
            .retractall => "retractall",
        };
    }

    pub fn parse(s: []const u8) ?Operation {
        if (std.mem.eql(u8, s, "assert")) return .assert;
        if (std.mem.eql(u8, s, "retract")) return .retract;
        if (std.mem.eql(u8, s, "retractall")) return .retractall;
        return null;
    }
};

pub const JournalEntry = struct {
    timestamp: i64,
    op: Operation = .assert,
    clause: []const u8,
};

pub const WriteAheadLog = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !WriteAheadLog {
        const owned = try allocator.dupe(u8, dir_path);
        return WriteAheadLog{ .allocator = allocator, .dir_path = owned };
    }

    pub fn deinit(self: *WriteAheadLog) void {
        self.allocator.free(self.dir_path);
    }

    pub fn append(self: *WriteAheadLog, entry: JournalEntry) !void {
        var dir = try std.fs.openDirAbsolute(self.dir_path, .{});
        defer dir.close();
        const file = try dir.createFile("journal.wal", .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);
        var line_buf: [4096]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "%% {d} {s} {s}.\n", .{ entry.timestamp, entry.op.tag(), entry.clause });
        try file.writeAll(line);
    }

    pub fn replay(self: *WriteAheadLog, engine: *Engine) !void {
        var dir = std.fs.openDirAbsolute(self.dir_path, .{}) catch return;
        defer dir.close();
        const file = dir.openFile("journal.wal", .{}) catch return;
        defer file.close();
        var buf: [65536]u8 = undefined;
        const n = try file.readAll(&buf);
        var iter = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (iter.next()) |line| {
            const entry = parseEntry(line) orelse continue;
            switch (entry.op) {
                .assert => engine.assertFact(entry.clause) catch {},
                .retract => engine.retractFact(entry.clause) catch {},
                .retractall => engine.retractAll(entry.clause) catch {},
            }
        }
    }

    pub fn parseEntry(line: []const u8) ?JournalEntry {
        if (!std.mem.startsWith(u8, line, "%% ")) return null;
        const rest = line[3..];
        // Parse timestamp
        const sp1 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        const ts_str = rest[0..sp1];
        const timestamp = std.fmt.parseInt(i64, ts_str, 10) catch return null;
        const after_ts = rest[sp1 + 1 ..];
        // Parse operation
        const sp2 = std.mem.indexOfScalar(u8, after_ts, ' ') orelse return null;
        const op_str = after_ts[0..sp2];
        const op = Operation.parse(op_str) orelse return null;
        // Parse clause
        const clause_with_dot = after_ts[sp2 + 1 ..];
        if (clause_with_dot.len == 0) return null;
        const clause = if (std.mem.endsWith(u8, clause_with_dot, "."))
            clause_with_dot[0 .. clause_with_dot.len - 1]
        else
            clause_with_dot;
        return JournalEntry{ .timestamp = timestamp, .op = op, .clause = clause };
    }

    pub fn rotate(self: *WriteAheadLog) !void {
        var dir = std.fs.openDirAbsolute(self.dir_path, .{}) catch return;
        defer dir.close();
        const ts = std.time.timestamp();
        var buf: [64]u8 = undefined;
        const archived = try std.fmt.bufPrint(&buf, "journal.{d}.wal", .{ts});
        dir.rename("journal.wal", archived) catch {};
    }
};

test "init creates WriteAheadLog for valid directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path);
    defer wal.deinit();

    try std.testing.expectEqualStrings(dir_path, wal.dir_path);
}

test "append records a journal entry without error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path);
    defer wal.deinit();

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try wal.append(entry);
}

test "append writes entry in prolog comment format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path);
    defer wal.deinit();

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try wal.append(entry);

    var content_buf: [256]u8 = undefined;
    const n = try tmp.dir.readFile("journal.wal", &content_buf);
    try std.testing.expectEqualStrings("%% 1713000000 assert fact(a).\n", n);
}

test "replay asserts journal entries into engine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path);
    defer wal.deinit();

    try wal.append(.{ .timestamp = 1713000000, .clause = "fruit(apple)" });
    try wal.append(.{ .timestamp = 1713000001, .clause = "fruit(banana)" });

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try wal.replay(engine);

    var result = try engine.query("fruit(X)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.solutions.len);
}

test "parseEntry parses valid journal line into JournalEntry" {
    const entry = WriteAheadLog.parseEntry("%% 1713000000 assert fact(a).") orelse
        return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(i64, 1713000000), entry.timestamp);
    try std.testing.expectEqual(Operation.assert, entry.op);
    try std.testing.expectEqualStrings("fact(a)", entry.clause);
}

test "parseEntry returns null for lines not in journal format" {
    try std.testing.expect(WriteAheadLog.parseEntry("fact(a).") == null);
    try std.testing.expect(WriteAheadLog.parseEntry("") == null);
    try std.testing.expect(WriteAheadLog.parseEntry("%% 1713000000") == null);
    try std.testing.expect(WriteAheadLog.parseEntry("%% 1713000000 badop fact(a).") == null);
}

test "replay is no-op when journal file does not exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path);
    defer wal.deinit();

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try wal.replay(engine);
}
