const std = @import("std");
const cli = @import("cli");
const registry = @import("registry.zig");
const bootstrap = @import("bootstrap.zig");
const arg_mapper = @import("arg_mapper.zig");
const output = @import("output.zig");
const context = @import("../tools/context.zig");

pub const ParsedArgs = struct {
    format: output.OutputFormat,
    remaining: []const []const u8,
};

/// Split `--format <json|text>` out of the tool argv. Caller must free
/// `remaining` with the same allocator when it was allocated.
pub fn extractFormatFlag(
    allocator: std.mem.Allocator,
    tool_args: []const []const u8,
) !ParsedArgs {
    var format: output.OutputFormat = .text;
    var remaining: std.ArrayList([]const u8) = .empty;
    errdefer remaining.deinit(allocator);

    var i: usize = 0;
    while (i < tool_args.len) {
        const tok = tool_args[i];
        if (std.mem.eql(u8, tok, "--format")) {
            if (i + 1 >= tool_args.len) return error.FormatValueMissing;
            const val = tool_args[i + 1];
            if (std.mem.eql(u8, val, "json")) {
                format = .json;
            } else if (std.mem.eql(u8, val, "text")) {
                format = .text;
            } else {
                return error.FormatValueInvalid;
            }
            i += 2;
        } else {
            try remaining.append(allocator, tok);
            i += 1;
        }
    }
    return ParsedArgs{
        .format = format,
        .remaining = try remaining.toOwnedSlice(allocator),
    };
}

pub fn runTool(allocator: std.mem.Allocator, cmd_name: []const u8, tool_args: []const []const u8) anyerror!void {
    const defs = registry.all();
    var found_def: ?registry.ToolDef = null;
    for (defs) |def| {
        if (std.mem.eql(u8, def.cli_name, cmd_name)) {
            found_def = def;
            break;
        }
    }
    const def = found_def orelse {
        std.debug.print("zpm: unknown command '{s}'\n", .{cmd_name});
        std.process.exit(1);
    };

    const parsed = extractFormatFlag(allocator, tool_args) catch |err| {
        const detail = switch (err) {
            error.FormatValueMissing => "missing value for",
            error.FormatValueInvalid => "invalid value for",
            else => "failed to parse",
        };
        std.debug.print("zpm {s}: {s} --format (expected json or text)\n", .{ cmd_name, detail });
        std.process.exit(1);
    };
    defer allocator.free(parsed.remaining);

    var ctx = bootstrap.initBootstrap(allocator) catch |err| {
        std.debug.print("zpm {s}: {s}. Run 'zpm init' first.\n", .{ cmd_name, @errorName(err) });
        std.process.exit(1);
    };
    defer ctx.deinit();
    context.setPersistenceManager(@ptrCast(&ctx.pm));

    const tool = try def.build(allocator);
    var diag: arg_mapper.Diag = .{};
    const json_args = arg_mapper.mapArgs(allocator, parsed.remaining, tool, def.positional_field, &diag) catch |err| {
        const detail: []const u8 = switch (err) {
            arg_mapper.MapError.MissingRequired => "missing required argument",
            arg_mapper.MapError.UnknownFlag => "unknown flag",
            arg_mapper.MapError.OutOfMemory => "out of memory",
        };
        std.debug.print("zpm {s}: {s} '{s}'\n", .{ cmd_name, detail, diag.field orelse "" });
        std.process.exit(1);
    };

    const result = tool.handler(allocator, json_args) catch |err| {
        std.debug.print("zpm {s}: {s}\n", .{ cmd_name, @errorName(err) });
        std.process.exit(1);
    };

    const exit_code = try output.render(result, parsed.format);
    if (exit_code != 0) std.process.exit(exit_code);
}

/// Fallback path used only when a tool reaches dispatch through zig-cli
/// (e.g. via `zpm --help`'s subcommand listing).
fn toolExecAction() anyerror!void {
    const allocator = std.heap.page_allocator;
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);
    const cmd_name = if (raw_args.len >= 2) raw_args[1] else return error.MissingCommand;
    const tool_args: []const []const u8 = if (raw_args.len > 2) raw_args[2..] else &.{};
    return runTool(allocator, cmd_name, tool_args);
}

pub fn buildCommands(allocator: std.mem.Allocator) anyerror![]cli.Command {
    const defs = registry.all();
    const commands = try allocator.alloc(cli.Command, defs.len);
    for (defs, 0..) |def, i| {
        commands[i] = cli.Command{
            .name = def.cli_name,
            .description = cli.Description{ .one_line = def.description },
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = toolExecAction },
            },
        };
    }
    return commands;
}

test "extractFormatFlag parses default / json / text / missing / invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const default_parsed = try extractFormatFlag(alloc, &.{ "foo", "bar" });
    try std.testing.expectEqual(output.OutputFormat.text, default_parsed.format);
    try std.testing.expectEqual(@as(usize, 2), default_parsed.remaining.len);

    const json_parsed = try extractFormatFlag(alloc, &.{ "my_fact", "--format", "json" });
    try std.testing.expectEqual(output.OutputFormat.json, json_parsed.format);
    try std.testing.expectEqualStrings("my_fact", json_parsed.remaining[0]);

    const text_parsed = try extractFormatFlag(alloc, &.{ "--format", "text", "fact" });
    try std.testing.expectEqual(output.OutputFormat.text, text_parsed.format);
    try std.testing.expectEqualStrings("fact", text_parsed.remaining[0]);

    try std.testing.expectError(error.FormatValueMissing, extractFormatFlag(alloc, &.{"--format"}));
    try std.testing.expectError(error.FormatValueInvalid, extractFormatFlag(alloc, &.{ "--format", "yaml" }));
}

test "buildCommands returns 22 commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try buildCommands(arena.allocator());
    try std.testing.expectEqual(@as(usize, 22), cmds.len);
}

test "buildCommands command names match registry kebab names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try buildCommands(arena.allocator());
    const defs = registry.all();
    for (cmds, 0..) |cmd, i| {
        try std.testing.expectEqualStrings(defs[i].cli_name, cmd.name);
    }
}

test "buildCommands descriptions use human-readable text from registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try buildCommands(arena.allocator());
    const defs = registry.all();
    for (cmds, 0..) |cmd, i| {
        try std.testing.expectEqualStrings(defs[i].description, cmd.description.?.one_line);
        try std.testing.expect(cmd.description.?.one_line.len > 0);
    }
}

test "buildCommands all commands target an action not subcommands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try buildCommands(arena.allocator());
    for (cmds) |cmd| {
        try std.testing.expect(cmd.target == .action);
    }
}

test "buildCommands all commands share the same exec function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try buildCommands(arena.allocator());
    const first_exec = cmds[0].target.action.exec;
    for (cmds[1..]) |cmd| {
        try std.testing.expectEqual(first_exec, cmd.target.action.exec);
    }
}

test "NFR-004: each registry entry has a non-empty help one-liner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try buildCommands(arena.allocator());
    for (cmds) |cmd| {
        const desc = cmd.description orelse return error.MissingDescription;
        try std.testing.expect(desc.one_line.len > 0);
    }
}
