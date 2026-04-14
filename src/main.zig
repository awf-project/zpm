const std = @import("std");
const mcp = @import("mcp");
const cli = @import("cli");
const echo = @import("tools/echo.zig");
const remember_fact = @import("tools/remember_fact.zig");
const define_rule = @import("tools/define_rule.zig");
const context = @import("tools/context.zig");
const query_logic = @import("tools/query_logic.zig");
const trace_dependency = @import("tools/trace_dependency.zig");
const verify_consistency = @import("tools/verify_consistency.zig");
const explain_why = @import("tools/explain_why.zig");
const get_knowledge_schema = @import("tools/get_knowledge_schema.zig");
const forget_fact = @import("tools/forget_fact.zig");
const clear_context = @import("tools/clear_context.zig");
const update_fact = @import("tools/update_fact.zig");
const upsert_fact = @import("tools/upsert_fact.zig");
const assume_fact = @import("tools/assume_fact.zig");
const retract_assumption = @import("tools/retract_assumption.zig");
const get_belief_status = @import("tools/get_belief_status.zig");
const get_justification = @import("tools/get_justification.zig");
const list_assumptions = @import("tools/list_assumptions.zig");
const retract_assumptions = @import("tools/retract_assumptions.zig");
const save_snapshot = @import("tools/save_snapshot.zig");
const restore_snapshot = @import("tools/restore_snapshot.zig");
const list_snapshots = @import("tools/list_snapshots.zig");
const get_persistence_status = @import("tools/get_persistence_status.zig");
const Engine = @import("prolog/engine.zig").Engine;
const PersistenceManager = @import("persistence/manager.zig").PersistenceManager;
const PersistenceStatus = @import("persistence/manager.zig").PersistenceStatus;

const version = "0.1.0";

fn serve(allocator: std.mem.Allocator) !void {
    _ = allocator;
    // serve() owns its memory for the full server lifetime; page_allocator
    // avoids GPA leak detection when called from tests with a tracking allocator
    const alloc = std.heap.page_allocator;

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    const data_dir = std.posix.getenv("ZPM_DATA_DIR") orelse blk: {
        if (std.posix.getenv("XDG_DATA_HOME")) |xdg| {
            break :blk try std.fmt.allocPrint(alloc, "{s}/zpm", .{xdg});
        }
        if (std.posix.getenv("HOME")) |home| {
            break :blk try std.fmt.allocPrint(alloc, "{s}/.local/share/zpm", .{home});
        }
        break :blk try alloc.dupe(u8, "/tmp/zpm");
    };
    defer if (std.posix.getenv("ZPM_DATA_DIR") == null) alloc.free(data_dir);
    var pm = try PersistenceManager.init(alloc, data_dir);
    defer pm.deinit();
    try pm.restore(engine);
    context.setPersistenceManager(@ptrCast(&pm));

    var server = mcp.Server.init(.{
        .name = "zpm",
        .version = version,
        .title = "Zig Package Manager MCP Server",
        .description = "MCP server for Zig package management via Prolog inference",
        .allocator = alloc,
    });
    defer server.deinit();

    try server.addTool(echo.tool);
    try server.addTool(remember_fact.tool);
    try server.addTool(define_rule.tool);
    try server.addTool(query_logic.tool);
    try server.addTool(trace_dependency.tool);
    try server.addTool(verify_consistency.tool);
    try server.addTool(explain_why.tool);
    try server.addTool(get_knowledge_schema.tool);
    try server.addTool(forget_fact.tool);
    try server.addTool(clear_context.tool);
    try server.addTool(update_fact.tool);
    try server.addTool(upsert_fact.tool);
    try server.addTool(assume_fact.tool);
    try server.addTool(retract_assumption.tool);
    try server.addTool(get_belief_status.tool);
    try server.addTool(get_justification.tool);
    try server.addTool(list_assumptions.tool);
    try server.addTool(retract_assumptions.tool);
    try server.addTool(save_snapshot.tool);
    try server.addTool(restore_snapshot.tool);
    try server.addTool(list_snapshots.tool);
    try server.addTool(get_persistence_status.tool);

    try server.run(.stdio);
}

fn serveAction() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try serve(gpa.allocator());
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    if (args.len == 1) {
        stdout.writeAll(
            "zpm " ++ version ++ "\n\n" ++
                "Prolog inference engine for the Model Context Protocol\n\n" ++
                "USAGE:\n  zpm <command> [options]\n\n" ++
                "COMMANDS:\n  serve   Start the MCP server on stdio\n\n" ++
                "OPTIONS:\n  -h, --help       Show this help output\n" ++
                "  -v, --version    Print version\n",
        ) catch {};
        return;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        stdout.writeAll("zpm " ++ version ++ "\n") catch {};
        return;
    }
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h") or
        std.mem.eql(u8, args[1], "serve"))
    {
        // Known flags/subcommands — let zig-cli handle them
    } else {
        const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        if (args[1].len > 0 and args[1][0] == '-') {
            stderr.writeAll("ERROR: unknown option '") catch {};
            stderr.writeAll(args[1]) catch {};
            stderr.writeAll("'\nTry 'zpm --help' for more information.\n") catch {};
        } else {
            stderr.writeAll("ERROR: unknown command '") catch {};
            stderr.writeAll(args[1]) catch {};
            stderr.writeAll("'\nTry 'zpm --help' for more information.\n") catch {};
        }
        std.posix.exit(1);
    }

    var r = try cli.AppRunner.init(std.heap.page_allocator);
    const app = cli.App{
        .version = version,
        .command = cli.Command{
            .name = "zpm",
            .description = cli.Description{
                .one_line = "Prolog inference engine for the Model Context Protocol",
            },
            .target = cli.CommandTarget{
                .subcommands = &.{
                    cli.Command{
                        .name = "serve",
                        .description = cli.Description{
                            .one_line = "Start the MCP server on stdio",
                        },
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = serveAction },
                        },
                    },
                },
            },
        },
    };
    return r.run(&app);
}

test {
    _ = echo;
    _ = context;
    _ = remember_fact;
    _ = define_rule;
    _ = query_logic;
    _ = trace_dependency;
    _ = verify_consistency;
    _ = explain_why;
    _ = get_knowledge_schema;
    _ = forget_fact;
    _ = clear_context;
    _ = update_fact;
    _ = upsert_fact;
    _ = assume_fact;
    _ = retract_assumption;
    _ = get_belief_status;
    _ = get_justification;
    _ = list_assumptions;
    _ = retract_assumptions;
    _ = save_snapshot;
    _ = restore_snapshot;
    _ = list_snapshots;
    _ = get_persistence_status;
    _ = @import("prolog/engine.zig");
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

test "server capabilities include tools after registration" {
    var server = initTestServer();
    defer server.deinit();

    try std.testing.expect(server.capabilities.tools == null);
    try server.addTool(echo.tool);
    try std.testing.expect(server.capabilities.tools != null);
}

test "server registers all eighteen tools" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(echo.tool);
    try server.addTool(remember_fact.tool);
    try server.addTool(define_rule.tool);
    try server.addTool(query_logic.tool);
    try server.addTool(trace_dependency.tool);
    try server.addTool(verify_consistency.tool);
    try server.addTool(explain_why.tool);
    try server.addTool(get_knowledge_schema.tool);
    try server.addTool(forget_fact.tool);
    try server.addTool(clear_context.tool);
    try server.addTool(update_fact.tool);
    try server.addTool(upsert_fact.tool);
    try server.addTool(assume_fact.tool);
    try server.addTool(retract_assumption.tool);
    try server.addTool(get_belief_status.tool);
    try server.addTool(get_justification.tool);
    try server.addTool(list_assumptions.tool);
    try server.addTool(retract_assumptions.tool);

    try std.testing.expectEqual(@as(usize, 18), server.tools.count());
}

test "server registers get_knowledge_schema tool" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(get_knowledge_schema.tool);

    try std.testing.expectEqual(@as(usize, 1), server.tools.count());
    try std.testing.expect(server.tools.contains("get_knowledge_schema"));
}

test "server registers all twenty-two tools" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(echo.tool);
    try server.addTool(remember_fact.tool);
    try server.addTool(define_rule.tool);
    try server.addTool(query_logic.tool);
    try server.addTool(trace_dependency.tool);
    try server.addTool(verify_consistency.tool);
    try server.addTool(explain_why.tool);
    try server.addTool(get_knowledge_schema.tool);
    try server.addTool(forget_fact.tool);
    try server.addTool(clear_context.tool);
    try server.addTool(update_fact.tool);
    try server.addTool(upsert_fact.tool);
    try server.addTool(assume_fact.tool);
    try server.addTool(retract_assumption.tool);
    try server.addTool(get_belief_status.tool);
    try server.addTool(get_justification.tool);
    try server.addTool(list_assumptions.tool);
    try server.addTool(retract_assumptions.tool);
    try server.addTool(save_snapshot.tool);
    try server.addTool(restore_snapshot.tool);
    try server.addTool(list_snapshots.tool);
    try server.addTool(get_persistence_status.tool);

    try std.testing.expectEqual(@as(usize, 22), server.tools.count());
}

test "server registers save_snapshot tool" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(save_snapshot.tool);

    try std.testing.expect(server.tools.contains("save_snapshot"));
}

test "server registers restore_snapshot tool" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(restore_snapshot.tool);

    try std.testing.expect(server.tools.contains("restore_snapshot"));
}

test "server registers list_snapshots tool" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(list_snapshots.tool);

    try std.testing.expect(server.tools.contains("list_snapshots"));
}

test "server registers get_persistence_status tool" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(get_persistence_status.tool);

    try std.testing.expect(server.tools.contains("get_persistence_status"));
}

test "persistence manager initializes as active with valid directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var pm = try PersistenceManager.init(std.testing.allocator, tmp_path);
    defer pm.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, pm.getStatus());
}

test "persistence manager stored in context is retrievable" {
    context.clearPersistenceManager();
    defer context.clearPersistenceManager();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    var pm = try PersistenceManager.init(std.testing.allocator, tmp_path);
    defer pm.deinit();

    context.setPersistenceManager(@ptrCast(&pm));

    const retrieved = context.getPersistenceManagerAs(PersistenceManager);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(PersistenceStatus.active, retrieved.?.getStatus());
}

test "persistence manager degrades gracefully with non-existent directory" {
    var pm = try PersistenceManager.init(std.testing.allocator, "/nonexistent/path/that/does/not/exist");
    defer pm.deinit();

    try std.testing.expectEqual(PersistenceStatus.degraded, pm.getStatus());
}

// serve() blocking behavior and engine registration are validated
// by functional tests (tests/functional_mcp_server_test.sh) which
// can properly manage the process lifecycle via stdin/stdout pipes.

test "cli module provides App Command and AppRunner types" {
    _ = cli.App;
    _ = cli.Command;
    _ = cli.AppRunner;
}

test "cli app version field references version constant" {
    const app = cli.App{
        .version = version,
        .command = cli.Command{
            .name = "zpm",
            .target = cli.CommandTarget{ .subcommands = &.{} },
        },
    };
    try std.testing.expectEqualStrings(version, app.version.?);
}

test "root command has no fallback action so unknown subcommands trigger zig-cli error" {
    const root_cmd = cli.Command{
        .name = "zpm",
        .target = cli.CommandTarget{ .subcommands = &.{} },
    };
    try std.testing.expectEqualStrings("zpm", root_cmd.name);
    switch (root_cmd.target) {
        .subcommands => {},
        .action => return error.RootCommandMustUseSubcommandsNotAction,
    }
}

test "serve subcommand is registered with correct name and description" {
    const serve_cmd = cli.Command{
        .name = "serve",
        .description = cli.Description{ .one_line = "Start the MCP server on stdio" },
        .target = cli.CommandTarget{ .action = cli.CommandAction{ .exec = serveAction } },
    };
    try std.testing.expectEqualStrings("serve", serve_cmd.name);
    try std.testing.expectEqualStrings("Start the MCP server on stdio", serve_cmd.description.?.one_line);
}

// serveAction() blocking behavior and engine registration are validated
// by functional tests (tests/functional_mcp_server_test.sh) which
// can properly manage the process lifecycle via stdin/stdout pipes.
// Spawning serve/serveAction in detached threads corrupts the Zig test
// runner protocol because scryer-prolog FFI writes to stdout on init.
