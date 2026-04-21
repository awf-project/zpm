const std = @import("std");
const mcp = @import("mcp");

const echo = @import("../tools/echo.zig");
const remember_fact = @import("../tools/remember_fact.zig");
const define_rule = @import("../tools/define_rule.zig");
const query_logic = @import("../tools/query_logic.zig");
const trace_dependency = @import("../tools/trace_dependency.zig");
const verify_consistency = @import("../tools/verify_consistency.zig");
const explain_why = @import("../tools/explain_why.zig");
const get_knowledge_schema = @import("../tools/get_knowledge_schema.zig");
const forget_fact = @import("../tools/forget_fact.zig");
const clear_context = @import("../tools/clear_context.zig");
const update_fact = @import("../tools/update_fact.zig");
const upsert_fact = @import("../tools/upsert_fact.zig");
const assume_fact = @import("../tools/assume_fact.zig");
const retract_assumption = @import("../tools/retract_assumption.zig");
const get_belief_status = @import("../tools/get_belief_status.zig");
const get_justification = @import("../tools/get_justification.zig");
const list_assumptions = @import("../tools/list_assumptions.zig");
const retract_assumptions = @import("../tools/retract_assumptions.zig");
const save_snapshot = @import("../tools/save_snapshot.zig");
const restore_snapshot = @import("../tools/restore_snapshot.zig");
const list_snapshots = @import("../tools/list_snapshots.zig");
const get_persistence_status = @import("../tools/get_persistence_status.zig");

pub const ToolDef = struct {
    cli_name: []const u8,
    mcp_name: []const u8,
    /// One-line description shown in `zpm` / `zpm --help`. Kept short so the
    /// command table stays readable; full docs live in docs/reference/cli.md.
    description: []const u8,
    build: *const fn (std.mem.Allocator) anyerror!mcp.tools.Tool,
    positional_field: ?[]const u8 = null,
};

fn buildGetKnowledgeSchema(_: std.mem.Allocator) anyerror!mcp.tools.Tool {
    return get_knowledge_schema.tool;
}

fn buildListAssumptions(_: std.mem.Allocator) anyerror!mcp.tools.Tool {
    return list_assumptions.tool;
}

fn buildListSnapshots(_: std.mem.Allocator) anyerror!mcp.tools.Tool {
    return list_snapshots.tool;
}

fn buildGetPersistenceStatus(_: std.mem.Allocator) anyerror!mcp.tools.Tool {
    return get_persistence_status.tool;
}

const tool_defs: [22]ToolDef = .{
    .{ .cli_name = "echo", .mcp_name = "echo", .description = "Echo back the input message", .build = &echo.tool },
    .{ .cli_name = "remember-fact", .mcp_name = "remember_fact", .description = "Assert a Prolog fact into the knowledge base", .build = &remember_fact.tool },
    .{ .cli_name = "define-rule", .mcp_name = "define_rule", .description = "Assert a Prolog rule into the knowledge base", .build = &define_rule.tool, .positional_field = "head" },
    .{ .cli_name = "query-logic", .mcp_name = "query_logic", .description = "Execute a Prolog goal and return variable bindings", .build = &query_logic.tool },
    .{ .cli_name = "trace-dependency", .mcp_name = "trace_dependency", .description = "Trace transitive dependents of an atom via path/2 rules", .build = &trace_dependency.tool },
    .{ .cli_name = "verify-consistency", .mcp_name = "verify_consistency", .description = "Check the knowledge base for integrity violations", .build = &verify_consistency.tool },
    .{ .cli_name = "explain-why", .mcp_name = "explain_why", .description = "Trace the proof tree for a fact as structured JSON", .build = &explain_why.tool },
    .{ .cli_name = "get-knowledge-schema", .mcp_name = "get_knowledge_schema", .description = "Introspect all defined predicates and their arities", .build = &buildGetKnowledgeSchema },
    .{ .cli_name = "forget-fact", .mcp_name = "forget_fact", .description = "Retract a Prolog fact from the knowledge base", .build = &forget_fact.tool },
    .{ .cli_name = "clear-context", .mcp_name = "clear_context", .description = "Retract all facts matching a Prolog term pattern", .build = &clear_context.tool },
    .{ .cli_name = "update-fact", .mcp_name = "update_fact", .description = "Atomically replace an existing Prolog fact", .build = &update_fact.tool },
    .{ .cli_name = "upsert-fact", .mcp_name = "upsert_fact", .description = "Insert or replace a Prolog fact", .build = &upsert_fact.tool },
    .{ .cli_name = "assume-fact", .mcp_name = "assume_fact", .description = "Assert a fact under a named assumption (TMS-tracked)", .build = &assume_fact.tool, .positional_field = "fact" },
    .{ .cli_name = "retract-assumption", .mcp_name = "retract_assumption", .description = "Retract an assumption and propagate removal", .build = &retract_assumption.tool },
    .{ .cli_name = "get-belief-status", .mcp_name = "get_belief_status", .description = "Query whether a belief is currently supported", .build = &get_belief_status.tool },
    .{ .cli_name = "get-justification", .mcp_name = "get_justification", .description = "Return all facts supported by a given assumption", .build = &get_justification.tool },
    .{ .cli_name = "list-assumptions", .mcp_name = "list_assumptions", .description = "Return all registered named assumptions", .build = &buildListAssumptions },
    .{ .cli_name = "retract-assumptions", .mcp_name = "retract_assumptions", .description = "Retract all assumptions matching a glob pattern", .build = &retract_assumptions.tool },
    .{ .cli_name = "save-snapshot", .mcp_name = "save_snapshot", .description = "Persist the knowledge base to a named snapshot file", .build = &save_snapshot.tool },
    .{ .cli_name = "restore-snapshot", .mcp_name = "restore_snapshot", .description = "Restore the knowledge base from a named snapshot", .build = &restore_snapshot.tool },
    .{ .cli_name = "list-snapshots", .mcp_name = "list_snapshots", .description = "List all available knowledge base snapshots", .build = &buildListSnapshots },
    .{ .cli_name = "get-persistence-status", .mcp_name = "get_persistence_status", .description = "Query persistence subsystem health and status", .build = &buildGetPersistenceStatus },
};

pub fn all() []const ToolDef {
    return &tool_defs;
}

pub fn containsKebab(name: []const u8) bool {
    for (tool_defs) |def| {
        if (std.mem.eql(u8, def.cli_name, name)) return true;
    }
    return false;
}

test "all returns 22 tool definitions" {
    const tools = all();
    try std.testing.expectEqual(@as(usize, 22), tools.len);
}

test "containsKebab finds known tool" {
    try std.testing.expect(containsKebab("remember-fact"));
}

test "containsKebab returns false for unknown tool" {
    try std.testing.expect(!containsKebab("unknown-cmd"));
}

test "define-rule positional_field is head" {
    for (tool_defs) |def| {
        if (std.mem.eql(u8, def.cli_name, "define-rule")) {
            try std.testing.expectEqualStrings("head", def.positional_field.?);
            return;
        }
    }
    return error.ToolNotFound;
}

test "assume-fact positional_field is fact" {
    for (tool_defs) |def| {
        if (std.mem.eql(u8, def.cli_name, "assume-fact")) {
            try std.testing.expectEqualStrings("fact", def.positional_field.?);
            return;
        }
    }
    return error.ToolNotFound;
}

test "tools without explicit positional_field have null" {
    for (tool_defs) |def| {
        if (std.mem.eql(u8, def.cli_name, "define-rule")) continue;
        if (std.mem.eql(u8, def.cli_name, "assume-fact")) continue;
        try std.testing.expectEqual(@as(?[]const u8, null), def.positional_field);
    }
}

test "echo build returns tool with mcp name echo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (tool_defs) |def| {
        if (std.mem.eql(u8, def.cli_name, "echo")) {
            const t = try def.build(arena.allocator());
            try std.testing.expectEqualStrings("echo", t.name);
            return;
        }
    }
    return error.ToolNotFound;
}

test "remember-fact build returns tool with mcp name remember_fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (tool_defs) |def| {
        if (std.mem.eql(u8, def.cli_name, "remember-fact")) {
            const t = try def.build(arena.allocator());
            try std.testing.expectEqualStrings("remember_fact", t.name);
            return;
        }
    }
    return error.ToolNotFound;
}
