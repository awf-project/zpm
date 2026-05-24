const std = @import("std");
const builtin = @import("builtin");
const Engine = @import("prolog/engine.zig").Engine;

pub const ProjectError = error{
    NotFound,
    AlreadyInitialized,
    NotWritable,
};

pub const ProjectPaths = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    kb_dir: []const u8,
    manifest_path: []const u8,

    pub fn deinit(self: ProjectPaths) void {
        self.allocator.free(self.data_dir);
        self.allocator.free(self.kb_dir);
        self.allocator.free(self.manifest_path);
    }
};

pub fn discover(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) (ProjectError || std.mem.Allocator.Error)!ProjectPaths {
    var current = cwd;
    var start_dev: ?i64 = null;

    while (true) {
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (current.len >= path_buf.len) return ProjectError.NotFound;
        @memcpy(path_buf[0..current.len], current);
        path_buf[current.len] = 0;

        const dev = getDeviceId(@ptrCast(&path_buf)) orelse return ProjectError.NotFound;

        if (start_dev == null) {
            start_dev = dev;
        } else if (dev != start_dev.?) {
            return ProjectError.NotFound;
        }

        var cur_dir = std.Io.Dir.openDirAbsolute(io, current, .{}) catch return ProjectError.NotFound;
        const has_zpm = if (cur_dir.openDir(io, ".zpm", .{})) |zd| blk: {
            var mzd = zd;
            mzd.close(io);
            break :blk true;
        } else |_| false;

        cur_dir.close(io);

        if (has_zpm) {
            const data_dir = try std.fmt.allocPrint(allocator, "{s}/.zpm/data", .{current});
            errdefer allocator.free(data_dir);
            const kb_dir = try std.fmt.allocPrint(allocator, "{s}/.zpm/kb", .{current});
            errdefer allocator.free(kb_dir);
            const manifest_path = try std.fmt.allocPrint(allocator, "{s}/.zpm/mounts.json", .{current});
            errdefer allocator.free(manifest_path);
            return ProjectPaths{
                .allocator = allocator,
                .data_dir = data_dir,
                .kb_dir = kb_dir,
                .manifest_path = manifest_path,
            };
        }

        const parent = std.fs.path.dirname(current) orelse return ProjectError.NotFound;
        if (std.mem.eql(u8, parent, current)) return ProjectError.NotFound;
        current = parent;
    }
}

fn getDeviceId(path: [*:0]const u8) ?i64 {
    if (comptime builtin.os.tag == .linux) {
        var stx: std.os.linux.Statx = undefined;
        if (std.c.statx(std.posix.AT.FDCWD, path, 0, std.os.linux.STATX.BASIC_STATS, &stx) != 0) return null;
        return @intCast(stx.dev_major);
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.posix.AT.FDCWD, path, &st, 0) != 0) return null;
        return @intCast(st.dev);
    }
}

pub fn initProject(io: std.Io, cwd: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, cwd, .{});
    defer dir.close(io);

    if (dir.openDir(io, ".zpm", .{})) |zd| {
        var mzd = zd;
        mzd.close(io);
        return ProjectError.AlreadyInitialized;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try dir.createDir(io, ".zpm", .default_dir);
    try dir.createDir(io, ".zpm/kb", .default_dir);
    try dir.createDir(io, ".zpm/data", .default_dir);

    const gitignore = try dir.createFile(io, ".zpm/.gitignore", .{});
    defer gitignore.close(io);
    try gitignore.writeStreamingAll(io, "data/\n");
}

pub fn loadKnowledgeBase(io: std.Io, allocator: std.mem.Allocator, kb_dir: []const u8, engine: *Engine) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, kb_dir, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pl")) continue;

        const path = try std.fs.path.join(allocator, &.{ kb_dir, entry.name });
        defer allocator.free(path);

        engine.loadFile(path) catch |err| {
            std.log.warn("failed to load {s}: {}", .{ path, err });
        };
    }
}

test "discover returns ProjectPaths with data_dir and kb_dir when .zpm exists in cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".zpm", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/data", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/kb", .default_dir);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const paths = try discover(std.testing.io, std.testing.allocator, cwd);
    defer paths.deinit();

    try std.testing.expect(std.mem.endsWith(u8, paths.data_dir, "/.zpm/data"));
    try std.testing.expect(std.mem.endsWith(u8, paths.kb_dir, "/.zpm/kb"));
}

test "discover finds .zpm in parent directory when invoked from nested subdirectory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".zpm", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/data", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/kb", .default_dir);
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);

    var parent_buf: [4096]u8 = undefined;
    const parent_len = try tmp.dir.realPathFile(std.testing.io, ".", &parent_buf);
    const parent = parent_buf[0..parent_len];
    var child_buf: [4096]u8 = undefined;
    const child_len = try tmp.dir.realPathFile(std.testing.io, "src", &child_buf);
    const child = child_buf[0..child_len];

    const paths = try discover(std.testing.io, std.testing.allocator, child);
    defer paths.deinit();

    try std.testing.expect(std.mem.startsWith(u8, paths.data_dir, parent));
    try std.testing.expect(std.mem.endsWith(u8, paths.data_dir, "/.zpm/data"));
}

test "discover populates manifest_path ending with /.zpm/mounts.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".zpm", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/data", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/kb", .default_dir);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const paths = try discover(std.testing.io, std.testing.allocator, cwd);
    defer paths.deinit();

    try std.testing.expect(std.mem.endsWith(u8, paths.manifest_path, "/.zpm/mounts.json"));
}

test "ProjectPaths.deinit frees manifest_path without leaks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".zpm", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/data", .default_dir);
    try tmp.dir.createDir(std.testing.io, ".zpm/kb", .default_dir);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    const paths = try discover(std.testing.io, std.testing.allocator, cwd);
    paths.deinit();
}

test "initProject creates .zpm directory structure with kb and data subdirectories" {
    const tio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    try initProject(std.testing.io, cwd);

    var zpm = try tmp.dir.openDir(tio, ".zpm", .{});
    defer zpm.close(tio);
    var kb = try tmp.dir.openDir(tio, ".zpm/kb", .{});
    defer kb.close(tio);
    var data = try tmp.dir.openDir(tio, ".zpm/data", .{});
    defer data.close(tio);
    const gi = try tmp.dir.openFile(tio, ".zpm/.gitignore", .{});
    defer gi.close(tio);
}

test "initProject writes data/ to .zpm/.gitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    try initProject(std.testing.io, cwd);

    var buf: [256]u8 = undefined;
    const content = try tmp.dir.readFile(std.testing.io, ".zpm/.gitignore", &buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "data/") != null);
}

test "initProject returns AlreadyInitialized when .zpm already exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".zpm", .default_dir);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, ".", &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    try std.testing.expectError(ProjectError.AlreadyInitialized, initProject(std.testing.io, cwd));
}

test "loadKnowledgeBase loads .pl files from directory into engine" {
    const tio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pl = try tmp.dir.createFile(tio, "facts.pl", .{});
    try pl.writeStreamingAll(tio, ":- dynamic(hello/1).\nhello(world).\n");
    pl.close(tio);

    var kb_buf: [4096]u8 = undefined;
    const kb_dir_len = try tmp.dir.realPathFile(std.testing.io, ".", &kb_buf);
    const kb_dir = kb_buf[0..kb_dir_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try loadKnowledgeBase(std.testing.io, std.testing.allocator, kb_dir, engine);

    var result = try engine.query("hello(world)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len > 0);
}

test "loadKnowledgeBase ignores non-.pl files and still loads .pl files" {
    const tio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const txt = try tmp.dir.createFile(tio, "readme.txt", .{});
    try txt.writeStreamingAll(tio, "this is not prolog\n");
    txt.close(tio);

    const pl = try tmp.dir.createFile(tio, "rules.pl", .{});
    try pl.writeStreamingAll(tio, ":- dynamic(valid/1).\nvalid(yes).\n");
    pl.close(tio);

    var kb_buf: [4096]u8 = undefined;
    const kb_dir_len = try tmp.dir.realPathFile(std.testing.io, ".", &kb_buf);
    const kb_dir = kb_buf[0..kb_dir_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try loadKnowledgeBase(std.testing.io, std.testing.allocator, kb_dir, engine);

    var result = try engine.query("valid(yes)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len > 0);
}

test "loadKnowledgeBase succeeds with empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var kb_buf: [4096]u8 = undefined;
    const kb_dir_len = try tmp.dir.realPathFile(std.testing.io, ".", &kb_buf);
    const kb_dir = kb_buf[0..kb_dir_len];

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try loadKnowledgeBase(std.testing.io, std.testing.allocator, kb_dir, engine);
}

test "discover stops at filesystem root and returns NotFound when no .zpm exists" {
    // Create temp dir under /tmp to avoid finding the project's own .zpm/
    // std.testing.tmpDir uses cwd which is inside the project tree
    const base = "/tmp/zpm-test-discover-root";
    const nested = base ++ "/deep/nested";

    std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, base, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
    try std.Io.Dir.cwd().createDir(std.testing.io, base ++ "/deep", .default_dir);
    try std.Io.Dir.cwd().createDir(std.testing.io, nested, .default_dir);

    try std.testing.expectError(
        ProjectError.NotFound,
        discover(std.testing.io, std.testing.allocator, nested),
    );
}
