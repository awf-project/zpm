const std = @import("std");
const mcp = @import("mcp");
const echo = @import("tools/echo.zig");
const remember_fact = @import("tools/remember_fact.zig");
const define_rule = @import("tools/define_rule.zig");
const context = @import("tools/context.zig");
const Engine = @import("prolog/engine.zig").Engine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var server = mcp.Server.init(.{
        .name = "zpm",
        .version = "0.1.0",
        .title = "Zig Package Manager MCP Server",
        .description = "MCP server for Zig package management via Prolog inference",
        .allocator = allocator,
    });
    defer server.deinit();

    try server.addTool(echo.tool);
    try server.addTool(remember_fact.tool);
    try server.addTool(define_rule.tool);

    try server.run(.stdio);
}

test {
    _ = echo;
    _ = @import("tools/context.zig");
    _ = @import("tools/remember_fact.zig");
    _ = @import("tools/define_rule.zig");
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

test "server capabilities include tools after registration" {
    var server = initTestServer();
    defer server.deinit();

    try std.testing.expect(server.capabilities.tools == null);
    try server.addTool(echo.tool);
    try std.testing.expect(server.capabilities.tools != null);
}

test "server registers both echo and remember_fact tools" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(echo.tool);
    try server.addTool(remember_fact.tool);

    try std.testing.expectEqual(@as(usize, 2), server.tools.count());
}

test "server registers all three tools" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(echo.tool);
    try server.addTool(remember_fact.tool);
    try server.addTool(define_rule.tool);

    try std.testing.expectEqual(@as(usize, 3), server.tools.count());
}
