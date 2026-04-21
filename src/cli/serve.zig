const std = @import("std");
const mcp = @import("mcp");
const project = @import("../project.zig");
const bootstrap = @import("bootstrap.zig");
const registry = @import("registry.zig");
const context = @import("../tools/context.zig");
const version = @import("../version.zig").version;

pub fn serveAction() anyerror!void {
    const alloc = std.heap.page_allocator;
    var ctx = bootstrap.initBootstrap(alloc) catch |err| switch (err) {
        project.ProjectError.NotFound => {
            std.debug.print("No .zpm/ directory found. Run `zpm init` to initialize a project.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer ctx.deinit();
    context.setPersistenceManager(@ptrCast(&ctx.pm));

    var server = mcp.Server.init(.{
        .name = "zpm",
        .version = version,
        .title = "Zig Package Manager MCP Server",
        .description = "MCP server for Zig package management via Prolog inference",
        .allocator = alloc,
    });
    defer server.deinit();

    for (registry.all()) |def| {
        try server.addTool(try def.build(alloc));
    }

    try server.run(.stdio);
}
