const std = @import("std");
const project = @import("../project.zig");

pub fn initAction() anyerror!void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    project.initProject(cwd) catch |err| switch (err) {
        error.AlreadyInitialized => {
            stdout.writeAll(".zpm/ project directory already initialized\n") catch {};
            return;
        },
        else => return err,
    };
    stdout.writeAll("Initialized .zpm/ project directory\n") catch {};
}

test "initAction creates .zpm directory in current working directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    try initAction();

    var zpm_dir = try tmp.dir.openDir(".zpm", .{});
    zpm_dir.close();
}

test "initAction returns without error when already initialized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir(".zpm");

    var orig_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    try initAction();
}
