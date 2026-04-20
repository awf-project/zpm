//! fd-level stdout/stderr capture used while invoking Trealla, whose printf
//! calls go directly to libc and cannot be intercepted through Zig's std.io.
//! The strategy mirrors `ffi/trealla-wrapper.c` (pre-port): for each begin()
//! we dup() the current STDOUT_FILENO (and optionally STDERR_FILENO), open a
//! fresh temp file, and dup2() its fd into the stdio slot. end() restores the
//! original fds and unlinks the temp files.

const std = @import("std");
const posix = std.posix;

/// Process-wide counter used to build unique temp filenames. We combine pid +
/// counter because callers may invoke this reentrantly (e.g. nested capture
/// blocks inside the same query) and concurrent calls with identical pid are
/// still possible across threads.
var g_counter = std.atomic.Value(u32).init(0);

pub const Capture = struct {
    allocator: std.mem.Allocator,
    saved_out_fd: ?posix.fd_t = null,
    saved_err_fd: ?posix.fd_t = null,
    tmp_out_fd: ?posix.fd_t = null,
    tmp_err_fd: ?posix.fd_t = null,
    path_out: ?[:0]u8 = null,
    path_err: ?[:0]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Capture {
        return .{ .allocator = allocator };
    }

    /// Begin redirecting stdout (and optionally stderr) to freshly created
    /// temp files. On failure the Capture ends up partially populated — calling
    /// end() remains safe and will restore whatever was redirected.
    pub fn begin(self: *Capture, capture_stderr: bool) !void {
        // Flush C stdio buffers so anything already queued lands on the real
        // terminal rather than in our capture file.
        flushStdout();

        const pid = std.os.linux.getpid();

        const out_counter = g_counter.fetchAdd(1, .monotonic);
        const path_out = try std.fmt.allocPrintSentinel(
            self.allocator,
            "/tmp/zpm_capo_{d}_{d}.tmp",
            .{ pid, out_counter },
            0,
        );
        errdefer self.allocator.free(path_out);

        const saved_out = try posix.dup(posix.STDOUT_FILENO);
        errdefer posix.close(saved_out);

        const out_fd = try posix.open(path_out, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
        }, 0o600);
        errdefer posix.close(out_fd);

        try posix.dup2(out_fd, posix.STDOUT_FILENO);

        self.saved_out_fd = saved_out;
        self.tmp_out_fd = out_fd;
        self.path_out = path_out;

        if (capture_stderr) {
            flushStderr();

            const err_counter = g_counter.fetchAdd(1, .monotonic);
            const path_err = std.fmt.allocPrintSentinel(
                self.allocator,
                "/tmp/zpm_cape_{d}_{d}.tmp",
                .{ pid, err_counter },
                0,
            ) catch return; // stderr capture is best-effort
            errdefer self.allocator.free(path_err);

            const saved_err = posix.dup(posix.STDERR_FILENO) catch return;
            errdefer posix.close(saved_err);

            const err_fd = posix.open(path_err, .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .TRUNC = true,
            }, 0o600) catch return;
            errdefer posix.close(err_fd);

            posix.dup2(err_fd, posix.STDERR_FILENO) catch return;

            self.saved_err_fd = saved_err;
            self.tmp_err_fd = err_fd;
            self.path_err = path_err;
        }
    }

    /// Read everything currently in the stdout capture file, reset it to
    /// empty, and return it as a heap-allocated slice owned by the caller.
    /// The redirection stays active after this call.
    pub fn readAndReset(self: *Capture) ![]u8 {
        flushStdout();
        const fd = self.tmp_out_fd orelse return try self.allocator.alloc(u8, 0);

        posix.lseek_END(fd, 0) catch {};
        const file_end = posix.lseek_CUR_get(fd) catch 0;
        if (file_end == 0) {
            return try self.allocator.alloc(u8, 0);
        }

        const buf = try self.allocator.alloc(u8, @intCast(file_end));
        errdefer self.allocator.free(buf);

        try posix.lseek_SET(fd, 0);
        const got = try posix.read(fd, buf);

        // Reset for next capture. We lseek the raw fd back to 0 AND tell
        // libc's stdio layer via fseek, otherwise glibc keeps the stale
        // offset and the next printf writes past the truncated region,
        // causing captured dump_vars output to appear staggered or missing.
        posix.lseek_SET(fd, 0) catch {};
        posix.ftruncate(fd, 0) catch {};
        _ = fseek(stdout, 0, 0);

        if (got < buf.len) {
            return try self.allocator.realloc(buf, got);
        }
        return buf;
    }

    /// Read captured stderr content. Returns an empty slice if stderr wasn't
    /// being captured. Caller owns the returned memory.
    pub fn readStderr(self: *Capture) ![]u8 {
        const fd = self.tmp_err_fd orelse return try self.allocator.alloc(u8, 0);
        flushStderr();

        posix.lseek_END(fd, 0) catch {};
        const file_end = posix.lseek_CUR_get(fd) catch 0;
        if (file_end == 0) {
            return try self.allocator.alloc(u8, 0);
        }

        const buf = try self.allocator.alloc(u8, @intCast(file_end));
        errdefer self.allocator.free(buf);

        try posix.lseek_SET(fd, 0);
        const got = try posix.read(fd, buf);

        if (got < buf.len) {
            return try self.allocator.realloc(buf, got);
        }
        return buf;
    }

    /// Restore original stdout/stderr and delete the temp files. Safe to call
    /// multiple times; idempotent.
    pub fn end(self: *Capture) void {
        flushStdout();
        flushStderr();

        if (self.saved_out_fd) |saved| {
            posix.dup2(saved, posix.STDOUT_FILENO) catch {};
            posix.close(saved);
            self.saved_out_fd = null;
        }
        if (self.tmp_out_fd) |fd| {
            posix.close(fd);
            self.tmp_out_fd = null;
        }
        if (self.path_out) |p| {
            posix.unlink(p) catch {};
            self.allocator.free(p);
            self.path_out = null;
        }

        if (self.saved_err_fd) |saved| {
            posix.dup2(saved, posix.STDERR_FILENO) catch {};
            posix.close(saved);
            self.saved_err_fd = null;
        }
        if (self.tmp_err_fd) |fd| {
            posix.close(fd);
            self.tmp_err_fd = null;
        }
        if (self.path_err) |p| {
            posix.unlink(p) catch {};
            self.allocator.free(p);
            self.path_err = null;
        }
    }
};

// libc forward declarations used to flush C stdio buffers before every fd
// swap. Without these, printf output can leak past the capture window because
// libc still holds it in stdout/stderr buffer memory.
extern "c" fn fflush(stream: ?*anyopaque) c_int;
extern "c" fn fseek(stream: ?*anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" var stdout: ?*anyopaque;
extern "c" var stderr: ?*anyopaque;

fn flushStdout() void {
    _ = fflush(stdout);
}

fn flushStderr() void {
    _ = fflush(stderr);
}

const testing = std.testing;

test "Capture roundtrips stdout writes" {
    var cap = Capture.init(testing.allocator);
    try cap.begin(false);
    errdefer cap.end();

    const msg = "hello capture\n";
    _ = try posix.write(posix.STDOUT_FILENO, msg);

    const got = try cap.readAndReset();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(msg, got);

    cap.end();
}

test "Capture readAndReset clears buffer between reads" {
    var cap = Capture.init(testing.allocator);
    try cap.begin(false);
    errdefer cap.end();

    _ = try posix.write(posix.STDOUT_FILENO, "first\n");
    const first = try cap.readAndReset();
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first\n", first);

    _ = try posix.write(posix.STDOUT_FILENO, "second\n");
    const second = try cap.readAndReset();
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("second\n", second);

    cap.end();
}

test "Capture stderr captures writes separately from stdout" {
    var cap = Capture.init(testing.allocator);
    try cap.begin(true);
    errdefer cap.end();

    _ = try posix.write(posix.STDOUT_FILENO, "out\n");
    _ = try posix.write(posix.STDERR_FILENO, "err\n");

    const out = try cap.readAndReset();
    defer testing.allocator.free(out);
    const err = try cap.readStderr();
    defer testing.allocator.free(err);

    try testing.expectEqualStrings("out\n", out);
    try testing.expectEqualStrings("err\n", err);

    cap.end();
}

test "Capture end without begin is a no-op" {
    var cap = Capture.init(testing.allocator);
    cap.end();
}
