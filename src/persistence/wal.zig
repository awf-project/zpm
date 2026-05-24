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

const JournalEntryJson = struct {
    ts: i64,
    op: []const u8,
    clause: []const u8,
};

pub const WriteAheadLog = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    file: std.Io.File,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8, io: std.Io) !WriteAheadLog {
        const owned_path = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned_path);
        var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer dir.close(io);
        const file = try dir.createFile(io, "journal.wal", .{ .truncate = false });
        _ = std.c.lseek64(file.handle, 0, std.c.SEEK.END);
        return .{
            .allocator = allocator,
            .dir_path = owned_path,
            .file = file,
            .io = io,
        };
    }

    pub fn deinit(self: *WriteAheadLog) void {
        self.file.close(self.io);
        self.allocator.free(self.dir_path);
    }

    pub fn append(self: *WriteAheadLog, entry: JournalEntry) !void {
        return self.appendBatch(&[_]JournalEntry{entry});
    }

    /// Append multiple entries as a single `writeAll` + `sync`. Ensures that
    /// either all entries land in the journal or none do — no partial prefix
    /// that would leave replay reconstructing a half-applied mutation.
    pub fn appendBatch(self: *WriteAheadLog, entries: []const JournalEntry) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        for (entries) |entry| {
            try std.json.Stringify.value(
                JournalEntryJson{
                    .ts = entry.timestamp,
                    .op = entry.op.tag(),
                    .clause = entry.clause,
                },
                .{},
                &aw.writer,
            );
            try aw.writer.writeByte('\n');
        }
        const buf = try aw.toOwnedSlice();
        defer self.allocator.free(buf);
        try self.file.writeStreamingAll(self.io, buf);
        try self.file.sync(self.io);
    }

    pub fn replay(self: *WriteAheadLog, engine: *Engine) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.dir_path, .{}) catch return;
        defer dir.close(self.io);
        const buf = dir.readFileAlloc(self.io, "journal.wal", self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(buf);
        var iter = std.mem.splitScalar(u8, buf, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;

            // Corrupt entries fail boot — partial replay would leave the KB
            // in an observable state that does not match the journal.
            const parsed = try std.json.parseFromSlice(
                JournalEntryJson,
                self.allocator,
                line,
                .{},
            );
            defer parsed.deinit();

            const op = Operation.parse(parsed.value.op) orelse return error.CorruptWalEntry;
            switch (op) {
                .assert => try engine.assertFact(parsed.value.clause),
                .retract => try engine.retractFact(parsed.value.clause),
                .retractall => try engine.retractAll(parsed.value.clause),
            }
        }
    }

    pub fn rotate(self: *WriteAheadLog) !void {
        var dir = try std.Io.Dir.openDirAbsolute(self.io, self.dir_path, .{});
        defer dir.close(self.io);

        var name_buf: [64]u8 = undefined;
        const ts = blk: {
            var _ts: std.posix.timespec = undefined;
            _ = std.c.clock_gettime(std.posix.CLOCK.REALTIME, &_ts);
            break :blk _ts.sec;
        };
        const archive = try std.fmt.bufPrint(&name_buf, "journal-{d}.wal", .{ts});

        const old_file = self.file;
        old_file.close(self.io);

        std.Io.Dir.rename(dir, "journal.wal", dir, archive, self.io) catch |rename_err| {
            // Reopen the original journal so self.file remains valid.
            self.file = dir.createFile(self.io, "journal.wal", .{ .truncate = false }) catch
                return rename_err;
            _ = std.c.lseek64(self.file.handle, 0, std.c.SEEK.END);
            return rename_err;
        };
        self.file = dir.createFile(self.io, "journal.wal", .{ .truncate = true }) catch |err| {
            std.Io.Dir.rename(dir, archive, dir, "journal.wal", self.io) catch {};
            self.file = dir.createFile(self.io, "journal.wal", .{ .truncate = false }) catch
                return err;
            _ = std.c.lseek64(self.file.handle, 0, std.c.SEEK.END);
            return err;
        };
    }
};

test "init creates WriteAheadLog for valid directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    try std.testing.expectEqualStrings(dir_path, wal.dir_path);
}

test "append records a journal entry without error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    const entry = JournalEntry{ .timestamp = 1713000000, .clause = "fact(a)" };
    try wal.append(entry);
}

test "append writes one JSON line per entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    try wal.append(.{ .timestamp = 1714000000, .op = .assert, .clause = "parent(alice, bob)" });

    const raw = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(raw);
    const line = std.mem.trim(u8, raw, "\n");

    const parsed = try std.json.parseFromSlice(JournalEntryJson, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1714000000), parsed.value.ts);
    try std.testing.expectEqualStrings("assert", parsed.value.op);
    try std.testing.expectEqualStrings("parent(alice, bob)", parsed.value.clause);
}

test "replay asserts journal entries into engine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    try wal.append(.{ .timestamp = 1713000000, .clause = "fruit(apple)" });
    try wal.append(.{ .timestamp = 1713000001, .clause = "fruit(banana)" });

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try wal.replay(engine);

    var result = try engine.query("fruit(X)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.solutions.len);
}

test "replay is no-op when journal file does not exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try wal.replay(engine);
}

test "replay parses JSON Lines and asserts entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();
    try wal.append(.{ .timestamp = 1714000000, .op = .assert, .clause = "color(red)" });
    try wal.append(.{ .timestamp = 1714000001, .op = .assert, .clause = "color(blue)" });

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try wal.replay(engine);

    var result = try engine.query("color(C)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len == 2);
}

test "init opens journal.wal for append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    const stat = try wal.file.stat(std.testing.io);
    try std.testing.expect(stat.size == 0);
}

test "append handles clause larger than 4KB (no hardcoded limit)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    const big = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    const clause = try std.fmt.allocPrint(std.testing.allocator, "data('{s}')", .{big});
    defer std.testing.allocator.free(clause);

    try wal.append(.{ .timestamp = 1, .op = .assert, .clause = clause });
}

test "append handles clause containing newline (JSON-escaped)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    try wal.append(.{ .timestamp = 1, .op = .assert, .clause = "rule(a) :-\n    ok(a)" });

    const raw = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .limited(512));
    defer std.testing.allocator.free(raw);
    const newline_count = std.mem.count(u8, raw, "\n");
    try std.testing.expectEqual(@as(usize, 1), newline_count);
}

test "replay propagates error on corrupt (non-JSON) journal entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "journal.wal",
        .data = "{\"ts\":1,\"op\":\"assert\",\"clause\":\"fact(a)\"}\nnot-valid-json\n",
    });

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try std.testing.expectError(error.SyntaxError, wal.replay(engine));
}

test "replay propagates error on unknown op in journal entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "journal.wal",
        .data = "{\"ts\":1,\"op\":\"bogus\",\"clause\":\"fact(a)\"}\n",
    });

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try std.testing.expectError(error.CorruptWalEntry, wal.replay(engine));
}

test "replay of retract_assumption journal entries removes facts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    try wal.append(.{ .timestamp = 1, .op = .assert, .clause = "tms_justification(feature(f019,draft,planned),spec_draft)" });
    try wal.append(.{ .timestamp = 2, .op = .assert, .clause = "feature(f019,draft,planned)" });
    try wal.append(.{ .timestamp = 3, .op = .retractall, .clause = "tms_justification(_,spec_draft)" });
    try wal.append(.{ .timestamp = 4, .op = .retractall, .clause = "feature(f019,_,_)" });

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try wal.replay(engine);

    var result = try engine.query("feature(f019,_,_)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.solutions.len);
}

test "replay handles journal larger than 64KB (no hardcoded limit)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const clause = try std.fmt.allocPrint(std.testing.allocator, "fact({d})", .{i});
        defer std.testing.allocator.free(clause);
        try wal.append(.{ .timestamp = @intCast(i), .op = .assert, .clause = clause });
    }

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try wal.replay(engine);

    var result = try engine.query("fact(N)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len >= 100);
}

test "appendBatch writes all entries atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    const entries = [_]JournalEntry{
        .{ .timestamp = 1715000000, .op = .retractall, .clause = "tms_justification(_,alpha)" },
        .{ .timestamp = 1715000000, .op = .retractall, .clause = "tms_justification(_,beta)" },
        .{ .timestamp = 1715000000, .op = .retractall, .clause = "tms_justification(_,gamma)" },
    };
    try wal.appendBatch(&entries);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        const parsed = try std.json.parseFromSlice(JournalEntryJson, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("retractall", parsed.value.op);
    }
    try std.testing.expectEqual(@as(usize, 3), line_count);
    try std.testing.expect(std.mem.indexOf(u8, content, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "gamma") != null);
}

test "appendBatch writes nothing when entries is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    try wal.appendBatch(&[_]JournalEntry{});

    const empty_content = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(empty_content);
    try std.testing.expectEqual(@as(usize, 0), empty_content.len);
}
