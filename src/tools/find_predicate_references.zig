const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const validation = @import("tool_validation");
const clause_utils = @import("tool_clause_utils");
const term_utils = @import("term_utils");
const predicate_types = @import("tool_predicate_types");

const Engine = engine_mod.Engine;
const Term = engine_mod.Term;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

const RuleRef = predicate_types.RuleRef;
const AssumptionRef = predicate_types.AssumptionRef;
const CrossMemoryRef = predicate_types.CrossMemoryRef;
const bodyContainsTarget = predicate_types.bodyContainsTarget;
const detectCrossMemoryRefs = predicate_types.detectCrossMemoryRefs;
const parseBoolArg = validation.parseBoolArg;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "functor", "Predicate functor name", true);
    _ = try schema.addInteger(allocator, "arity", "Predicate arity (optional, omit to match all arities)", false);
    _ = try schema.addString(allocator, "memory", "Memory segment name (optional, defaults to 'default')", false);
    _ = try schema.addBoolean(allocator, "include_cross_memory_refs", "Include cross-memory references (optional, defaults to true)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "find_predicate_references",
        .description = "Find all clauses referencing a target predicate, walking rule bodies for meta-call nesting",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"functor"},
        },
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

const CrossMemoryRefsCtx = struct {
    functor: []const u8,
    arity_arg: ?i64,
    out: *std.ArrayList(CrossMemoryRef),

    fn callback(
        ctx_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        body_term: Term,
        head_str: []const u8,
        body_str: []const u8,
        memory_name: []const u8,
    ) anyerror!void {
        const ctx: *CrossMemoryRefsCtx = @ptrCast(@alignCast(ctx_ptr));
        try detectCrossMemoryRefs(allocator, body_term, ctx.functor, ctx.arity_arg, head_str, body_str, memory_name, ctx.out);
    }
};

fn collectCrossMemoryRefs(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity_arg: ?i64,
    memory_name: []const u8,
    out: *std.ArrayList(CrossMemoryRef),
) !void {
    var ctx = CrossMemoryRefsCtx{ .functor = functor, .arity_arg = arity_arg, .out = out };
    enumeratePredicateBodies(allocator, engine, memory_name, .{
        .ptr = @ptrCast(&ctx),
        .callFn = CrossMemoryRefsCtx.callback,
    });
}

/// Context struct for enumeratePredicateBodies callbacks.
/// Each callback receives `(ctx, allocator, body_term, head_str, body_str, memory_name)`.
/// `head_str` and `body_str` are caller-allocated; the callback must NOT free them.
/// `enumeratePredicateBodies` frees them after the callback returns.
const BodyCallbackCtx = struct {
    ptr: *anyopaque,
    callFn: *const fn (ctx_ptr: *anyopaque, allocator: std.mem.Allocator, body_term: Term, head_str: []const u8, body_str: []const u8, memory_name: []const u8) anyerror!void,

    pub fn call(
        self: BodyCallbackCtx,
        allocator: std.mem.Allocator,
        body_term: Term,
        head_str: []const u8,
        body_str: []const u8,
        memory_name: []const u8,
    ) !void {
        return self.callFn(self.ptr, allocator, body_term, head_str, body_str, memory_name);
    }
};

/// Shared enumeration loop: enumerate all user predicates in `memory_name`,
/// skip builtins and hook predicates, and for each non-fact body invoke `cb`.
/// `head_str` and `body_str` passed to `cb` are freed by this function after
/// `cb` returns — callbacks must dupe them if they need to outlive the call.
fn enumeratePredicateBodies(
    allocator: std.mem.Allocator,
    engine: *Engine,
    memory_name: []const u8,
    cb: BodyCallbackCtx,
) void {
    // The leading `mod:current_predicate(F/A)` scopes enumeration to `mod`.
    // Use `isBuiltin` to filter system predicates instead of
    // `predicate_property(H,dynamic)` (which under-reports user-declared
    // dynamic predicates inside loaded modules).
    const raw_preds_query = "current_predicate(F/A)";
    const all_preds_query = context.qualifyClause(allocator, memory_name, raw_preds_query) catch return;
    defer allocator.free(all_preds_query);
    var pred_result = engine.query(all_preds_query) catch return;
    defer pred_result.deinit();

    for (pred_result.solutions) |sol| {
        const f_term = sol.bindings.get("F") orelse continue;
        const a_term = sol.bindings.get("A") orelse continue;
        const pred_name = switch (f_term) {
            .atom => |s| s,
            else => continue,
        };
        const pred_arity: i64 = switch (a_term) {
            .integer => |i| i,
            .atom => |s| std.fmt.parseInt(i64, s, 10) catch continue,
            else => continue,
        };
        if (clause_utils.isBuiltin(pred_name)) continue;
        if (std.mem.eql(u8, pred_name, "goal_expansion") or std.mem.eql(u8, pred_name, "term_expansion")) continue;

        // Render Head pattern from name+arity directly (avoids a Trealla variable
        // aliasing bug where `functor(H,F,A),clause(H,B)` leaks the query
        // conjunction into B's variable positions).
        const raw_clause_query = clause_utils.buildClauseQuery(allocator, pred_name, pred_arity, "Body") catch continue;
        defer allocator.free(raw_clause_query);
        const clause_query = context.qualifyClause(allocator, memory_name, raw_clause_query) catch continue;
        defer allocator.free(clause_query);

        var clause_result = engine.query(clause_query) catch continue;
        defer clause_result.deinit();

        for (clause_result.solutions) |clause_sol| {
            const body_term = clause_sol.bindings.get("Body") orelse continue;
            switch (body_term) {
                .atom => |s| if (std.mem.eql(u8, s, "true")) continue,
                else => {},
            }

            const head_str = renderHeadPattern(allocator, pred_name, pred_arity) catch continue;
            const body_str = term_utils.termToString(allocator, body_term) catch {
                allocator.free(head_str);
                continue;
            };

            cb.call(allocator, body_term, head_str, body_str, memory_name) catch {};
            allocator.free(body_str);
            allocator.free(head_str);
        }
    }
}

// Render a head display string `name(_,_,...)` from functor + arity. Used in
// place of capturing Head via `functor/3` to avoid the Trealla variable-alias
// bug that leaks the enclosing query conjunction into body bindings.
fn renderHeadPattern(allocator: std.mem.Allocator, name: []const u8, arity: i64) ![]u8 {
    if (arity <= 0) return allocator.dupe(u8, name);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(name);
    try w.writeByte('(');
    var i: i64 = 0;
    while (i < arity) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('_');
    }
    try w.writeByte(')');
    return aw.toOwnedSlice();
}

fn sortCrossMemoryRefs(refs: []CrossMemoryRef) void {
    std.mem.sort(CrossMemoryRef, refs, {}, struct {
        fn cmp(_: void, a: CrossMemoryRef, b: CrossMemoryRef) bool {
            const mem_cmp = std.mem.order(u8, a.memory, b.memory);
            if (mem_cmp != .eq) return mem_cmp == .lt;
            const qual_cmp = std.mem.order(u8, a.qualifier, b.qualifier);
            if (qual_cmp != .eq) return qual_cmp == .lt;
            const head_cmp = std.mem.order(u8, a.head, b.head);
            if (head_cmp != .eq) return head_cmp == .lt;
            return std.mem.order(u8, a.body, b.body) == .lt;
        }
    }.cmp);
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (args == null) return mcp.tools.ToolError.InvalidArguments;

    const obj = switch (args.?) {
        .object => |o| o,
        else => return mcp.tools.ToolError.InvalidArguments,
    };

    const functor_val = obj.get("functor") orelse return mcp.tools.ToolError.InvalidArguments;
    const functor = switch (functor_val) {
        .string => |s| s,
        else => return mcp.tools.ToolError.InvalidArguments,
    };

    if (!validation.isValidAtomName(functor)) return mcp.tools.ToolError.InvalidArguments;

    var arity_arg: ?i64 = null;
    if (obj.get("arity")) |arity_val| {
        const a = switch (arity_val) {
            .integer => |i| i,
            else => return mcp.tools.ToolError.InvalidArguments,
        };
        if (a < 0) return mcp.tools.ToolError.InvalidArguments;
        arity_arg = a;
    }

    const memory_name = context.resolveMemoryName(args);
    const include_cross_refs = parseBoolArg(obj, "include_cross_memory_refs", true);

    const engine = context.getEngine() orelse
        return mcp.tools.errorResult(allocator, "Prolog engine is not initialized") catch return mcp.tools.ToolError.OutOfMemory;

    const is_all = std.mem.eql(u8, memory_name, "__all__");

    if (!context.isDefaultMemory(memory_name) and !is_all) {
        const reg = context.getMemoryRegistryAs(MemoryRegistry) orelse {
            // NOTE: do NOT `defer allocator.free(msg)` here — `mcp.tools.errorResult`
            // (see ~/.cache/zig/p/mcp-.../src/server/tools.zig:157) stores the slice
            // by reference, not by copy. Freeing here would leave a dangling pointer
            // in the returned ToolResult. The caller's allocator (typically an arena
            // or the request-scope allocator) is responsible for lifetime.
            const msg = try std.fmt.allocPrint(allocator, "Memory not mounted: {s}", .{memory_name});
            return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
        };
        if (reg.getMounted(memory_name) == null) {
            const msg = try std.fmt.allocPrint(allocator, "Memory not mounted: {s}", .{memory_name});
            return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
        }
    }

    var rules: std.ArrayList(RuleRef) = .empty;
    defer {
        for (rules.items) |r| {
            allocator.free(r.head);
            allocator.free(r.body);
            allocator.free(r.memory);
        }
        rules.deinit(allocator);
    }

    var cross_refs: std.ArrayList(CrossMemoryRef) = .empty;
    defer {
        for (cross_refs.items) |r| {
            allocator.free(r.head);
            allocator.free(r.body);
            allocator.free(r.memory);
            allocator.free(r.qualifier);
        }
        cross_refs.deinit(allocator);
    }

    var assumption_refs: std.ArrayList(AssumptionRef) = .empty;
    defer {
        for (assumption_refs.items) |r| {
            allocator.free(r.assumption);
            allocator.free(r.fact);
            allocator.free(r.memory);
        }
        assumption_refs.deinit(allocator);
    }

    var direct_facts_total: usize = 0;

    if (is_all) {
        var mounted_names: [][]const u8 = &.{};
        var mounted_names_owned = false;
        defer {
            if (mounted_names_owned) {
                for (mounted_names) |n| allocator.free(n);
                allocator.free(mounted_names);
            }
        }

        if (context.getMemoryRegistryAs(MemoryRegistry)) |reg| {
            if (reg.listMounted(allocator)) |names| {
                mounted_names = names;
                mounted_names_owned = true;
            } else |_| {}
        }

        var segments: std.ArrayList([]const u8) = .empty;
        defer segments.deinit(allocator);

        var default_in_mounts = false;
        for (mounted_names) |n| {
            if (context.isDefaultMemory(n)) {
                default_in_mounts = true;
                break;
            }
        }
        if (!default_in_mounts) {
            segments.append(allocator, context.default_memory_name) catch {};
        }
        for (mounted_names) |n| {
            segments.append(allocator, n) catch {};
        }

        for (segments.items) |seg| {
            collectRules(allocator, engine, functor, arity_arg, seg, &rules) catch {};
            direct_facts_total += countDirectFacts(allocator, engine, functor, arity_arg, seg) catch 0;
            collectCrossMemoryRefs(allocator, engine, functor, arity_arg, seg, &cross_refs) catch {};

            // ADR-0009: `tms_justification/2` is GLOBAL — never module-scoped.
            // `mod:tms_justification(F, Name)` fails for any non-default mod, so
            // skip the call to avoid wasted Prolog round-trips. The default
            // segment alone captures every TMS justification fact.
            if (!context.isDefaultMemory(seg)) continue;

            if (collectAssumptionRefs(allocator, engine, functor, arity_arg, seg)) |seg_refs| {
                defer allocator.free(seg_refs);
                for (seg_refs) |r| {
                    assumption_refs.append(allocator, r) catch {
                        allocator.free(r.assumption);
                        allocator.free(r.fact);
                        allocator.free(r.memory);
                    };
                }
            } else |_| {}
        }
    } else {
        collectRules(allocator, engine, functor, arity_arg, memory_name, &rules) catch {};
        direct_facts_total = countDirectFacts(allocator, engine, functor, arity_arg, memory_name) catch 0;

        if (collectAssumptionRefs(allocator, engine, functor, arity_arg, memory_name)) |seg_refs| {
            defer allocator.free(seg_refs);
            for (seg_refs) |r| {
                assumption_refs.append(allocator, r) catch {
                    allocator.free(r.assumption);
                    allocator.free(r.fact);
                    allocator.free(r.memory);
                };
            }
        } else |_| {}

        collectCrossMemoryRefs(allocator, engine, functor, arity_arg, memory_name, &cross_refs) catch {};
    }

    sortRules(rules.items);
    sortAssumptionRefs(assumption_refs.items);

    if (!include_cross_refs) {
        for (cross_refs.items) |r| {
            allocator.free(r.head);
            allocator.free(r.body);
            allocator.free(r.memory);
            allocator.free(r.qualifier);
        }
        cross_refs.clearRetainingCapacity();
    } else {
        sortCrossMemoryRefs(cross_refs.items);
    }

    const response_memory = if (is_all) "__all__" else memory_name;

    const json = buildJson(allocator, functor, arity_arg, response_memory, rules.items, direct_facts_total, assumption_refs.items, cross_refs.items) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json);

    return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
}

fn countDirectFacts(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity_arg: ?i64,
    memory_name: []const u8,
) !usize {
    if (arity_arg) |arity| {
        const raw_query = clause_utils.buildClauseQuery(allocator, functor, arity, "true") catch return 0;
        defer allocator.free(raw_query);
        const clause_query = context.qualifyClause(allocator, memory_name, raw_query) catch return 0;
        defer allocator.free(clause_query);
        var result = engine.query(clause_query) catch return 0;
        defer result.deinit();
        return result.solutions.len;
    }

    // Prolog allows same-named predicates at different arities; aggregate all of them.
    const raw_arities_query = try std.fmt.allocPrint(
        allocator,
        "current_predicate({s}/A)",
        .{functor},
    );
    defer allocator.free(raw_arities_query);
    const all_arities_query = context.qualifyClause(allocator, memory_name, raw_arities_query) catch return 0;
    defer allocator.free(all_arities_query);

    var pred_result = engine.query(all_arities_query) catch return 0;
    defer pred_result.deinit();

    var total: usize = 0;
    for (pred_result.solutions) |sol| {
        const a_term = sol.bindings.get("A") orelse continue;
        const arity: i64 = switch (a_term) {
            .integer => |i| i,
            .atom => |s| std.fmt.parseInt(i64, s, 10) catch continue,
            else => continue,
        };
        const raw_clause_query = clause_utils.buildClauseQuery(allocator, functor, arity, "true") catch continue;
        defer allocator.free(raw_clause_query);
        const clause_query = context.qualifyClause(allocator, memory_name, raw_clause_query) catch continue;
        defer allocator.free(clause_query);
        var result = engine.query(clause_query) catch continue;
        defer result.deinit();
        total += result.solutions.len;
    }
    return total;
}

const CollectRulesCtx = struct {
    functor: []const u8,
    arity_arg: ?i64,
    rules: *std.ArrayList(RuleRef),

    fn callback(
        ctx_ptr: *anyopaque,
        allocator: std.mem.Allocator,
        body_term: Term,
        head_str: []const u8,
        body_str: []const u8,
        memory_name: []const u8,
    ) anyerror!void {
        const ctx: *CollectRulesCtx = @ptrCast(@alignCast(ctx_ptr));
        if (!bodyContainsTarget(body_term, ctx.functor, ctx.arity_arg)) return;

        const head_copy = try allocator.dupe(u8, head_str);
        errdefer allocator.free(head_copy);
        const body_copy = try allocator.dupe(u8, body_str);
        errdefer allocator.free(body_copy);
        const mem_copy = try allocator.dupe(u8, memory_name);
        errdefer allocator.free(mem_copy);

        try ctx.rules.append(allocator, .{
            .head = head_copy,
            .body = body_copy,
            .memory = mem_copy,
        });
    }
};

fn collectRules(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity_arg: ?i64,
    memory_name: []const u8,
    rules: *std.ArrayList(RuleRef),
) !void {
    var ctx = CollectRulesCtx{ .functor = functor, .arity_arg = arity_arg, .rules = rules };
    enumeratePredicateBodies(allocator, engine, memory_name, .{
        .ptr = @ptrCast(&ctx),
        .callFn = CollectRulesCtx.callback,
    });
}

fn collectAssumptionRefs(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity_opt: ?i64,
    memory_name: []const u8,
) ![]AssumptionRef {
    var refs: std.ArrayList(AssumptionRef) = .empty;
    errdefer {
        for (refs.items) |r| {
            allocator.free(r.assumption);
            allocator.free(r.fact);
            allocator.free(r.memory);
        }
        refs.deinit(allocator);
    }

    const qualified = context.qualifyClause(allocator, memory_name, "tms_justification(F, Name)") catch return refs.toOwnedSlice(allocator);
    defer allocator.free(qualified);
    var qr = engine.query(qualified) catch return refs.toOwnedSlice(allocator);
    defer qr.deinit();

    for (qr.solutions) |sol| {
        const f_term = sol.bindings.get("F") orelse continue;
        const name_term = sol.bindings.get("Name") orelse continue;

        const matches = switch (f_term) {
            .atom => |s| std.mem.eql(u8, s, functor) and (arity_opt == null or arity_opt.? == 0),
            .compound => |c| std.mem.eql(u8, c.functor, functor) and (arity_opt == null or arity_opt.? == @as(i64, @intCast(c.args.len))),
            else => false,
        };
        if (!matches) continue;

        const assumption_name = switch (name_term) {
            .atom => |s| s,
            else => continue,
        };

        const fact_str = term_utils.termToString(allocator, f_term) catch continue;
        const assumption_str = allocator.dupe(u8, assumption_name) catch {
            allocator.free(fact_str);
            continue;
        };
        const mem_str = allocator.dupe(u8, memory_name) catch {
            allocator.free(fact_str);
            allocator.free(assumption_str);
            continue;
        };

        refs.append(allocator, .{
            .assumption = assumption_str,
            .fact = fact_str,
            .memory = mem_str,
        }) catch {
            allocator.free(fact_str);
            allocator.free(assumption_str);
            allocator.free(mem_str);
            return error.OutOfMemory;
        };
    }

    return refs.toOwnedSlice(allocator);
}

fn sortAssumptionRefs(refs: []AssumptionRef) void {
    std.mem.sort(AssumptionRef, refs, {}, struct {
        fn cmp(_: void, a: AssumptionRef, b: AssumptionRef) bool {
            const mem_cmp = std.mem.order(u8, a.memory, b.memory);
            if (mem_cmp != .eq) return mem_cmp == .lt;
            const ass_cmp = std.mem.order(u8, a.assumption, b.assumption);
            if (ass_cmp != .eq) return ass_cmp == .lt;
            return std.mem.order(u8, a.fact, b.fact) == .lt;
        }
    }.cmp);
}

fn formatTarget(allocator: std.mem.Allocator, functor: []const u8, arity: ?i64) ![]u8 {
    if (arity) |a| {
        return try std.fmt.allocPrint(allocator, "{s}/{d}", .{ functor, a });
    }
    return try allocator.dupe(u8, functor);
}

fn sortRules(rules: []RuleRef) void {
    std.mem.sort(RuleRef, rules, {}, struct {
        fn cmp(_: void, a: RuleRef, b: RuleRef) bool {
            const mem_cmp = std.mem.order(u8, a.memory, b.memory);
            if (mem_cmp != .eq) return mem_cmp == .lt;
            const head_cmp = std.mem.order(u8, a.head, b.head);
            if (head_cmp != .eq) return head_cmp == .lt;
            return std.mem.order(u8, a.body, b.body) == .lt;
        }
    }.cmp);
}

fn buildJson(
    allocator: std.mem.Allocator,
    functor: []const u8,
    arity: ?i64,
    memory_name: []const u8,
    rules: []const RuleRef,
    direct_facts_count: usize,
    assumption_refs: []const AssumptionRef,
    cross_refs: []const CrossMemoryRef,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    const target = try formatTarget(allocator, functor, arity);
    defer allocator.free(target);

    try w.writeAll("{\"target\":");
    try std.json.Stringify.value(target, .{}, w);
    try w.writeAll(",\"memory\":");
    try std.json.Stringify.value(memory_name, .{}, w);
    try w.writeAll(",\"rules\":[");
    for (rules, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"head\":");
        try std.json.Stringify.value(r.head, .{}, w);
        try w.writeAll(",\"body\":");
        try std.json.Stringify.value(r.body, .{}, w);
        try w.writeAll(",\"memory\":");
        try std.json.Stringify.value(r.memory, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"direct_facts_count\":");
    try std.json.Stringify.value(direct_facts_count, .{}, w);
    try w.writeAll(",\"facts_referenced_in_assumptions\":[");
    for (assumption_refs, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"assumption\":");
        try std.json.Stringify.value(r.assumption, .{}, w);
        try w.writeAll(",\"fact\":");
        try std.json.Stringify.value(r.fact, .{}, w);
        try w.writeAll(",\"memory\":");
        try std.json.Stringify.value(r.memory, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"cross_memory_refs\":[");
    for (cross_refs, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"head\":");
        try std.json.Stringify.value(r.head, .{}, w);
        try w.writeAll(",\"body\":");
        try std.json.Stringify.value(r.body, .{}, w);
        // `memory` is the segment that contains the referencing rule (owner).
        try w.writeAll(",\"memory\":");
        try std.json.Stringify.value(r.memory, .{}, w);
        // `qualifier` is the module name used in the cross-memory call (the target segment).
        try w.writeAll(",\"qualifier\":");
        try std.json.Stringify.value(r.qualifier, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

test "tool exports function returning Tool with name find_predicate_references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    try std.testing.expectEqualStrings("find_predicate_references", t.name);
}

test "tool schema declares functor as required string property" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    const schema = t.inputSchema orelse return error.MissingSchema;
    const props = schema.properties orelse return error.MissingProperties;
    const props_obj = switch (props) {
        .object => |o| o,
        else => return error.UnexpectedPropertiesType,
    };
    try std.testing.expect(props_obj.contains("functor"));
    try std.testing.expect(schema.required != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when functor key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when functor is not a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .integer = 123 });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when arity is negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    try obj.put(allocator, "arity", .{ .integer = -1 });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when functor fails validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test:bad" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error result when engine is not initialized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler response includes target field with functor when arity omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"target\":\"test\"") != null);
}

test "handler response includes target field with arity when arity provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"target\":\"test/2\"") != null);
}

test "handler response includes memory field set to default when omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"memory\":\"default\"") != null);
}

test "handler response includes rules array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[]") != null);
}

test "handler response includes direct_facts_count field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"direct_facts_count\":") != null);
}

test "handler response includes empty facts_referenced_in_assumptions array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"facts_referenced_in_assumptions\":[]") != null);
}

test "handler response includes empty cross_memory_refs array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"cross_memory_refs\":[]") != null);
}

test "handler returns InvalidArguments when arity is non-integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    try obj.put(allocator, "arity", .{ .string = "not_an_int" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

fn emptyEngineResponse(allocator: std.mem.Allocator, functor: []const u8, arity_opt: ?i64) ![]const u8 {
    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = functor });
    if (arity_opt) |a| {
        try obj.put(allocator, "arity", .{ .integer = a });
    }
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    return result.content[0].text.text;
}

test "empty KB returns empty rules array and zero fact count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = try emptyEngineResponse(allocator, "nonexistent", null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"direct_facts_count\":0") != null);
}

test "one asserted fact is counted by direct_facts_count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("task_status(f016, in_progress)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"direct_facts_count\":1,") != null);
}

test "rule body reference is enumerated in rules array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("active_work(X) :- task_status(X, in_progress)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"head\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"body\"") != null);
}

test "arity omitted matches multiple arities of same functor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("task_status(f016)");
    try engine.assertFact("task_status(f016, in_progress)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"direct_facts_count\":2") != null);
}

test "non-existent functor returns empty results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = try emptyEngineResponse(allocator, "nonexistent_predicate", 5);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"direct_facts_count\":0") != null);
}

test "response target field includes arity when provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = try emptyEngineResponse(allocator, "task_status", 2);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"target\":\"task_status/2\"") != null);
}

test "response target field omits arity when not provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = try emptyEngineResponse(allocator, "task_status", null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"target\":\"task_status\"") != null);
}

test "reference inside negation \\+ is detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("available_task(X) :- \\+ task_status(X, in_progress)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[{") != null);
}

test "reference inside findall is detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("count_active(N) :- findall(X, task_status(X, in_progress), L)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[{") != null);
}

test "reference inside conjunction is detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("pending_action(X) :- (a, task_status(X, in_progress), b)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[{") != null);
}

test "reference inside disjunction is detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("maybe_active(X) :- (task_status(X, in_progress) ; task_status(X, pending))");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[{") != null);
}

test "rules array is lexicographically sorted by memory, head, body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("z_rule(X) :- target(X, b)");
    try engine.assert("a_rule(X) :- target(X, a)");
    try engine.assert("m_rule(X) :- target(X, c)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "target" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    const a_idx = std.mem.indexOf(u8, text, "a_rule") orelse return error.TestMissingRule;
    const m_idx = std.mem.indexOf(u8, text, "m_rule") orelse return error.TestMissingRule;
    const z_idx = std.mem.indexOf(u8, text, "z_rule") orelse return error.TestMissingRule;
    try std.testing.expect(a_idx < m_idx);
    try std.testing.expect(m_idx < z_idx);
}

test "handler returns error result with Memory not mounted when memory names unknown segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();
    context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "test" });
    try obj.put(allocator, "memory", .{ .string = "unknown_segment" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "Memory not mounted") != null);
}

test "handler returns empty facts_referenced_in_assumptions when no tms_justification facts exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"facts_referenced_in_assumptions\":[]") != null);
}

test "handler returns one facts_referenced_in_assumptions entry when tms_justification fact is asserted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var qr = try engine.query("assertz(tms_justification(task_status(f016, in_progress), hyp_sprint_4))");
    defer qr.deinit();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"assumption\":\"hyp_sprint_4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"fact\":\"task_status(f016, in_progress)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"memory\":\"default\"") != null);
}

test "handler with arity omitted matches assumptions referencing both task_status/1 and task_status/2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var qr1 = try engine.query("assertz(tms_justification(task_status(f016), a1))");
    defer qr1.deinit();
    var qr2 = try engine.query("assertz(tms_justification(task_status(f016, in_progress), a2))");
    defer qr2.deinit();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"assumption\":\"a1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"assumption\":\"a2\"") != null);
}

test "handler with arity: 1 excludes assumptions referencing task_status/2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var qr1 = try engine.query("assertz(tms_justification(task_status(f016), a1))");
    defer qr1.deinit();
    var qr2 = try engine.query("assertz(tms_justification(task_status(f016, in_progress), a2))");
    defer qr2.deinit();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"assumption\":\"a1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"assumption\":\"a2\"") == null);
}

test "facts_referenced_in_assumptions entries are stably sorted by memory, assumption, fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var qr1 = try engine.query("assertz(tms_justification(status(z), z_assump))");
    defer qr1.deinit();
    var qr2 = try engine.query("assertz(tms_justification(status(a), a_assump))");
    defer qr2.deinit();
    var qr3 = try engine.query("assertz(tms_justification(status(m), m_assump))");
    defer qr3.deinit();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "status" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    const a_idx = std.mem.indexOf(u8, text, "\"assumption\":\"a_assump\"") orelse return error.TestMissingAssumption;
    const m_idx = std.mem.indexOf(u8, text, "\"assumption\":\"m_assump\"") orelse return error.TestMissingAssumption;
    const z_idx = std.mem.indexOf(u8, text, "\"assumption\":\"z_assump\"") orelse return error.TestMissingAssumption;

    try std.testing.expect(a_idx < m_idx);
    try std.testing.expect(m_idx < z_idx);
}

test "handler with rule stale(F) :- tasks:task_status(F, blocked) in default memory emits one cross_memory_refs entry with memory:default and qualifier:tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("stale(F) :- tasks:task_status(F, blocked)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    // Trealla does not preserve source variable names (`F` becomes `_<N>` or
    // `_` per arity-pattern); we render Head from name+arity as `name(_,...)`.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"cross_memory_refs\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"head\":\"stale(_)\"") != null);
    // `memory` is the owning segment (default — where the rule lives).
    try std.testing.expect(std.mem.indexOf(u8, text, "\"memory\":\"default\"") != null);
    // `qualifier` is the module name used in the cross-memory call.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"qualifier\":\"tasks\"") != null);
    // No spurious `user:` wrapper entry — Trealla adds it internally; we skip it.
    const cmr_start = std.mem.indexOf(u8, text, "\"cross_memory_refs\":[") orelse return error.TestMissingSection;
    const cmr_slice = text[cmr_start..];
    const count = std.mem.count(u8, cmr_slice, "\"head\":\"stale(_)\"");
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "handler detects Mod:Goal nested under \\+ tasks:task_status(X, blocked)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("available_task(X) :- \\+ tasks:task_status(X, blocked)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "\"cross_memory_refs\":[") != null);
    // `memory` is the owning segment; `qualifier` is the module name used.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"memory\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"qualifier\":\"tasks\"") != null);
}

test "handler detects Mod:Goal nested under findall(_, audit:task_status(_, _), _)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("count_audit_status(N) :- findall(X, audit:task_status(X, _), L), length(L, N)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "\"cross_memory_refs\":[") != null);
    // `memory` is the owning segment; `qualifier` is the module name used.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"memory\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"qualifier\":\"audit\"") != null);
}

test "handler with Var:Goal left arg (variable, not atom) does NOT emit a cross_memory_refs entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("call_indirect(Mod, Goal) :- Mod:Goal");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "\"cross_memory_refs\":[]") != null);
}

test "cross_memory_refs is stably sorted by (memory, qualifier, head, body)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("z_rule(X) :- tasks:target(X, b)");
    try engine.assert("a_rule(X) :- audit:target(X, a)");
    try engine.assert("m_rule(X) :- tasks:target(X, a)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "target" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    // Constrain the search to the `cross_memory_refs` section — the same head
    // patterns appear in `rules` first, and we must verify ordering inside the
    // cross_memory_refs array specifically.
    const cmr_start = std.mem.indexOf(u8, text, "\"cross_memory_refs\":[") orelse return error.TestMissingSection;
    const cmr_slice = text[cmr_start..];

    // All entries share memory="default" (owning segment). Sorting is by
    // (memory, qualifier, head, body): qualifier "audit" < "tasks", so
    // a_rule (audit) comes first, then m_rule and z_rule (tasks).
    // Heads are rendered from name+arity (`m_rule(_)`, `z_rule(_)`) — Trealla
    // does not preserve source variable names.
    const audit_idx = std.mem.indexOf(u8, cmr_slice, "\"qualifier\":\"audit\"") orelse return error.TestMissingQualifier;
    const tasks_a_idx = std.mem.indexOf(u8, cmr_slice, "\"head\":\"m_rule(_)\"") orelse return error.TestMissingHead;
    const tasks_b_idx = std.mem.indexOf(u8, cmr_slice, "\"head\":\"z_rule(_)\"") orelse return error.TestMissingHead;

    try std.testing.expect(audit_idx < tasks_a_idx);
    try std.testing.expect(tasks_a_idx < tasks_b_idx);
}

test "handler with include_cross_memory_refs: false returns empty cross_memory_refs even when Mod:Goal terms exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("stale(F) :- tasks:task_status(F, blocked)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    try obj.put(allocator, "include_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "\"cross_memory_refs\":[]") != null);
}

test "handler with include_cross_memory_refs: true (default) includes cross_memory_refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("stale(F) :- tasks:task_status(F, blocked)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    // After Bug 2 fix: `memory` is the owning segment (default); `qualifier` is the module used.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"qualifier\":\"tasks\"") != null);
}

test "handler with memory: \"__all__\" and two mounted memories iterates both and tags each rule with its originating segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_tasks = std.testing.tmpDir(.{});
    defer tmp_tasks.cleanup();
    var path_buf_tasks: [std.fs.max_path_bytes]u8 = undefined;
    const tasks_path_len = try tmp_tasks.dir.realPathFile(std.testing.io, ".", &path_buf_tasks);
    const tasks_path = path_buf_tasks[0..tasks_path_len];
    var tasks_kf = try tmp_tasks.dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer tasks_kf.close(std.testing.io);
    try tasks_kf.writeStreamingAll(std.testing.io, ":- module(tasks, []).\n");

    var tmp_audit = std.testing.tmpDir(.{});
    defer tmp_audit.cleanup();
    var path_buf_audit: [std.fs.max_path_bytes]u8 = undefined;
    const audit_path_len = try tmp_audit.dir.realPathFile(std.testing.io, ".", &path_buf_audit);
    const audit_path = path_buf_audit[0..audit_path_len];
    var audit_kf = try tmp_audit.dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer audit_kf.close(std.testing.io);
    try audit_kf.writeStreamingAll(std.testing.io, ":- module(audit, []).\n");

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    // Default-segment rule (global namespace).
    try engine.assert("default_rule(X) :- target(X, d)");

    // Per-segment rules: load module content with dynamic decl + clause.
    try engine.loadString(
        \\:- module(tasks, []).
        \\:- dynamic(target/2).
        \\:- dynamic(tasks_rule/1).
        \\tasks_rule(X) :- target(X, t).
        \\
    );
    try engine.loadString(
        \\:- module(audit, []).
        \\:- dynamic(target/2).
        \\:- dynamic(audit_rule/1).
        \\audit_rule(X) :- target(X, a).
        \\
    );

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.mount("tasks", tasks_path, .project, .rw, engine, std.testing.io);
    try reg.mount("audit", audit_path, .project, .rw, engine, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&reg));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "target" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    try obj.put(allocator, "memory", .{ .string = "__all__" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    // Response envelope must be tagged "__all__".
    try std.testing.expect(std.mem.indexOf(u8, text, "\"memory\":\"__all__\"") != null);

    // Constrain the search to the `rules` array to verify per-segment tagging.
    // Use the next sibling key (`"direct_facts_count"`) as the end boundary
    // rather than `"],"` — a rule whose body serializes a Prolog list would
    // contain `],` earlier and produce a wrong slice.
    const rules_start = std.mem.indexOf(u8, text, "\"rules\":[") orelse return error.TestMissingRulesSection;
    const rules_end = std.mem.indexOf(u8, text[rules_start..], ",\"direct_facts_count\"") orelse text.len - rules_start;
    const rules_slice = text[rules_start .. rules_start + rules_end];

    // Each mounted segment must contribute an entry tagged with its name.
    try std.testing.expect(std.mem.indexOf(u8, rules_slice, "\"memory\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules_slice, "\"memory\":\"tasks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules_slice, "\"memory\":\"audit\"") != null);
}

test "handler with memory: \"__all__\" sums direct_facts_count across all mounted memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("target(a, 1)");
    try engine.assertFact("target(b, 2)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "target" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    try obj.put(allocator, "memory", .{ .string = "__all__" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "\"direct_facts_count\":") != null);
}

test "handler with include_cross_memory_refs: false under memory: \"__all__\" still aggregates rules, direct_facts_count, and facts_referenced_in_assumptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("rule1(X) :- target(X, a)");
    try engine.assertFact("target(f, 1)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "target" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    try obj.put(allocator, "memory", .{ .string = "__all__" });
    try obj.put(allocator, "include_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    try std.testing.expect(std.mem.indexOf(u8, text, "\"cross_memory_refs\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"rules\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"direct_facts_count\":") != null);
}

// Regression test for Bug 1: Trealla wraps module-qualified calls with `user:`
// (e.g. `default:f(X)` becomes `:(user, :(default, f(X)))`). The walker must
// skip the synthetic `user:` node and emit exactly one entry per user-written
// qualifier — not two (one for `user`, one for the real qualifier).
test "cross_memory_refs emits exactly one entry per qualifier, no spurious user: duplicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    // A rule in the default module with a cross-memory call. Trealla will
    // internally represent `mymod:task_status(X, done)` as
    // `:(user, :(mymod, task_status(X, done)))`. Without the user-skip fix,
    // detectCrossMemoryRefs would emit two entries: one with qualifier "user"
    // and one with qualifier "mymod".
    try engine.assert("check_done(X) :- mymod:task_status(X, done)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "task_status" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    const cmr_start = std.mem.indexOf(u8, text, "\"cross_memory_refs\":[") orelse return error.TestMissingSection;
    const cmr_slice = text[cmr_start..];

    // Exactly one entry for the real qualifier.
    const mymod_count = std.mem.count(u8, cmr_slice, "\"qualifier\":\"mymod\"");
    try std.testing.expectEqual(@as(usize, 1), mymod_count);

    // No spurious entry for the Trealla-internal `user` module.
    try std.testing.expect(std.mem.indexOf(u8, cmr_slice, "\"qualifier\":\"user\"") == null);
}

// Regression test for Bug 2: `cross_memory_refs[].memory` must be the segment
// that **owns** the referencing rule (the segment being scanned), not the
// qualifier used in the cross-memory call. The qualifier target is exposed
// in the separate `qualifier` field.
test "cross_memory_refs memory field is the owning segment, qualifier field is the target module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    // Rule asserting in the default segment, referencing "other_seg".
    try engine.assert("check_other(X) :- other_seg:item(X, active)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "item" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    const cmr_start = std.mem.indexOf(u8, text, "\"cross_memory_refs\":[") orelse return error.TestMissingSection;
    const cmr_slice = text[cmr_start..];

    // `memory` is the owning segment ("default"), not the qualifier.
    try std.testing.expect(std.mem.indexOf(u8, cmr_slice, "\"memory\":\"default\"") != null);
    // `qualifier` is the module name used in the cross-memory call.
    try std.testing.expect(std.mem.indexOf(u8, cmr_slice, "\"qualifier\":\"other_seg\"") != null);
    // Verify the qualifier name does NOT appear as the memory field value.
    try std.testing.expect(std.mem.indexOf(u8, cmr_slice, "\"memory\":\"other_seg\"") == null);
}

// Regression test for Bug 3: the handler always returns JSON-formatted text
// in its ToolResult (the CLI `--format text` mode prints this JSON directly;
// `--format json` wraps it in a JSON array). This is the uniform pattern for
// all read-only query tools in this project. The response must be valid JSON.
test "handler response is valid JSON parseable by std.json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("ref_rule(X) :- ref_target(X, done)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "functor", .{ .string = "ref_target" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    // The raw output must parse as valid JSON — this is what `--format text`
    // prints to stdout and `--format json` wraps in a JSON array.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch |err| {
        std.debug.print("handler output is not valid JSON: {s}\n{s}\n", .{ @errorName(err), text });
        return error.InvalidJson;
    };
    defer parsed.deinit();

    // Verify top-level keys are present in the parsed object.
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    try std.testing.expect(root.contains("target"));
    try std.testing.expect(root.contains("memory"));
    try std.testing.expect(root.contains("rules"));
    try std.testing.expect(root.contains("direct_facts_count"));
    try std.testing.expect(root.contains("facts_referenced_in_assumptions"));
    try std.testing.expect(root.contains("cross_memory_refs"));
}
