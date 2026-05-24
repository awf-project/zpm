const std = @import("std");
const project = @import("../project.zig");

pub fn initAction() anyerror!void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NameTooLong;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    project.initProject(threaded.io(), cwd) catch |err| switch (err) {
        error.AlreadyInitialized => {
            std.debug.print(".zpm/ project directory already initialized\n", .{});
            return;
        },
        else => return err,
    };
    std.debug.print("Initialized .zpm/ project directory\n", .{});
}

test "initAction creates .zpm directory in current working directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&orig_buf, orig_buf.len) orelse return error.NameTooLong;
    const orig = std.mem.sliceTo(&orig_buf, 0);
    defer std.Io.Threaded.chdir(orig) catch {};
    try std.Io.Threaded.chdir(tmp_path);

    try initAction();

    var zpm_dir = try tmp.dir.openDir(std.testing.io, ".zpm", .{});
    zpm_dir.close(std.testing.io);
}

test "initAction returns without error when already initialized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const tmp_path = path_buf[0..tmp_path_len];

    try tmp.dir.createDir(std.testing.io, ".zpm", .default_dir);

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.c.getcwd(&orig_buf, orig_buf.len) orelse return error.NameTooLong;
    const orig = std.mem.sliceTo(&orig_buf, 0);
    defer std.Io.Threaded.chdir(orig) catch {};
    try std.Io.Threaded.chdir(tmp_path);

    try initAction();
}
