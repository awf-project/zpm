const std = @import("std");
const mcp = @import("mcp");
const project = @import("../project.zig");
const bootstrap = @import("bootstrap.zig");
const registry = @import("registry.zig");
const context = @import("../tools/context.zig");
const version = @import("../version.zig").version;

pub fn serveAction() anyerror!void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = bootstrap.initBootstrap(alloc, io) catch |err| switch (err) {
        project.ProjectError.NotFound => {
            std.debug.print("No .zpm/ directory found. Run `zpm init` to initialize a project.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer ctx.deinit();
    context.setPersistenceManager(@ptrCast(&ctx.pm));
    defer context.clearPersistenceManager();
    context.setMemoryRegistry(@ptrCast(&ctx.registry));
    defer context.clearMemoryRegistry();
    context.setMountManifest(@ptrCast(&ctx.manifest));
    defer context.clearMountManifest();
    context.setKbDir(ctx.paths.kb_dir);
    defer context.clearKbDir();
    defer context.clearEngine();

    // Declared before server so LIFO defer frees the arena AFTER server.deinit()
    // (which frees only the HashMap backing array, not the stored schema trees).
    var schema_arena = std.heap.ArenaAllocator.init(alloc);
    defer schema_arena.deinit();
    const schema_alloc = schema_arena.allocator();

    var server = mcp.Server.init(alloc, .{
        .name = "zpm",
        .version = version,
        .title = "ZPM MCP Server",
        .description = "Prolog inference engine accessible via the Model Context Protocol",
    });
    defer server.deinit();

    for (registry.all()) |def| {
        try server.addTool(try def.build(schema_alloc));
    }

    try server.run(io, alloc, .stdio);
}

test "all registry tool schemas build through an arena without GPA leak" {
    // Allocate schemas from an arena backed by the test allocator. arena.deinit()
    // frees them in one shot; anything that bypasses the arena (e.g. a build() that
    // hardcoded another allocator) would leak and be flagged by std.testing.allocator.
    // Guards the invariant "build() respects its allocator argument"; it cannot
    // observe serveAction()'s call site directly (blocking I/O, not unit-testable).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema_alloc = arena.allocator();

    for (registry.all()) |def| {
        _ = try def.build(schema_alloc);
    }
}
