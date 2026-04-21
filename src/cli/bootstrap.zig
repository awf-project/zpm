const std = @import("std");
const posix = std.posix;
const Engine = @import("../prolog/engine.zig").Engine;
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const project = @import("../project.zig");
const context = @import("../tools/context.zig");

/// Silence libc stdout for the duration of a call. Trealla's pl_create()
/// writes a banner directly via libc, so we dup2 /dev/null over fd 1 around
/// it. Two syscalls (open + dup) beats a tmpfile round-trip.
fn silenceStdout() !posix.fd_t {
    const saved = try posix.dup(posix.STDOUT_FILENO);
    errdefer posix.close(saved);
    const null_fd = try posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer posix.close(null_fd);
    try posix.dup2(null_fd, posix.STDOUT_FILENO);
    return saved;
}

fn restoreStdout(saved: posix.fd_t) void {
    posix.dup2(saved, posix.STDOUT_FILENO) catch {};
    posix.close(saved);
}

pub const Context = struct {
    engine: *Engine,
    pm: PersistenceManager,
    paths: project.ProjectPaths,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Context) void {
        self.engine.deinit();
        self.pm.deinit();
        self.paths.deinit();
    }
};

pub fn initBootstrap(allocator: std.mem.Allocator) anyerror!Context {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const paths = try project.discover(allocator, cwd);
    errdefer paths.deinit();

    std.fs.makeDirAbsolute(paths.data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(paths.kb_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Trealla's pl_create() writes a banner to libc stdout; redirect it to
    // /dev/null so it doesn't corrupt CLI text output.
    const saved_stdout = silenceStdout() catch null;
    const engine = Engine.init(.{}) catch |err| {
        if (saved_stdout) |fd| restoreStdout(fd);
        return err;
    };
    if (saved_stdout) |fd| restoreStdout(fd);
    errdefer engine.deinit();
    context.setEngine(engine);

    try project.loadKnowledgeBase(allocator, paths.kb_dir, engine);

    var pm = try PersistenceManager.init(allocator, paths.data_dir, paths.kb_dir);
    errdefer pm.deinit();
    try pm.restore(engine);

    return Context{
        .engine = engine,
        .pm = pm,
        .paths = paths,
        .allocator = allocator,
    };
}

test "initBootstrap returns Context with correct project paths" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(std.mem.endsWith(u8, ctx.paths.data_dir, "/.zpm/data"));
    try std.testing.expect(std.mem.endsWith(u8, ctx.paths.kb_dir, "/.zpm/kb"));
}

test "initBootstrap sets engine in context globals (PM is set by caller)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    context.clearEngine();
    context.clearPersistenceManager();
    defer context.clearEngine();
    defer context.clearPersistenceManager();

    var ctx = try initBootstrap(allocator);
    defer ctx.deinit();

    try std.testing.expect(context.getEngine() != null);
    // PM is deliberately not set here: it lives by value in the returned
    // Context, so only the caller has its stable address.
    try std.testing.expect(context.getPersistenceManagerAs(PersistenceManager) == null);
}

var notfound_counter = std.atomic.Value(u32).init(0);

test "initBootstrap returns NotFound when no .zpm directory exists" {
    const allocator = std.testing.allocator;

    // /tmp path avoids walking up into the repo's own .zpm/; pid+counter
    // keeps it race-free across parallel runs.
    const pid = std.c.getpid();
    const counter = notfound_counter.fetchAdd(1, .monotonic);
    var path_buf: [256]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&path_buf, "/tmp/zpm-test-bootstrap-notfound-{d}-{d}", .{ pid, counter });
    try std.fs.makeDirAbsolute(tmp_path);
    defer std.fs.deleteDirAbsolute(tmp_path) catch {};

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    try std.testing.expectError(project.ProjectError.NotFound, initBootstrap(allocator));
}
