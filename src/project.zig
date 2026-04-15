const std = @import("std");
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

    pub fn deinit(self: ProjectPaths) void {
        self.allocator.free(self.data_dir);
        self.allocator.free(self.kb_dir);
    }
};

pub fn discover(allocator: std.mem.Allocator, cwd: []const u8) (ProjectError || std.mem.Allocator.Error)!ProjectPaths {
    var current = cwd;
    var start_dev: ?std.posix.dev_t = null;

    while (true) {
        var cur_dir = std.fs.openDirAbsolute(current, .{}) catch return ProjectError.NotFound;

        const cur_stat = std.posix.fstat(cur_dir.fd) catch {
            cur_dir.close();
            return ProjectError.NotFound;
        };

        if (start_dev == null) {
            start_dev = cur_stat.dev;
        } else if (cur_stat.dev != start_dev.?) {
            cur_dir.close();
            return ProjectError.NotFound;
        }

        const has_zpm = if (cur_dir.openDir(".zpm", .{})) |zd| blk: {
            var mzd = zd;
            mzd.close();
            break :blk true;
        } else |_| false;

        cur_dir.close();

        if (has_zpm) {
            const data_dir = try std.fmt.allocPrint(allocator, "{s}/.zpm/data", .{current});
            errdefer allocator.free(data_dir);
            const kb_dir = try std.fmt.allocPrint(allocator, "{s}/.zpm/kb", .{current});
            errdefer allocator.free(kb_dir);
            return ProjectPaths{
                .allocator = allocator,
                .data_dir = data_dir,
                .kb_dir = kb_dir,
            };
        }

        const parent = std.fs.path.dirname(current) orelse return ProjectError.NotFound;
        if (std.mem.eql(u8, parent, current)) return ProjectError.NotFound;
        current = parent;
    }
}

pub fn initProject(cwd: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(cwd, .{});
    defer dir.close();

    if (dir.openDir(".zpm", .{})) |zd| {
        var mzd = zd;
        mzd.close();
        return ProjectError.AlreadyInitialized;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try dir.makeDir(".zpm");
    try dir.makeDir(".zpm/kb");
    try dir.makeDir(".zpm/data");

    const gitignore = try dir.createFile(".zpm/.gitignore", .{});
    defer gitignore.close();
    try gitignore.writeAll("data/\n");
}

pub fn loadKnowledgeBase(allocator: std.mem.Allocator, kb_dir: []const u8, engine: *Engine) !void {
    var dir = try std.fs.openDirAbsolute(kb_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
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
    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/data");
    try tmp.dir.makeDir(".zpm/kb");

    var cwd_buf: [4096]u8 = undefined;
    const cwd = try tmp.dir.realpath(".", &cwd_buf);

    const paths = try discover(std.testing.allocator, cwd);
    defer paths.deinit();

    try std.testing.expect(std.mem.endsWith(u8, paths.data_dir, "/.zpm/data"));
    try std.testing.expect(std.mem.endsWith(u8, paths.kb_dir, "/.zpm/kb"));
}

test "discover finds .zpm in parent directory when invoked from nested subdirectory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/data");
    try tmp.dir.makeDir(".zpm/kb");
    try tmp.dir.makeDir("src");

    var parent_buf: [4096]u8 = undefined;
    const parent = try tmp.dir.realpath(".", &parent_buf);
    var child_buf: [4096]u8 = undefined;
    const child = try tmp.dir.realpath("src", &child_buf);

    const paths = try discover(std.testing.allocator, child);
    defer paths.deinit();

    try std.testing.expect(std.mem.startsWith(u8, paths.data_dir, parent));
    try std.testing.expect(std.mem.endsWith(u8, paths.data_dir, "/.zpm/data"));
}

test "initProject creates .zpm directory structure with kb and data subdirectories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buf: [4096]u8 = undefined;
    const cwd = try tmp.dir.realpath(".", &cwd_buf);

    try initProject(cwd);

    var zpm = try tmp.dir.openDir(".zpm", .{});
    defer zpm.close();
    var kb = try tmp.dir.openDir(".zpm/kb", .{});
    defer kb.close();
    var data = try tmp.dir.openDir(".zpm/data", .{});
    defer data.close();
    const gi = try tmp.dir.openFile(".zpm/.gitignore", .{});
    defer gi.close();
}

test "initProject writes data/ to .zpm/.gitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd_buf: [4096]u8 = undefined;
    const cwd = try tmp.dir.realpath(".", &cwd_buf);

    try initProject(cwd);

    var buf: [256]u8 = undefined;
    const content = try tmp.dir.readFile(".zpm/.gitignore", &buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "data/") != null);
}

test "initProject returns AlreadyInitialized when .zpm already exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(".zpm");

    var cwd_buf: [4096]u8 = undefined;
    const cwd = try tmp.dir.realpath(".", &cwd_buf);

    try std.testing.expectError(ProjectError.AlreadyInitialized, initProject(cwd));
}

test "loadKnowledgeBase loads .pl files from directory into engine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pl = try tmp.dir.createFile("facts.pl", .{});
    try pl.writeAll(":- dynamic(hello/1).\nhello(world).\n");
    pl.close();

    var kb_buf: [4096]u8 = undefined;
    const kb_dir = try tmp.dir.realpath(".", &kb_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try loadKnowledgeBase(std.testing.allocator, kb_dir, engine);

    var result = try engine.query("hello(world)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len > 0);
}

test "loadKnowledgeBase ignores non-.pl files and still loads .pl files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const txt = try tmp.dir.createFile("readme.txt", .{});
    try txt.writeAll("this is not prolog\n");
    txt.close();

    const pl = try tmp.dir.createFile("rules.pl", .{});
    try pl.writeAll(":- dynamic(valid/1).\nvalid(yes).\n");
    pl.close();

    var kb_buf: [4096]u8 = undefined;
    const kb_dir = try tmp.dir.realpath(".", &kb_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try loadKnowledgeBase(std.testing.allocator, kb_dir, engine);

    var result = try engine.query("valid(yes)");
    defer result.deinit();
    try std.testing.expect(result.solutions.len > 0);
}

test "loadKnowledgeBase succeeds with empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var kb_buf: [4096]u8 = undefined;
    const kb_dir = try tmp.dir.realpath(".", &kb_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();

    try loadKnowledgeBase(std.testing.allocator, kb_dir, engine);
}

test "discover stops at filesystem root and returns NotFound when no .zpm exists" {
    // Create temp dir under /tmp to avoid finding the project's own .zpm/
    // std.testing.tmpDir uses cwd which is inside the project tree
    const base = "/tmp/zpm-test-discover-root";
    const nested = base ++ "/deep/nested";

    std.fs.deleteTreeAbsolute(base) catch {};
    try std.fs.makeDirAbsolute(base);
    defer std.fs.deleteTreeAbsolute(base) catch {};
    try std.fs.makeDirAbsolute(base ++ "/deep");
    try std.fs.makeDirAbsolute(nested);

    try std.testing.expectError(
        ProjectError.NotFound,
        discover(std.testing.allocator, nested),
    );
}
