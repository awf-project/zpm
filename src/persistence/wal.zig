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

pub fn nowSeconds() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.posix.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

test "nowSeconds returns a positive epoch timestamp" {
    try std.testing.expect(nowSeconds() > 0);
}

const JournalEntryJson = struct {
    ts: i64,
    op: []const u8,
    clause: []const u8,
};

/// Mode for journal/lock files created via openat (rw-r--r--).
const journal_file_mode: std.posix.mode_t = 0o644;

/// Open (creating if absent) the active journal in O_APPEND mode: the kernel
/// positions every write at EOF, so concurrent writers can't clobber records.
fn openAppendJournal(dir: std.Io.Dir) !std.Io.File {
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = try std.posix.openat(dir.handle, "journal.wal", flags, journal_file_mode);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Persistent advisory-lock target. Unlike journal.wal (which rotate() renames),
/// it is never swapped out, so a lock held on it spans a rotation.
fn openLockFile(dir: std.Io.Dir) !std.Io.File {
    const flags: std.posix.O = .{ .ACCMODE = .RDWR, .CREAT = true };
    const fd = try std.posix.openat(dir.handle, "journal.lock", flags, journal_file_mode);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Acquire an exclusive advisory lock (blocking), serializing the multi-syscall
/// write sequence across processes.
fn lockEx(fd: std.posix.fd_t) !void {
    while (true) {
        if (std.c.flock(fd, std.posix.LOCK.EX) == 0) return;
        if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue; // spurious; retry
        return error.FlockFailed;
    }
}

/// Release the advisory lock. flock auto-releases on close(), so a missed
/// unlock is non-fatal.
fn unlock(fd: std.posix.fd_t) void {
    _ = std.c.flock(fd, std.posix.LOCK.UN);
}

/// Truncate the journal file to `n` bytes (torn-tail recovery).
fn truncateTo(fd: std.posix.fd_t, n: u64) !void {
    const len: std.c.off_t = @intCast(n);
    if (std.c.ftruncate(fd, len) != 0) return error.TruncateFailed;
}

/// Open the live journal by path, truncate to `n` bytes, persist. Re-opened
/// (not cached) so it targets the current inode, never a rotated-away one.
fn truncateJournal(io: std.Io, dir: std.Io.Dir, n: u64) !void {
    var jf = try openAppendJournal(dir);
    defer jf.close(io);
    try truncateTo(jf.handle, n);
    try jf.sync(io);
}

pub const WriteAheadLog = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    // The journal fd is deliberately NOT cached: every op re-opens journal.wal
    // by path (always the live inode) and serializes on this rename-stable
    // lock_file, so a concurrent rotate() can't strand a write in the archive.
    lock_file: std.Io.File,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8, io: std.Io) !WriteAheadLog {
        const owned_path = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned_path);
        var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer dir.close(io);
        // Ensure journal.wal exists (size 0 on first boot); appends re-open it.
        const j = try openAppendJournal(dir);
        j.close(io);
        const lock_file = try openLockFile(dir);
        errdefer lock_file.close(io);
        return .{
            .allocator = allocator,
            .dir_path = owned_path,
            .lock_file = lock_file,
            .io = io,
        };
    }

    pub fn deinit(self: *WriteAheadLog) void {
        self.lock_file.close(self.io);
        self.allocator.free(self.dir_path);
    }

    pub fn append(self: *WriteAheadLog, entry: JournalEntry) !void {
        return self.appendBatch(&[_]JournalEntry{entry});
    }

    /// Append multiple entries as a single `writeAll` + `sync`. Ensures that
    /// either all entries land in the journal or none do — no partial prefix
    /// that would leave replay reconstructing a half-applied mutation.
    pub fn appendBatch(self: *WriteAheadLog, entries: []const JournalEntry) !void {
        if (entries.len == 0) return; // skip the lock + fsync for an empty batch

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

        var dir = try std.Io.Dir.openDirAbsolute(self.io, self.dir_path, .{});
        defer dir.close(self.io);
        // Lock first, THEN open the live journal: a rotate() that completed
        // before we got the lock must not leave us writing the archived inode.
        try lockEx(self.lock_file.handle);
        defer unlock(self.lock_file.handle);
        var file = try openAppendJournal(dir);
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, buf);
        try file.sync(self.io);
    }

    pub fn replay(self: *WriteAheadLog, engine: *Engine) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.dir_path, .{}) catch return;
        defer dir.close(self.io);
        // Hold the lock across the whole read+parse+truncate (replay also runs
        // at runtime via mount_memory / retract_assumptions). Otherwise a
        // concurrent append could land between our read and ftruncate, and we'd
        // truncate away a record another process already acknowledged.
        try lockEx(self.lock_file.handle);
        defer unlock(self.lock_file.handle);
        const buf = dir.readFileAlloc(self.io, "journal.wal", self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(buf);
        // Torn-tail truncate (WAL crash recovery): replay the valid prefix; on
        // the first unparseable/unknown-op line, truncate to the last good
        // record, warn, and return success. Trailing bytes after a crash- or
        // clobber-induced bad line are intentionally discarded for a usable boot.
        var good_bytes: usize = 0; // end of the last fully-applied record (incl. its newline)
        var iter = std.mem.splitScalar(u8, buf, '\n');
        while (iter.next()) |line| {
            // Offset past this line's newline (splitScalar yields buf subslices);
            // capped at buf.len for a final line with no trailing newline.
            const line_start = @intFromPtr(line.ptr) - @intFromPtr(buf.ptr);
            const after_newline = @min(line_start + line.len + 1, buf.len);

            if (line.len == 0) {
                // Blank line: valid no-op; carry the watermark past it.
                good_bytes = after_newline;
                continue;
            }

            const parsed = std.json.parseFromSlice(
                JournalEntryJson,
                self.allocator,
                line,
                .{},
            ) catch {
                // First unparseable line => torn tail.
                try truncateJournal(self.io, dir, good_bytes);
                std.log.warn("WAL torn tail at byte {d}; truncated journal (trailing bytes discarded)", .{good_bytes});
                return;
            };
            defer parsed.deinit();

            const op = Operation.parse(parsed.value.op) orelse {
                // Unknown op is also a corrupt record under torn-tail semantics.
                try truncateJournal(self.io, dir, good_bytes);
                std.log.warn("WAL corrupt op at byte {d}; truncated journal (trailing bytes discarded)", .{good_bytes});
                return;
            };
            switch (op) {
                .assert => try engine.assertFact(parsed.value.clause),
                .retract => try engine.retractFact(parsed.value.clause),
                .retractall => try engine.retractAll(parsed.value.clause),
            }
            good_bytes = after_newline;
        }
    }

    pub fn rotate(self: *WriteAheadLog) !void {
        var dir = try std.Io.Dir.openDirAbsolute(self.io, self.dir_path, .{});
        defer dir.close(self.io);

        // Lock across the whole rename+recreate so a concurrent appender blocks
        // instead of writing into the inode being archived.
        try lockEx(self.lock_file.handle);
        defer unlock(self.lock_file.handle);

        var name_buf: [64]u8 = undefined;
        var raw_ts: std.posix.timespec = undefined;
        _ = std.c.clock_gettime(std.posix.CLOCK.REALTIME, &raw_ts);
        // Nanoseconds avoid same-second archive name collisions (silent overwrite).
        const archive = try std.fmt.bufPrint(&name_buf, "journal-{d}-{d}.wal", .{ raw_ts.sec, raw_ts.nsec });

        // Rename failure leaves journal.wal intact; on success recreate it empty
        // (and the next append's O_CREAT self-heals if this open fails).
        try std.Io.Dir.rename(dir, "journal.wal", dir, archive, self.io);
        const fresh = try openAppendJournal(dir);
        fresh.close(self.io);
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

test "init creates an empty journal.wal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    // The journal fd is not cached on the struct; verify the file exists on
    // disk at size 0 (eagerly created by init for replay/stat).
    const st = try tmp.dir.statFile(std.testing.io, "journal.wal", .{});
    try std.testing.expect(st.size == 0);
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

test "replay truncates at corrupt (non-JSON) journal entry, replays good prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // WAL semantics changed: a corrupt entry no longer fails boot. Under the
    // torn-tail-truncate policy, replay applies the valid prefix, truncates the
    // journal at the first bad record, and returns success. Any data AFTER the
    // corruption (here there is none) would be intentionally discarded.
    const good = "{\"ts\":1,\"op\":\"assert\",\"clause\":\"fact(a)\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "journal.wal",
        .data = good ++ "not-valid-json\n",
    });

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try wal.replay(engine);

    // The one good fact was applied.
    var result = try engine.query("fact(X)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.solutions.len);

    // The journal was truncated to just the good prefix.
    const after = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(good, after);
}

test "replay truncates at unknown op in journal entry, replays good prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // An unknown op is a well-formed JSON line but a semantically corrupt
    // record. Under torn-tail semantics it is treated like any first-bad-record:
    // truncate at it and return success rather than propagating an error.
    const good = "{\"ts\":1,\"op\":\"assert\",\"clause\":\"fact(a)\"}\n";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "journal.wal",
        .data = good ++ "{\"ts\":2,\"op\":\"bogus\",\"clause\":\"fact(b)\"}\n",
    });

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try wal.replay(engine);

    var result = try engine.query("fact(X)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.solutions.len);

    const after = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(good, after);
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

test "concurrent writers do not clobber: every line is valid JSON and count matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // Two independent WriteAheadLog handles on the SAME journal.wal, mimicking
    // two zpm processes (e.g. overlapping MCP sessions) appending concurrently.
    var wal_a = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal_a.deinit();
    var wal_b = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal_b.deinit();

    const rounds: usize = 50;
    // Use a large clause so writeStreamingAll may split into multiple write()
    // syscalls; only flock(LOCK_EX) around the whole write serializes that.
    const big = try std.testing.allocator.alloc(u8, 2048);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    const big_clause = try std.fmt.allocPrint(std.testing.allocator, "data_b('{s}')", .{big});
    defer std.testing.allocator.free(big_clause);

    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const clause_a = try std.fmt.allocPrint(std.testing.allocator, "fact_a({d})", .{i});
        defer std.testing.allocator.free(clause_a);
        try wal_a.append(.{ .timestamp = @intCast(i), .op = .assert, .clause = clause_a });
        try wal_b.append(.{ .timestamp = @intCast(i), .op = .assert, .clause = big_clause });
    }

    const content = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(content);

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        // Each non-empty line must independently parse: no half-overwritten
        // lines and no two records packed onto one line.
        const parsed = try std.json.parseFromSlice(JournalEntryJson, std.testing.allocator, line, .{});
        defer parsed.deinit();
    }
    // 2 writers * rounds appends, none lost or clobbered.
    try std.testing.expectEqual(@as(usize, rounds * 2), line_count);
}

test "replay torn tail: valid prefix replayed, file truncated, no error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // Three valid records followed by a torn tail (partial JSON, no newline) —
    // exactly what a process killed mid-write leaves behind.
    const good_prefix =
        "{\"ts\":1,\"op\":\"assert\",\"clause\":\"fruit(apple)\"}\n" ++
        "{\"ts\":2,\"op\":\"assert\",\"clause\":\"fruit(banana)\"}\n" ++
        "{\"ts\":3,\"op\":\"assert\",\"clause\":\"fruit(cherry)\"}\n";
    const torn = good_prefix ++ "{\"ts\":4,\"op\":\"asse";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "journal.wal", .data = torn });

    var wal = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer wal.deinit();

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    // Torn-tail recovery: must NOT propagate an error.
    try wal.replay(engine);

    // The three valid records were applied.
    var result = try engine.query("fruit(X)");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.solutions.len);

    // The torn tail was truncated away: file is exactly the good prefix.
    const after = try tmp.dir.readFileAlloc(std.testing.io, "journal.wal", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(good_prefix, after);
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

test "rotate does not strand a concurrent writer's append in the archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // Two handles on the same journal, mimicking two processes: one appends,
    // the other rotates underneath it.
    var writer = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer writer.deinit();
    var rotator = try WriteAheadLog.init(std.testing.allocator, dir_path, std.testing.io);
    defer rotator.deinit();

    try writer.append(.{ .timestamp = 1, .op = .assert, .clause = "before(rotation)" });
    // Another process rotates journal.wal out to the archive and recreates it.
    try rotator.rotate();
    // The writer must target the LIVE journal.wal, NOT the archived inode. With
    // a cached fd this record would land in the archive and be lost; with the
    // per-append re-open it lands in the active journal.
    try writer.append(.{ .timestamp = 2, .op = .assert, .clause = "after(rotation)" });

    var engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try rotator.replay(engine);

    // Active journal holds only the post-rotation record (pre-rotation one was
    // archived, so replay does not see it).
    var after = try engine.query("after(X)");
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.solutions.len);

    var before = try engine.query("before(X)");
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 0), before.solutions.len);
}
