const std = @import("std");
const mcp = @import("mcp");
const echo = @import("tools/echo.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = mcp.Server.init(.{
        .name = "zpm",
        .version = "0.1.0",
        .title = "Zig Package Manager MCP Server",
        .description = "MCP server for Zig package management via Prolog inference",
        .allocator = allocator,
    });
    defer server.deinit();

    try server.addTool(echo.tool);

    try server.run(.stdio);
}

test {
    _ = echo;
    _ = @import("prolog/engine.zig");
}

fn initTestServer() mcp.Server {
    return mcp.Server.init(.{
        .name = "zpm",
        .version = "0.1.0",
        .allocator = std.testing.allocator,
    });
}

test "server initializes with correct name and version" {
    var server = initTestServer();
    defer server.deinit();

    try std.testing.expectEqualStrings("zpm", server.config.name);
    try std.testing.expectEqualStrings("0.1.0", server.config.version);
}

test "server registers echo tool" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(echo.tool);

    try std.testing.expectEqual(@as(usize, 1), server.tools.count());
}

test "server capabilities include tools after registration" {
    var server = initTestServer();
    defer server.deinit();

    try std.testing.expect(server.capabilities.tools == null);
    try server.addTool(echo.tool);
    try std.testing.expect(server.capabilities.tools != null);
}
