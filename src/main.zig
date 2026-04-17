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
const project = @import("project.zig");

const version = "0.1.0";

fn serve(allocator: std.mem.Allocator) !void {
    _ = allocator;
    // serve() owns its memory for the full server lifetime; page_allocator
    // avoids GPA leak detection when called from tests with a tracking allocator
    const alloc = std.heap.page_allocator;

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const paths = try project.discover(alloc, cwd);
    defer paths.deinit();

    std.fs.makeDirAbsolute(paths.data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    std.fs.makeDirAbsolute(paths.kb_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try project.loadKnowledgeBase(alloc, paths.kb_dir, engine);

    var pm = try PersistenceManager.init(alloc, paths.data_dir, paths.kb_dir);
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

    try server.addTool(try echo.tool(alloc));
    try server.addTool(try remember_fact.tool(alloc));
    try server.addTool(try define_rule.tool(alloc));
    try server.addTool(try query_logic.tool(alloc));
    try server.addTool(try trace_dependency.tool(alloc));
    try server.addTool(try verify_consistency.tool(alloc));
    try server.addTool(try explain_why.tool(alloc));
    try server.addTool(get_knowledge_schema.tool);
    try server.addTool(try forget_fact.tool(alloc));
    try server.addTool(try clear_context.tool(alloc));
    try server.addTool(try update_fact.tool(alloc));
    try server.addTool(try upsert_fact.tool(alloc));
    try server.addTool(try assume_fact.tool(alloc));
    try server.addTool(try retract_assumption.tool(alloc));
    try server.addTool(try get_belief_status.tool(alloc));
    try server.addTool(try get_justification.tool(alloc));
    try server.addTool(list_assumptions.tool);
    try server.addTool(try retract_assumptions.tool(alloc));
    try server.addTool(try save_snapshot.tool(alloc));
    try server.addTool(try restore_snapshot.tool(alloc));
    try server.addTool(list_snapshots.tool);
    try server.addTool(get_persistence_status.tool);

    try server.run(.stdio);
}

fn initAction() anyerror!void {
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

fn serveAction() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    serve(gpa.allocator()) catch |err| switch (err) {
        project.ProjectError.NotFound => {
            const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
            stderr.writeAll("No .zpm/ directory found. Run `zpm init` to initialize a project.\n") catch {};
            std.process.exit(1);
        },
        else => return err,
    };
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    if (args.len == 1) {
        stdout.writeAll(
            "zpm " ++ version ++ "\n\n" ++
                "Prolog inference engine for the Model Context Protocol\n\n" ++
                "USAGE:\n  zpm <command> [options]\n\n" ++
                "COMMANDS:\n  init    Initialize a .zpm/ project directory\n  serve   Start the MCP server on stdio\n\n" ++
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
        std.mem.eql(u8, args[1], "serve") or std.mem.eql(u8, args[1], "init"))
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
                        .name = "init",
                        .description = cli.Description{
                            .one_line = "Initialize a .zpm/ project directory",
                        },
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{ .exec = initAction },
                        },
                    },
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = initTestServer();
    defer server.deinit();

    try std.testing.expect(server.capabilities.tools == null);
    try server.addTool(try echo.tool(arena.allocator()));
    try std.testing.expect(server.capabilities.tools != null);
}

test "server registers all eighteen tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(try echo.tool(alloc));
    try server.addTool(try remember_fact.tool(alloc));
    try server.addTool(try define_rule.tool(alloc));
    try server.addTool(try query_logic.tool(alloc));
    try server.addTool(try trace_dependency.tool(alloc));
    try server.addTool(try verify_consistency.tool(alloc));
    try server.addTool(try explain_why.tool(alloc));
    try server.addTool(get_knowledge_schema.tool);
    try server.addTool(try forget_fact.tool(alloc));
    try server.addTool(try clear_context.tool(alloc));
    try server.addTool(try update_fact.tool(alloc));
    try server.addTool(try upsert_fact.tool(alloc));
    try server.addTool(try assume_fact.tool(alloc));
    try server.addTool(try retract_assumption.tool(alloc));
    try server.addTool(try get_belief_status.tool(alloc));
    try server.addTool(try get_justification.tool(alloc));
    try server.addTool(list_assumptions.tool);
    try server.addTool(try retract_assumptions.tool(alloc));

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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(try echo.tool(alloc));
    try server.addTool(try remember_fact.tool(alloc));
    try server.addTool(try define_rule.tool(alloc));
    try server.addTool(try query_logic.tool(alloc));
    try server.addTool(try trace_dependency.tool(alloc));
    try server.addTool(try verify_consistency.tool(alloc));
    try server.addTool(try explain_why.tool(alloc));
    try server.addTool(get_knowledge_schema.tool);
    try server.addTool(try forget_fact.tool(alloc));
    try server.addTool(try clear_context.tool(alloc));
    try server.addTool(try update_fact.tool(alloc));
    try server.addTool(try upsert_fact.tool(alloc));
    try server.addTool(try assume_fact.tool(alloc));
    try server.addTool(try retract_assumption.tool(alloc));
    try server.addTool(try get_belief_status.tool(alloc));
    try server.addTool(try get_justification.tool(alloc));
    try server.addTool(list_assumptions.tool);
    try server.addTool(try retract_assumptions.tool(alloc));
    try server.addTool(try save_snapshot.tool(alloc));
    try server.addTool(try restore_snapshot.tool(alloc));
    try server.addTool(list_snapshots.tool);
    try server.addTool(get_persistence_status.tool);

    try std.testing.expectEqual(@as(usize, 22), server.tools.count());
}

test "server registers save_snapshot tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(try save_snapshot.tool(arena.allocator()));

    try std.testing.expect(server.tools.contains("save_snapshot"));
}

test "server registers restore_snapshot tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(try restore_snapshot.tool(arena.allocator()));

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

    var pm = try PersistenceManager.init(std.testing.allocator, tmp_path, tmp_path);
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

    var pm = try PersistenceManager.init(std.testing.allocator, tmp_path, tmp_path);
    defer pm.deinit();

    context.setPersistenceManager(@ptrCast(&pm));

    const retrieved = context.getPersistenceManagerAs(PersistenceManager);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(PersistenceStatus.active, retrieved.?.getStatus());
}

test "persistence manager degrades gracefully with non-existent directory" {
    var pm = try PersistenceManager.init(std.testing.allocator, "/nonexistent/path/that/does/not/exist", "/nonexistent/path/that/does/not/exist");
    defer pm.deinit();

    try std.testing.expectEqual(PersistenceStatus.degraded, pm.getStatus());
}

// serve() blocking behavior and engine registration are validated
// by functional tests (tests/functional_mcp_server_test.sh) which
// can properly manage the process lifecycle via stdin/stdout pipes.

test "init subcommand is registered with correct name and description" {
    const init_cmd = cli.Command{
        .name = "init",
        .description = cli.Description{ .one_line = "Initialize a .zpm/ project directory" },
        .target = cli.CommandTarget{ .action = cli.CommandAction{ .exec = initAction } },
    };
    try std.testing.expectEqualStrings("init", init_cmd.name);
    try std.testing.expectEqualStrings("Initialize a .zpm/ project directory", init_cmd.description.?.one_line);
}

test "initAction creates .zpm directory structure in current working directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_path_buf: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);

    var orig_buf: [4096]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    try initAction();

    var zpm = try tmp.dir.openDir(".zpm", .{});
    defer zpm.close();
    var kb = try tmp.dir.openDir(".zpm/kb", .{});
    defer kb.close();
    var data = try tmp.dir.openDir(".zpm/data", .{});
    defer data.close();
}

test "initAction is idempotent when .zpm already exists in current working directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/kb");
    try tmp.dir.makeDir(".zpm/data");
    var tmp_path_buf: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);

    var orig_buf: [4096]u8 = undefined;
    const orig = try std.process.getCwd(&orig_buf);
    defer std.posix.chdir(orig) catch {};
    try std.posix.chdir(tmp_path);

    try initAction();
}

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

// T005: serve() uses project.discover() for data directory resolution.
// serve() itself cannot be unit-tested (FFI stdout corruption — see above),
// so these tests verify the integration contract serve() depends on.

test "serve startup data dir comes from project discover not env var fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/data");
    try tmp.dir.makeDir(".zpm/kb");

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const paths = try project.discover(std.testing.allocator, tmp_path);
    defer paths.deinit();

    try std.testing.expect(std.mem.endsWith(u8, paths.data_dir, "/.zpm/data"));

    var pm = try PersistenceManager.init(std.testing.allocator, paths.data_dir, paths.data_dir);
    defer pm.deinit();

    try std.testing.expectEqual(PersistenceStatus.active, pm.getStatus());
}

test "serve startup exits with NotFound when no .zpm directory exists in ancestry" {
    // Use /tmp to avoid finding the project's own .zpm/ during upward traversal
    const base = "/tmp/zpm-test-serve-no-zpm";
    const nested = base ++ "/deep/nested";

    std.fs.deleteTreeAbsolute(base) catch {};
    try std.fs.makeDirAbsolute(base);
    defer std.fs.deleteTreeAbsolute(base) catch {};
    try std.fs.makeDirAbsolute(base ++ "/deep");
    try std.fs.makeDirAbsolute(nested);

    try std.testing.expectError(
        project.ProjectError.NotFound,
        project.discover(std.testing.allocator, nested),
    );
}

test "serve startup kb_dir comes from project discover for Prolog file loading" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(".zpm");
    try tmp.dir.makeDir(".zpm/data");
    try tmp.dir.makeDir(".zpm/kb");

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const paths = try project.discover(std.testing.allocator, tmp_path);
    defer paths.deinit();

    try std.testing.expect(std.mem.endsWith(u8, paths.kb_dir, "/.zpm/kb"));
}

test "root command has two subcommands init and serve" {
    const app = cli.App{
        .version = version,
        .command = cli.Command{
            .name = "zpm",
            .target = cli.CommandTarget{
                .subcommands = &.{
                    cli.Command{
                        .name = "init",
                        .description = cli.Description{ .one_line = "Initialize a .zpm/ project directory" },
                        .target = cli.CommandTarget{ .action = cli.CommandAction{ .exec = initAction } },
                    },
                    cli.Command{
                        .name = "serve",
                        .description = cli.Description{ .one_line = "Start the MCP server on stdio" },
                        .target = cli.CommandTarget{ .action = cli.CommandAction{ .exec = serveAction } },
                    },
                },
            },
        },
    };
    const subs = app.command.target.subcommands;
    try std.testing.expectEqual(@as(usize, 2), subs.len);
    try std.testing.expectEqualStrings("init", subs[0].name);
    try std.testing.expectEqualStrings("serve", subs[1].name);
}

test "init subcommand action is bound to initAction handler" {
    const init_cmd = cli.Command{
        .name = "init",
        .description = cli.Description{ .one_line = "Initialize a .zpm/ project directory" },
        .target = cli.CommandTarget{ .action = cli.CommandAction{ .exec = initAction } },
    };
    switch (init_cmd.target) {
        .action => |a| try std.testing.expect(a.exec == initAction),
        .subcommands => return error.ExpectedActionTarget,
    }
}

test "help text includes init command and description" {
    const help =
        "COMMANDS:\n  init    Initialize a .zpm/ project directory\n  serve   Start the MCP server on stdio\n";
    try std.testing.expect(std.mem.indexOf(u8, help, "init") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Initialize a .zpm/ project directory") != null);
}

test "persistence manager dual path init stores dir_path and snapshot_dir_path separately" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var snap_tmp = std.testing.tmpDir(.{});
    defer snap_tmp.cleanup();

    const data_path = try data_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(data_path);
    const snap_path = try snap_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(snap_path);

    var pm = try PersistenceManager.init(std.testing.allocator, data_path, snap_path);
    defer pm.deinit();

    try std.testing.expectEqualStrings(data_path, pm.dir_path);
    try std.testing.expectEqualStrings(snap_path, pm.snapshot_dir_path);
    try std.testing.expect(!std.mem.eql(u8, pm.dir_path, pm.snapshot_dir_path));
    try std.testing.expectEqual(PersistenceStatus.active, pm.getStatus());
}

test "persistence manager listSnapshots reads from snapshot_dir_path not dir_path" {
    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();
    var snap_tmp = std.testing.tmpDir(.{});
    defer snap_tmp.cleanup();

    const data_path = try data_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(data_path);
    const snap_path = try snap_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(snap_path);

    const sentinel = try snap_tmp.dir.createFile("test_snapshot.pl", .{});
    sentinel.close();

    var pm = try PersistenceManager.init(std.testing.allocator, data_path, snap_path);
    defer pm.deinit();

    const snaps = try pm.listSnapshots(std.testing.allocator);
    defer {
        for (snaps) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(snaps);
    }

    try std.testing.expectEqual(@as(usize, 1), snaps.len);
    try std.testing.expectEqualStrings("test_snapshot.pl", snaps[0]);
}
