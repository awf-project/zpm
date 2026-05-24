const std = @import("std");
const cli = @import("cli");
const mcp = @import("mcp");
const bootstrap = @import("bootstrap.zig");
const output = @import("output.zig");
const context = @import("../tools/context.zig");
const create_memory = @import("../tools/create_memory.zig");
const mount_memory = @import("../tools/mount_memory.zig");
const unmount_memory = @import("../tools/unmount_memory.zig");
const list_memories = @import("../tools/list_memories.zig");

var create_name_slot: ?[]const u8 = null;
var create_scope_slot: ?[]const u8 = null;
var mount_name_slot: ?[]const u8 = null;
var mount_mode_slot: ?[]const u8 = null;
var mount_scope_slot: ?[]const u8 = null;
var unmount_name_slot: ?[]const u8 = null;

pub fn buildCommand(runner: *cli.AppRunner) !cli.Command {
    return cli.Command{
        .name = "memory",
        .description = .{ .one_line = "Manage named memory segments" },
        .target = .{ .subcommands = try assembleMemoryCommands(runner) },
    };
}

fn assembleMemoryCommands(runner: *cli.AppRunner) ![]cli.Command {
    var tmp: [4]cli.Command = undefined;
    tmp[0] = try buildCreateSubcommand(runner);
    tmp[1] = try buildMountSubcommand(runner);
    tmp[2] = try buildUnmountSubcommand(runner);
    tmp[3] = buildListSubcommand();
    return runner.allocCommands(tmp[0..]);
}

fn wireContext(ctx: *bootstrap.Context) void {
    context.setPersistenceManager(@ptrCast(&ctx.pm));
    context.setMemoryRegistry(@ptrCast(&ctx.registry));
    context.setMountManifest(@ptrCast(&ctx.manifest));
    context.setKbDir(ctx.paths.kb_dir);
}

fn buildCreateSubcommand(runner: *cli.AppRunner) !cli.Command {
    const opts = try runner.allocOptions(&.{
        .{
            .long_name = "name",
            .help = "Memory name (lowercase, alphanumeric with underscores)",
            .required = true,
            .value_ref = runner.mkRef(&create_name_slot),
        },
        .{
            .long_name = "scope",
            .help = "Memory scope: project or global (default: project)",
            .required = false,
            .value_ref = runner.mkRef(&create_scope_slot),
        },
    });
    return cli.Command{
        .name = "create",
        .description = .{ .one_line = "Create a new named memory module" },
        .options = opts,
        .target = .{ .action = .{ .exec = createExec } },
    };
}

fn buildMountSubcommand(runner: *cli.AppRunner) !cli.Command {
    const opts = try runner.allocOptions(&.{
        .{
            .long_name = "name",
            .help = "Memory name to mount",
            .required = true,
            .value_ref = runner.mkRef(&mount_name_slot),
        },
        .{
            .long_name = "mode",
            .help = "Mount mode: rw or ro (default: rw)",
            .required = false,
            .value_ref = runner.mkRef(&mount_mode_slot),
        },
        .{
            .long_name = "scope",
            .help = "Memory scope: project or global (default: project)",
            .required = false,
            .value_ref = runner.mkRef(&mount_scope_slot),
        },
    });
    return cli.Command{
        .name = "mount",
        .description = .{ .one_line = "Mount an existing named memory module" },
        .options = opts,
        .target = .{ .action = .{ .exec = mountExec } },
    };
}

fn buildUnmountSubcommand(runner: *cli.AppRunner) !cli.Command {
    const opts = try runner.allocOptions(&.{
        .{
            .long_name = "name",
            .help = "Memory name to unmount",
            .required = true,
            .value_ref = runner.mkRef(&unmount_name_slot),
        },
    });
    return cli.Command{
        .name = "unmount",
        .description = .{ .one_line = "Unmount a named memory module" },
        .options = opts,
        .target = .{ .action = .{ .exec = unmountExec } },
    };
}

fn buildListSubcommand() cli.Command {
    return cli.Command{
        .name = "list",
        .description = .{ .one_line = "List all known memory modules" },
        .target = .{ .action = .{ .exec = listExec } },
    };
}

fn createExec() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = bootstrap.initBootstrap(allocator, io) catch |err| {
        std.debug.print("zpm memory create: {s}. Run 'zpm init' first.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ctx.deinit();
    wireContext(&ctx);
    defer context.clearPersistenceManager();
    defer context.clearMemoryRegistry();
    defer context.clearMountManifest();
    defer context.clearKbDir();
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    defer obj.deinit(allocator);
    if (create_name_slot) |val| try obj.put(allocator, "name", .{ .string = val });
    if (create_scope_slot) |val| try obj.put(allocator, "scope", .{ .string = val });
    const json_args: ?std.json.Value = if (obj.count() == 0) null else .{ .object = obj };

    const result = create_memory.handler(null, io, allocator, json_args) catch |err| {
        std.debug.print("zpm memory create: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const exit_code = try output.render(result, .text, io);
    if (exit_code != 0) std.process.exit(exit_code);
}

fn mountExec() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = bootstrap.initBootstrap(allocator, io) catch |err| {
        std.debug.print("zpm memory mount: {s}. Run 'zpm init' first.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ctx.deinit();
    wireContext(&ctx);
    defer context.clearPersistenceManager();
    defer context.clearMemoryRegistry();
    defer context.clearMountManifest();
    defer context.clearKbDir();
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    defer obj.deinit(allocator);
    if (mount_name_slot) |val| try obj.put(allocator, "name", .{ .string = val });
    if (mount_mode_slot) |val| try obj.put(allocator, "mode", .{ .string = val });
    if (mount_scope_slot) |val| try obj.put(allocator, "scope", .{ .string = val });
    const json_args: ?std.json.Value = if (obj.count() == 0) null else .{ .object = obj };

    const result = mount_memory.handler(null, io, allocator, json_args) catch |err| {
        std.debug.print("zpm memory mount: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const exit_code = try output.render(result, .text, io);
    if (exit_code != 0) std.process.exit(exit_code);
}

fn unmountExec() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = bootstrap.initBootstrap(allocator, io) catch |err| {
        std.debug.print("zpm memory unmount: {s}. Run 'zpm init' first.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ctx.deinit();
    wireContext(&ctx);
    defer context.clearPersistenceManager();
    defer context.clearMemoryRegistry();
    defer context.clearMountManifest();
    defer context.clearKbDir();
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    defer obj.deinit(allocator);
    if (unmount_name_slot) |val| try obj.put(allocator, "name", .{ .string = val });
    const json_args: ?std.json.Value = if (obj.count() == 0) null else .{ .object = obj };

    const result = unmount_memory.handler(null, io, allocator, json_args) catch |err| {
        std.debug.print("zpm memory unmount: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const exit_code = try output.render(result, .text, io);
    if (exit_code != 0) std.process.exit(exit_code);
}

fn listExec() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = bootstrap.initBootstrap(allocator, io) catch |err| {
        std.debug.print("zpm memory list: {s}. Run 'zpm init' first.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ctx.deinit();
    wireContext(&ctx);
    defer context.clearPersistenceManager();
    defer context.clearMemoryRegistry();
    defer context.clearMountManifest();
    defer context.clearKbDir();
    defer context.clearEngine();

    const result = list_memories.handler(null, io, allocator, null) catch |err| {
        std.debug.print("zpm memory list: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const exit_code = try output.render(result, .text, io);
    if (exit_code != 0) std.process.exit(exit_code);
}

fn makeTestInit(arena: *std.heap.ArenaAllocator, environ_map: *std.process.Environ.Map) std.process.Init {
    return .{
        .minimal = .{
            .environ = .empty,
            .args = .{ .vector = &.{} },
        },
        .arena = arena,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = environ_map,
        .preopens = .empty,
    };
}

test "buildCommand returns command named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    try std.testing.expectEqualStrings("memory", cmd.name);
}

test "buildCommand returns 4 subcommands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    try std.testing.expect(cmd.target == .subcommands);
    try std.testing.expectEqual(@as(usize, 4), cmd.target.subcommands.len);
}

test "buildCommand subcommands are named create mount unmount list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    const subs = cmd.target.subcommands;
    try std.testing.expectEqualStrings("create", subs[0].name);
    try std.testing.expectEqualStrings("mount", subs[1].name);
    try std.testing.expectEqualStrings("unmount", subs[2].name);
    try std.testing.expectEqualStrings("list", subs[3].name);
}

test "create subcommand has required name and optional scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    const opts = cmd.target.subcommands[0].options orelse return error.MissingOptions;
    try std.testing.expectEqual(@as(usize, 2), opts.len);
    try std.testing.expectEqualStrings("name", opts[0].long_name);
    try std.testing.expect(opts[0].required);
    try std.testing.expectEqualStrings("scope", opts[1].long_name);
    try std.testing.expect(!opts[1].required);
}

test "mount subcommand has required name and optional mode and scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    const opts = cmd.target.subcommands[1].options orelse return error.MissingOptions;
    try std.testing.expectEqual(@as(usize, 3), opts.len);
    try std.testing.expectEqualStrings("name", opts[0].long_name);
    try std.testing.expect(opts[0].required);
    try std.testing.expectEqualStrings("mode", opts[1].long_name);
    try std.testing.expect(!opts[1].required);
    try std.testing.expectEqualStrings("scope", opts[2].long_name);
    try std.testing.expect(!opts[2].required);
}

test "unmount subcommand has required name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    const opts = cmd.target.subcommands[2].options orelse return error.MissingOptions;
    try std.testing.expectEqual(@as(usize, 1), opts.len);
    try std.testing.expectEqualStrings("name", opts[0].long_name);
    try std.testing.expect(opts[0].required);
}

test "list subcommand has no options and an action target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    const list_cmd = cmd.target.subcommands[3];
    try std.testing.expect(list_cmd.options == null);
    try std.testing.expect(list_cmd.target == .action);
}

test "list subcommand targets listExec action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);
    const list_cmd = cmd.target.subcommands[3];
    try std.testing.expect(list_cmd.target == .action);
    try std.testing.expectEqual(@as(*const fn () anyerror!void, &listExec), list_cmd.target.action.exec);
}
