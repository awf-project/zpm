const std = @import("std");
const mcp = @import("mcp");
const cli = @import("cli");
const serve_cli = @import("cli/serve.zig");
const init_cli = @import("cli/init.zig");
const dispatcher = @import("cli/dispatcher.zig");
const registry = @import("cli/registry.zig");

const version = @import("version.zig").version;

/// Widest `cli_name` across built-ins + registry, so the description column
/// lines up. Kept as a comptime-computed constant.
const help_name_column_width: usize = blk: {
    var w: usize = "serve".len;
    for (registry.all()) |def| {
        if (def.cli_name.len > w) w = def.cli_name.len;
    }
    break :blk w + 2;
};

// ANSI palette mirrors zig-cli's defaults (see HelpConfig in the cli package)
// so `zpm` and `zpm --help` look identical in a terminal.
const color_reset = "\x1b[0m";
const color_section = "\x1b[33;1m";
const color_name = "\x1b[32m";

fn printHelp(stdout: std.fs.File) !void {
    const use_color = std.posix.isatty(stdout.handle);
    var buf: [4096]u8 = undefined;
    var fw = stdout.writer(&buf);
    const w = &fw.interface;

    try writeColored(w, use_color, color_section, "zpm");
    try w.writeAll(" " ++ version ++ "\n\n");
    try w.writeAll("Prolog inference engine for the Model Context Protocol\n\n");

    try writeColored(w, use_color, color_section, "USAGE:");
    try w.writeAll("\n  zpm <command> [options]\n\n");

    try writeColored(w, use_color, color_section, "COMMANDS:");
    try w.writeAll("\n");
    try writeCommandRow(w, use_color, "init", "Initialize a .zpm/ project directory");
    try writeCommandRow(w, use_color, "serve", "Start the MCP server on stdio");
    for (registry.all()) |def| {
        try writeCommandRow(w, use_color, def.cli_name, def.description);
    }

    try w.writeAll("\n");
    try writeColored(w, use_color, color_section, "OPTIONS:");
    try w.writeAll("\n  ");
    try writeColored(w, use_color, color_name, "-h, --help");
    try w.writeAll("       Show this help output\n  ");
    try writeColored(w, use_color, color_name, "-v, --version");
    try w.writeAll("    Print version\n");
    try w.flush();
}

fn writeColored(w: *std.io.Writer, use_color: bool, color: []const u8, text: []const u8) !void {
    if (use_color) try w.writeAll(color);
    try w.writeAll(text);
    if (use_color) try w.writeAll(color_reset);
}

fn writeCommandRow(w: *std.io.Writer, use_color: bool, name: []const u8, desc: []const u8) !void {
    try w.writeAll("  ");
    try writeColored(w, use_color, color_name, name);
    const pad = help_name_column_width - name.len;
    try w.splatByteAll(' ', pad);
    try w.writeAll(desc);
    try w.writeAll("\n");
}

fn assembleCommands(allocator: std.mem.Allocator) ![]cli.Command {
    const tool_cmds = try dispatcher.buildCommands(allocator);
    const all_cmds = try allocator.alloc(cli.Command, 2 + tool_cmds.len);
    all_cmds[0] = cli.Command{
        .name = "init",
        .description = cli.Description{ .one_line = "Initialize a .zpm/ project directory" },
        .target = cli.CommandTarget{ .action = cli.CommandAction{ .exec = init_cli.initAction } },
    };
    all_cmds[1] = cli.Command{
        .name = "serve",
        .description = cli.Description{ .one_line = "Start the MCP server on stdio" },
        .target = cli.CommandTarget{ .action = cli.CommandAction{ .exec = serve_cli.serveAction } },
    };
    @memcpy(all_cmds[2..], tool_cmds);
    return all_cmds;
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    if (args.len == 1) {
        printHelp(stdout) catch {};
        return;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        stdout.writeAll("zpm " ++ version ++ "\n") catch {};
        return;
    }

    if (registry.containsKebab(args[1])) {
        const tool_args: []const []const u8 = if (args.len > 2) args[2..] else &.{};
        try dispatcher.runTool(std.heap.page_allocator, args[1], tool_args);
        return;
    }

    // zig-cli emits an empty stderr on unknown subcommands; filter here so
    // users see a real message.
    const is_help = std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h");
    const is_builtin = std.mem.eql(u8, args[1], "init") or std.mem.eql(u8, args[1], "serve");
    if (!is_help and !is_builtin) {
        const kind: []const u8 = if (args[1].len > 0 and args[1][0] == '-') "option" else "command";
        std.debug.print("ERROR: unknown {s} '{s}'\nTry 'zpm --help' for more information.\n", .{ kind, args[1] });
        std.posix.exit(1);
    }

    var r = try cli.AppRunner.init(std.heap.page_allocator);
    const all_cmds = try assembleCommands(std.heap.page_allocator);

    const app = cli.App{
        .version = version,
        .command = cli.Command{
            .name = "zpm",
            .description = cli.Description{
                .one_line = "Prolog inference engine for the Model Context Protocol",
            },
            .target = cli.CommandTarget{ .subcommands = all_cmds },
        },
    };
    return r.run(&app);
}

test {
    _ = @import("prolog/engine.zig");
    _ = registry;
    _ = dispatcher;
    _ = serve_cli;
    _ = init_cli;
}

fn initTestServer() mcp.Server {
    return mcp.Server.init(.{
        .name = "zpm",
        .version = version,
        .allocator = std.testing.allocator,
    });
}

test "server initializes with correct name and version" {
    var server = initTestServer();
    defer server.deinit();

    try std.testing.expectEqualStrings("zpm", server.config.name);
    try std.testing.expectEqualStrings(version, server.config.version);
}

test "version constant value is 0.1.0" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test "server registers all tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = initTestServer();
    defer server.deinit();

    for (registry.all()) |def| {
        try server.addTool(try def.build(arena.allocator()));
    }

    try std.testing.expectEqual(@as(usize, 22), server.tools.count());
}

test "assembleCommands prepends init + serve to the 22 tool commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all_cmds = try assembleCommands(arena.allocator());
    try std.testing.expectEqual(@as(usize, 24), all_cmds.len);
    try std.testing.expectEqualStrings("init", all_cmds[0].name);
    try std.testing.expectEqualStrings("serve", all_cmds[1].name);
    try std.testing.expectEqual(init_cli.initAction, all_cmds[0].target.action.exec);
    try std.testing.expectEqual(serve_cli.serveAction, all_cmds[1].target.action.exec);
}
