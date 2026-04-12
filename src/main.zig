const std = @import("std");
const mcp = @import("mcp");
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
    try server.addTool(query_logic.tool);
    try server.addTool(trace_dependency.tool);
    try server.addTool(verify_consistency.tool);
    try server.addTool(explain_why.tool);
    try server.addTool(get_knowledge_schema.tool);
    try server.addTool(forget_fact.tool);
    try server.addTool(clear_context.tool);

    try server.run(.stdio);
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

test "server registers all ten tools" {
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

    try std.testing.expectEqual(@as(usize, 10), server.tools.count());
}

test "server registers get_knowledge_schema tool" {
    var server = initTestServer();
    defer server.deinit();

    try server.addTool(get_knowledge_schema.tool);

    try std.testing.expectEqual(@as(usize, 1), server.tools.count());
    try std.testing.expect(server.tools.contains("get_knowledge_schema"));
}
