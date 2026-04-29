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

pub const ParamKind = enum { string, integer };

pub const ParamSpec = struct {
    /// JSON key consumed by the MCP tool handler (e.g. "fact", "max_depth").
    /// The CLI long flag is derived by replacing `_` with `-`.
    mcp_key: []const u8,
    help: []const u8,
    required: bool,
    kind: ParamKind = .string,
    positional: bool = false,
    short: ?u8 = null,
};

pub const ToolDef = struct {
    cli_name: []const u8,
    mcp_name: []const u8,
    description: []const u8,
    build: *const fn (std.mem.Allocator) anyerror!mcp.tools.Tool,
    params: []const ParamSpec = &.{},
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
    .{
        .cli_name = "echo",
        .mcp_name = "echo",
        .description = "Echo back the input message",
        .build = &echo.tool,
        .params = &.{
            .{ .mcp_key = "message", .help = "The message to echo back", .required = true },
        },
    },
    .{
        .cli_name = "remember-fact",
        .mcp_name = "remember_fact",
        .description = "Assert a Prolog fact into the knowledge base",
        .build = &remember_fact.tool,
        .params = &.{
            .{ .mcp_key = "fact", .help = "A Prolog fact to assert (e.g. 'parent(tom, bob)')", .required = true },
        },
    },
    .{
        .cli_name = "define-rule",
        .mcp_name = "define_rule",
        .description = "Assert a Prolog rule into the knowledge base",
        .build = &define_rule.tool,
        .params = &.{
            .{ .mcp_key = "head", .help = "The head of the Prolog rule (e.g. 'grandparent(X, Z)')", .required = true, .positional = true },
            .{ .mcp_key = "body", .help = "The body of the Prolog rule (e.g. 'parent(X, Y), parent(Y, Z)')", .required = true },
        },
    },
    .{
        .cli_name = "query-logic",
        .mcp_name = "query_logic",
        .description = "Execute a Prolog goal and return variable bindings",
        .build = &query_logic.tool,
        .params = &.{
            .{ .mcp_key = "goal", .help = "A Prolog goal to evaluate (e.g. 'parent(X, bob)')", .required = true },
        },
    },
    .{
        .cli_name = "trace-dependency",
        .mcp_name = "trace_dependency",
        .description = "Trace transitive dependents of an atom via path/2 rules",
        .build = &trace_dependency.tool,
        .params = &.{
            .{ .mcp_key = "start_node", .help = "The reference atom whose dependents are traced", .required = true },
        },
    },
    .{
        .cli_name = "verify-consistency",
        .mcp_name = "verify_consistency",
        .description = "Check the knowledge base for integrity violations",
        .build = &verify_consistency.tool,
        .params = &.{
            .{ .mcp_key = "scope", .help = "Optional scope pattern for filtering violation predicates", .required = false },
        },
    },
    .{
        .cli_name = "explain-why",
        .mcp_name = "explain_why",
        .description = "Trace the proof tree for a fact as structured JSON",
        .build = &explain_why.tool,
        .params = &.{
            .{ .mcp_key = "fact", .help = "The Prolog fact to explain (e.g. 'grandparent(tom, jim)')", .required = true },
            .{ .mcp_key = "max_depth", .help = "Maximum proof tree depth (default: unlimited)", .required = false, .kind = .integer },
        },
    },
    .{
        .cli_name = "get-knowledge-schema",
        .mcp_name = "get_knowledge_schema",
        .description = "Introspect all defined predicates and their arities",
        .build = &buildGetKnowledgeSchema,
        .params = &.{},
    },
    .{
        .cli_name = "forget-fact",
        .mcp_name = "forget_fact",
        .description = "Retract a Prolog fact from the knowledge base",
        .build = &forget_fact.tool,
        .params = &.{
            .{ .mcp_key = "fact", .help = "The Prolog fact to retract (e.g. 'parent(tom, bob)')", .required = true },
        },
    },
    .{
        .cli_name = "clear-context",
        .mcp_name = "clear_context",
        .description = "Retract all facts matching a Prolog term pattern",
        .build = &clear_context.tool,
        .params = &.{
            .{ .mcp_key = "category", .help = "A Prolog term pattern passed to retractall/1 (e.g. 'task_status(_,_)')", .required = true },
        },
    },
    .{
        .cli_name = "update-fact",
        .mcp_name = "update_fact",
        .description = "Atomically replace an existing Prolog fact",
        .build = &update_fact.tool,
        .params = &.{
            .{ .mcp_key = "old_fact", .help = "The existing Prolog fact to retract", .required = true },
            .{ .mcp_key = "new_fact", .help = "The new Prolog fact to assert in its place", .required = true },
        },
    },
    .{
        .cli_name = "upsert-fact",
        .mcp_name = "upsert_fact",
        .description = "Insert or replace a Prolog fact",
        .build = &upsert_fact.tool,
        .params = &.{
            .{ .mcp_key = "fact", .help = "The Prolog fact to upsert (replaces clauses with same functor and first arg)", .required = true },
        },
    },
    .{
        .cli_name = "assume-fact",
        .mcp_name = "assume_fact",
        .description = "Assert a fact under a named assumption (TMS-tracked)",
        .build = &assume_fact.tool,
        .params = &.{
            .{ .mcp_key = "fact", .help = "The Prolog fact to assert under the assumption", .required = true, .positional = true },
            .{ .mcp_key = "assumption", .help = "The assumption name (lowercase, alphanumeric with underscores)", .required = true },
        },
    },
    .{
        .cli_name = "retract-assumption",
        .mcp_name = "retract_assumption",
        .description = "Retract an assumption and propagate removal",
        .build = &retract_assumption.tool,
        .params = &.{
            .{ .mcp_key = "assumption", .help = "The assumption name to retract", .required = true },
        },
    },
    .{
        .cli_name = "get-belief-status",
        .mcp_name = "get_belief_status",
        .description = "Query whether a belief is currently supported",
        .build = &get_belief_status.tool,
        .params = &.{
            .{ .mcp_key = "fact", .help = "The Prolog fact to check belief status for", .required = true },
        },
    },
    .{
        .cli_name = "get-justification",
        .mcp_name = "get_justification",
        .description = "Return all facts supported by a given assumption",
        .build = &get_justification.tool,
        .params = &.{
            .{ .mcp_key = "assumption", .help = "The assumption name to get justifications for", .required = true },
        },
    },
    .{
        .cli_name = "list-assumptions",
        .mcp_name = "list_assumptions",
        .description = "Return all registered named assumptions",
        .build = &buildListAssumptions,
        .params = &.{},
    },
    .{
        .cli_name = "retract-assumptions",
        .mcp_name = "retract_assumptions",
        .description = "Retract all assumptions matching a glob pattern",
        .build = &retract_assumptions.tool,
        .params = &.{
            .{ .mcp_key = "pattern", .help = "Glob-style pattern to match assumption names (e.g. 'hyp_*')", .required = true },
        },
    },
    .{
        .cli_name = "save-snapshot",
        .mcp_name = "save_snapshot",
        .description = "Persist the knowledge base to a named snapshot file",
        .build = &save_snapshot.tool,
        .params = &.{
            .{ .mcp_key = "name", .help = "The name for the snapshot file", .required = true },
        },
    },
    .{
        .cli_name = "restore-snapshot",
        .mcp_name = "restore_snapshot",
        .description = "Restore the knowledge base from a named snapshot",
        .build = &restore_snapshot.tool,
        .params = &.{
            .{ .mcp_key = "name", .help = "The name of the snapshot to restore", .required = true },
        },
    },
    .{
        .cli_name = "list-snapshots",
        .mcp_name = "list_snapshots",
        .description = "List all available knowledge base snapshots",
        .build = &buildListSnapshots,
        .params = &.{},
    },
    .{
        .cli_name = "get-persistence-status",
        .mcp_name = "get_persistence_status",
        .description = "Query persistence subsystem health and status",
        .build = &buildGetPersistenceStatus,
        .params = &.{},
    },
};

/// Comptime-friendly view of the registry, used by app.zig to inline-instantiate
/// `ToolCommand(def)` for each entry. The runtime `all()` helper still exists
/// for non-comptime callers.
pub const tool_defs_for_app = tool_defs;

pub fn all() []const ToolDef {
    return &tool_defs;
}

test "all returns 22 tool definitions" {
    const tools = all();
    try std.testing.expectEqual(@as(usize, 22), tools.len);
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

test "params declared for representative tools" {
    const tools = all();
    for (tools) |def| {
        if (std.mem.eql(u8, def.cli_name, "remember-fact")) {
            try std.testing.expectEqual(@as(usize, 1), def.params.len);
            try std.testing.expectEqualStrings("fact", def.params[0].mcp_key);
            try std.testing.expect(def.params[0].required);
            try std.testing.expectEqual(ParamKind.string, def.params[0].kind);
        } else if (std.mem.eql(u8, def.cli_name, "define-rule")) {
            try std.testing.expectEqual(@as(usize, 2), def.params.len);
            try std.testing.expectEqualStrings("head", def.params[0].mcp_key);
            try std.testing.expect(def.params[0].positional);
            try std.testing.expectEqualStrings("body", def.params[1].mcp_key);
            try std.testing.expect(!def.params[1].positional);
        } else if (std.mem.eql(u8, def.cli_name, "explain-why")) {
            try std.testing.expectEqual(@as(usize, 2), def.params.len);
            try std.testing.expectEqualStrings("max_depth", def.params[1].mcp_key);
            try std.testing.expectEqual(ParamKind.integer, def.params[1].kind);
            try std.testing.expect(!def.params[1].required);
        } else if (std.mem.eql(u8, def.cli_name, "list-assumptions")) {
            try std.testing.expectEqual(@as(usize, 0), def.params.len);
        } else if (std.mem.eql(u8, def.cli_name, "assume-fact")) {
            try std.testing.expectEqual(@as(usize, 2), def.params.len);
            try std.testing.expectEqualStrings("fact", def.params[0].mcp_key);
            try std.testing.expect(def.params[0].positional);
        }
    }
}
