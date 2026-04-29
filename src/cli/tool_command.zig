const std = @import("std");
const cli = @import("cli");
const mcp = @import("mcp");
const registry = @import("registry.zig");
const bootstrap = @import("bootstrap.zig");
const output = @import("output.zig");
const context = @import("../tools/context.zig");

/// Comptime-generated struct: one field per param, named after `mcp_key`,
/// typed as `?[]const u8` (string params) or `?i64` (integer params).
/// All fields default to `null`. zig-cli's native value parsers write into
/// these fields via `ValueRef`, automatically wrapping the value as `Some(...)`.
fn SlotsType(comptime params: []const registry.ParamSpec) type {
    if (params.len == 0) return struct {};

    var fields: [params.len]std.builtin.Type.StructField = undefined;
    inline for (params, 0..) |p, i| {
        switch (p.kind) {
            .string => {
                const default: ?[]const u8 = null;
                fields[i] = .{
                    .name = p.mcp_key[0..p.mcp_key.len :0],
                    .type = ?[]const u8,
                    .default_value_ptr = @ptrCast(&default),
                    .is_comptime = false,
                    .alignment = @alignOf(?[]const u8),
                };
            },
            .integer => {
                const default: ?i64 = null;
                fields[i] = .{
                    .name = p.mcp_key[0..p.mcp_key.len :0],
                    .type = ?i64,
                    .default_value_ptr = @ptrCast(&default),
                    .is_comptime = false,
                    .alignment = @alignOf(?i64),
                };
            },
        }
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

test "SlotsType empty params yields zero-field struct" {
    const T = SlotsType(&.{});
    const instance: T = .{};
    _ = instance;
    try std.testing.expectEqual(@as(usize, 0), @typeInfo(T).@"struct".fields.len);
}

test "SlotsType one string param yields one ?[]const u8 field" {
    const params = [_]registry.ParamSpec{
        .{ .mcp_key = "fact", .help = "h", .required = true },
    };
    const T = SlotsType(&params);
    const fields = @typeInfo(T).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("fact", fields[0].name);
    try std.testing.expectEqual(?[]const u8, fields[0].type);
}

test "SlotsType integer param yields ?i64 field" {
    const params = [_]registry.ParamSpec{
        .{ .mcp_key = "max_depth", .help = "h", .required = false, .kind = .integer },
    };
    const T = SlotsType(&params);
    const fields = @typeInfo(T).@"struct".fields;
    try std.testing.expectEqual(?i64, fields[0].type);
}

test "SlotsType field defaults to null" {
    const params = [_]registry.ParamSpec{
        .{ .mcp_key = "x", .help = "h", .required = true },
    };
    const T = SlotsType(&params);
    const instance: T = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), @field(instance, "x"));
}

/// Generic per-tool CLI machinery. For each registry entry, a fresh
/// instantiation produces:
///   - module-level `slots` struct (one field per param, typed)
///   - module-level `format_slot: []const u8 = "text"`
///   - `build(runner)` that constructs a `cli.Command` with bound Options
///   - `exec()` that reads slots, builds JSON, dispatches the handler
///
/// Each call to `ToolCommand(def)` returns a distinct type, so its `slots`
/// and `format_slot` are disjoint from every other tool's.
pub fn ToolCommand(comptime def: registry.ToolDef) type {
    return struct {
        pub const Slots = SlotsType(def.params);

        pub var slots: Slots = .{};
        pub var format_slot: []const u8 = "text";

        /// Build the cli.Command for this tool, binding every param Option
        /// and PositionalArg to the corresponding `slots` field.
        pub fn build(runner: *cli.AppRunner) !cli.Command {
            // 1 Option per non-positional param, plus --format.
            const non_positional_count = comptime blk: {
                var n: usize = 0;
                for (def.params) |p| {
                    if (!p.positional) n += 1;
                }
                break :blk n;
            };
            const total_options = non_positional_count + 1; // + --format
            var opts = try runner.arena.allocator().alloc(cli.Option, total_options);

            var oi: usize = 0;
            inline for (def.params) |p| {
                if (p.positional) continue;
                opts[oi] = .{
                    .long_name = &comptime kebab(p.mcp_key),
                    .short_alias = p.short,
                    .help = p.help,
                    .required = p.required,
                    .value_ref = runner.mkRef(&@field(slots, p.mcp_key)),
                };
                oi += 1;
            }
            opts[oi] = .{
                .long_name = "format",
                .help = "Output format: 'text' or 'json'",
                .required = false,
                .value_ref = runner.mkRef(&format_slot),
            };

            // PositionalArgs: required positional params land here.
            const positional_count = comptime blk: {
                var n: usize = 0;
                for (def.params) |p| {
                    if (p.positional) n += 1;
                }
                break :blk n;
            };
            const positional_args: ?cli.PositionalArgs = if (positional_count == 0) null else blk: {
                var pos = try runner.arena.allocator().alloc(cli.PositionalArg, positional_count);
                var pi: usize = 0;
                inline for (def.params) |p| {
                    if (!p.positional) continue;
                    pos[pi] = .{
                        .name = p.mcp_key,
                        .help = p.help,
                        .value_ref = runner.mkRef(&@field(slots, p.mcp_key)),
                    };
                    pi += 1;
                }
                break :blk .{ .required = pos, .optional = null };
            };

            return cli.Command{
                .name = def.cli_name,
                .description = .{ .one_line = def.description },
                .options = opts,
                .target = .{ .action = .{ .exec = exec, .positional_args = positional_args } },
            };
        }

        fn exec() anyerror!void {
            const allocator = std.heap.page_allocator;

            var ctx = bootstrap.initBootstrap(allocator) catch |err| {
                std.debug.print("zpm {s}: {s}. Run 'zpm init' first.\n", .{ def.cli_name, @errorName(err) });
                std.process.exit(1);
            };
            defer ctx.deinit();
            context.setPersistenceManager(@ptrCast(&ctx.pm));

            // Build the JSON args object from set slots.
            var obj = std.json.ObjectMap.init(allocator);
            inline for (def.params) |p| {
                switch (p.kind) {
                    .string => {
                        if (@field(slots, p.mcp_key)) |val| {
                            try obj.put(p.mcp_key, .{ .string = val });
                        }
                    },
                    .integer => {
                        if (@field(slots, p.mcp_key)) |val| {
                            try obj.put(p.mcp_key, .{ .integer = val });
                        }
                    },
                }
            }
            const json_args: ?std.json.Value =
                if (obj.count() == 0) null else .{ .object = obj };

            const tool = try def.build(allocator);
            const result = tool.handler(allocator, json_args) catch |err| {
                std.debug.print("zpm {s}: {s}\n", .{ def.cli_name, @errorName(err) });
                std.process.exit(1);
            };

            const fmt: output.OutputFormat =
                if (std.mem.eql(u8, format_slot, "json")) .json else .text;
            const exit_code = try output.render(result, fmt);
            if (exit_code != 0) std.process.exit(exit_code);
        }
    };
}

/// Convert `snake_case` to `kebab-case` at comptime.
/// Returns the array by value; caller takes `&` and the compiler promotes
/// the result to static storage when called from a `comptime` context.
fn kebab(comptime input: []const u8) [input.len]u8 {
    var buf: [input.len]u8 = undefined;
    for (input, 0..) |c, i| {
        buf[i] = if (c == '_') '-' else c;
    }
    return buf;
}

test "kebab converts snake_case to kebab-case" {
    try std.testing.expectEqualStrings("max-depth", &kebab("max_depth"));
    try std.testing.expectEqualStrings("fact", &kebab("fact"));
    try std.testing.expectEqualStrings("dry-run-mode", &kebab("dry_run_mode"));
}

const echo = @import("../tools/echo.zig");

const ECHO_DEF: registry.ToolDef = .{
    .cli_name = "echo",
    .mcp_name = "echo",
    .description = "Echo back the input message",
    .build = &echo.tool,
    .params = &.{
        .{ .mcp_key = "message", .help = "msg", .required = true },
    },
};

test "ToolCommand exposes Slots, slots, format_slot" {
    const TC = ToolCommand(ECHO_DEF);
    try std.testing.expectEqual(?[]const u8, @TypeOf(TC.slots.message));
    try std.testing.expectEqualStrings("text", TC.format_slot);
}

test "ToolCommand build returns cli.Command with correct name" {
    var runner = try cli.AppRunner.init(std.testing.allocator);
    defer runner.deinit();
    const TC = ToolCommand(ECHO_DEF);
    const cmd = try TC.build(&runner);
    try std.testing.expectEqualStrings("echo", cmd.name);
    // 1 param + --format = 2 options
    try std.testing.expectEqual(@as(usize, 2), cmd.options.?.len);
    try std.testing.expect(cmd.target == .action);
}

const NO_PARAMS_DEF: registry.ToolDef = .{
    .cli_name = "list-snapshots",
    .mcp_name = "list_snapshots",
    .description = "List snapshots",
    .build = &echo.tool, // dummy: not invoked in this test
    .params = &.{},
};

test "ToolCommand with zero params still emits --format option" {
    var runner = try cli.AppRunner.init(std.testing.allocator);
    defer runner.deinit();
    const TC = ToolCommand(NO_PARAMS_DEF);
    const cmd = try TC.build(&runner);
    try std.testing.expectEqual(@as(usize, 1), cmd.options.?.len);
    try std.testing.expectEqualStrings("format", cmd.options.?[0].long_name);
}

const POSITIONAL_DEF: registry.ToolDef = .{
    .cli_name = "define-rule",
    .mcp_name = "define_rule",
    .description = "Define rule",
    .build = &echo.tool, // dummy
    .params = &.{
        .{ .mcp_key = "head", .help = "h", .required = true, .positional = true },
        .{ .mcp_key = "body", .help = "b", .required = true },
    },
};

test "ToolCommand with positional emits a PositionalArg" {
    var runner = try cli.AppRunner.init(std.testing.allocator);
    defer runner.deinit();
    const TC = ToolCommand(POSITIONAL_DEF);
    const cmd = try TC.build(&runner);
    // body + format = 2 options (head is positional, not an option)
    try std.testing.expectEqual(@as(usize, 2), cmd.options.?.len);
    const pos = cmd.target.action.positional_args orelse return error.MissingPositional;
    try std.testing.expectEqual(@as(usize, 1), pos.required.?.len);
    try std.testing.expectEqualStrings("head", pos.required.?[0].name);
}

test "ToolCommand for two distinct defs produces disjoint slots" {
    const A: registry.ToolDef = .{
        .cli_name = "a",
        .mcp_name = "a",
        .description = "",
        .build = &echo.tool,
        .params = &.{.{ .mcp_key = "x", .help = "", .required = true }},
    };
    const B: registry.ToolDef = .{
        .cli_name = "b",
        .mcp_name = "b",
        .description = "",
        .build = &echo.tool,
        .params = &.{.{ .mcp_key = "x", .help = "", .required = true }},
    };
    const TA = ToolCommand(A);
    const TB = ToolCommand(B);
    TA.slots.x = "alpha";
    TB.slots.x = "beta";
    try std.testing.expectEqualStrings("alpha", TA.slots.x.?);
    try std.testing.expectEqualStrings("beta", TB.slots.x.?);
}
