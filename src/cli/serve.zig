const std = @import("std");
const mcp = @import("mcp");
const project = @import("../project.zig");
const bootstrap = @import("bootstrap.zig");
const registry = @import("registry.zig");
const context = @import("../tools/context.zig");
const version = @import("../version.zig").version;

pub fn serveAction() anyerror!void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var ctx = bootstrap.initBootstrap(alloc) catch |err| switch (err) {
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

    var server = mcp.Server.init(.{
        .name = "zpm",
        .version = version,
        .title = "ZPM MCP Server",
        .description = "Prolog inference engine accessible via the Model Context Protocol",
        .allocator = alloc,
    });
    defer server.deinit();

    for (registry.all()) |def| {
        try server.addTool(try def.build(alloc));
    }

    try server.run(.stdio);
}
