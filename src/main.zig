const std = @import("std");
const mcp = @import("mcp");
const cli = @import("cli");
const cli_app = @import("cli/app.zig");
const registry = @import("cli/registry.zig");

const version = @import("version.zig").version;

pub fn main() !void {
    var r = try cli.AppRunner.init(std.heap.page_allocator);
    const app = try cli_app.buildApp(&r);
    return r.run(&app);
}

test {
    _ = @import("prolog/engine.zig");
    _ = registry;
    _ = @import("cli/tool_command.zig");
    _ = @import("cli/app.zig");
    _ = @import("cli/serve.zig");
    _ = @import("cli/init.zig");
    _ = @import("cli/upgrade.zig");
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
