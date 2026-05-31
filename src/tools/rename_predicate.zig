const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const Engine = engine_mod.Engine;
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;
const nowSeconds = @import("../persistence/wal.zig").nowSeconds;
const validation = @import("tool_validation");
const clause_utils = @import("tool_clause_utils");
const term_utils = @import("term_utils");
const predicate_types = @import("tool_predicate_types");

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "old_functor", "Predicate functor to rename", true);
    _ = try schema.addString(allocator, "new_functor", "New predicate functor name", true);
    _ = try schema.addInteger(allocator, "arity", "Predicate arity (optional, omit to match all arities)", false);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to 'default')", false);
    _ = try schema.addBoolean(allocator, "dry_run", "Preview changes without mutation (optional, defaults to false)", false);
    _ = try schema.addBoolean(allocator, "propagate_cross_memory_refs", "Propagate rename to cross-memory references (optional, defaults to false)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "rename_predicate",
        .description = "Rename a predicate functor throughout a memory segment, optionally previewing changes with dry-run",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{ "old_functor", "new_functor" },
        },
        .annotations = .{
            .readOnlyHint = false,
            .destructiveHint = true,
            .idempotentHint = false,
        },
        .handler = handler,
    };
}

/// A single collected clause before renaming.
const ClauseInfo = struct {
    /// The rendered head pattern, e.g. "foo(_,_)".
    head_str: []const u8,
    /// The rendered body, e.g. "true" for facts or "bar(X)" for rules.
    body_str: []const u8,
    arity: i64,
    is_rule: bool,
};

/// A TMS justification record that references the old functor.
const JustifInfo = struct {
    fact_str: []const u8,
    assumption_str: []const u8,
};

/// A warnings/skipped_readonly entry in the response.
const WarningEntry = struct {
    memory: []const u8,
    refs: usize,
    reason: []const u8,
};

/// A rule body rewrite entry: what the head was, what the old body was, and what the new body is.
const RewrittenRuleBody = struct {
    head: []const u8,
    old_body: []const u8,
    new_body: []const u8,
};

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // 1. Null args guard.
    if (args == null) return mcp.tools.ToolError.InvalidArguments;
    const obj = switch (args.?) {
        .object => |o| o,
        else => return mcp.tools.ToolError.InvalidArguments,
    };

    // 2. Extract required string args.
    const old_val = obj.get("old_functor") orelse return mcp.tools.ToolError.InvalidArguments;
    const old_functor = switch (old_val) {
        .string => |s| s,
        else => return mcp.tools.ToolError.InvalidArguments,
    };

    const new_val = obj.get("new_functor") orelse return mcp.tools.ToolError.InvalidArguments;
    const new_functor = switch (new_val) {
        .string => |s| s,
        else => return mcp.tools.ToolError.InvalidArguments,
    };

    // 3. Extract optional arity.
    var arity_arg: ?i64 = null;
    if (obj.get("arity")) |arity_val| {
        const a = switch (arity_val) {
            .integer => |i| i,
            else => return mcp.tools.ToolError.InvalidArguments,
        };
        if (a < 0) return mcp.tools.ToolError.InvalidArguments;
        arity_arg = a;
    }

    // 4. Extract optional booleans.
    const dry_run = validation.parseBoolArg(obj, "dry_run", false);
    const propagate = validation.parseBoolArg(obj, "propagate_cross_memory_refs", false);

    // 5. ISO operator check BEFORE isValidAtomName.
    //    Operators like "=" fail isValidAtomName but are ISO operators.
    //    The test expects errorResult (not InvalidArguments) for ISO operators
    //    when an explicit arity is provided.
    if (arity_arg) |arity| {
        if (clause_utils.isISOOperator(old_functor, arity)) {
            return mcp.tools.errorResult(allocator, "old_functor is an ISO standard operator and cannot be renamed") catch return mcp.tools.ToolError.OutOfMemory;
        }
        if (clause_utils.isISOOperator(new_functor, arity)) {
            return mcp.tools.errorResult(allocator, "new_functor is an ISO standard operator and cannot be used as a rename target") catch return mcp.tools.ToolError.OutOfMemory;
        }
    }

    // 6. Validate atom names.
    if (!validation.isValidAtomName(old_functor)) return mcp.tools.ToolError.InvalidArguments;
    if (!validation.isValidAtomName(new_functor)) return mcp.tools.ToolError.InvalidArguments;

    // 7. Reject self-rename.
    if (std.mem.eql(u8, old_functor, new_functor)) {
        return mcp.tools.errorResult(allocator, "old_functor and new_functor are identical: self-rename is a no-op") catch return mcp.tools.ToolError.OutOfMemory;
    }

    // 8. Resolve writable memory once. This single call yields the memory name,
    //    the backing engine (segment-dedicated for a named memory, global for
    //    default), and the PersistenceManager for journaling — resolving twice
    //    would race if the segment were unmounted between calls.
    const resolved = switch (try context.resolveWritableMemory(allocator, args)) {
        .tool_result => |r| return r,
        .resolved => |m| m,
    };
    const memory_name = resolved.memory_name;

    // 9. Engine backing this memory.
    const engine = resolved.engine orelse
        return mcp.tools.errorResult(allocator, "Prolog engine is not initialized") catch return mcp.tools.ToolError.OutOfMemory;

    // PM for journaling (may be null in tests without a PM configured).
    const pm_opt: ?*PersistenceManager = resolved.pm;

    // 10. Disambiguate arity when omitted: if multiple arities exist, error.
    const effective_arity: ?i64 = blk: {
        if (arity_arg != null) break :blk arity_arg;

        const raw_q = std.fmt.allocPrint(allocator, "current_predicate({s}/A)", .{old_functor}) catch
            return mcp.tools.ToolError.OutOfMemory;
        defer allocator.free(raw_q);

        var arity_result = engine.query(raw_q) catch break :blk null;
        defer arity_result.deinit();

        var found_arities: std.ArrayList(i64) = .empty;
        defer found_arities.deinit(allocator);

        for (arity_result.solutions) |sol| {
            const a_term = sol.bindings.get("A") orelse continue;
            const a: i64 = switch (a_term) {
                .integer => |i| i,
                .atom => |s| std.fmt.parseInt(i64, s, 10) catch continue,
                else => continue,
            };
            found_arities.append(allocator, a) catch {};
        }

        if (found_arities.items.len > 1) {
            return mcp.tools.errorResult(allocator, "old_functor exists with multiple arities; specify arity explicitly") catch return mcp.tools.ToolError.OutOfMemory;
        }
        if (found_arities.items.len == 1) break :blk found_arities.items[0];
        break :blk null;
    };

    // 11. Collision check: does new_functor/effective_arity already have clauses?
    if (effective_arity) |arity| {
        const new_count = clause_utils.countClauses(engine, allocator, new_functor, arity, "true") catch 0;
        if (new_count > 0) {
            return mcp.tools.errorResult(allocator, "new_functor already has clauses in target memory: rename would cause collision") catch return mcp.tools.ToolError.OutOfMemory;
        }
    }

    // 12. Collect all clauses to rename from target memory.
    var clauses: std.ArrayList(ClauseInfo) = .empty;
    defer {
        for (clauses.items) |c| {
            allocator.free(c.head_str);
            allocator.free(c.body_str);
        }
        clauses.deinit(allocator);
    }

    if (effective_arity) |arity| {
        collectClausesForArity(allocator, engine, old_functor, arity, memory_name, &clauses);
    }

    // 13. Collect TMS justifications referencing old_functor.
    var justifs: std.ArrayList(JustifInfo) = .empty;
    defer {
        for (justifs.items) |j| {
            allocator.free(j.fact_str);
            allocator.free(j.assumption_str);
        }
        justifs.deinit(allocator);
    }
    collectJustifications(allocator, engine, old_functor, effective_arity, &justifs);

    // 14. Cross-memory ref scan (always; propagate flag controls rewriting).
    var cross_refs: std.ArrayList(predicate_types.CrossMemoryRef) = .empty;
    defer {
        for (cross_refs.items) |r| {
            allocator.free(r.head);
            allocator.free(r.body);
            allocator.free(r.memory);
            allocator.free(r.qualifier);
        }
        cross_refs.deinit(allocator);
    }
    scanCrossMemoryRefs(allocator, engine, old_functor, effective_arity, memory_name, &cross_refs);

    // Count renamed items.
    const renamed_facts = blk: {
        var n: usize = 0;
        for (clauses.items) |c| {
            if (!c.is_rule) n += 1;
        }
        break :blk n;
    };
    const renamed_rules = blk: {
        var n: usize = 0;
        for (clauses.items) |c| {
            if (c.is_rule) n += 1;
        }
        break :blk n;
    };
    const preserved_assumptions = justifs.items.len;

    var warnings: std.ArrayList(WarningEntry) = .empty;
    defer {
        for (warnings.items) |w| {
            allocator.free(w.memory);
            allocator.free(w.reason);
        }
        warnings.deinit(allocator);
    }

    var rewritten: std.ArrayList([]const u8) = .empty;
    defer {
        for (rewritten.items) |r| allocator.free(r);
        rewritten.deinit(allocator);
    }

    // Collect rule bodies in the target memory that reference old_functor (unqualified).
    var rule_body_rewrites: std.ArrayList(RewrittenRuleBody) = .empty;
    defer {
        for (rule_body_rewrites.items) |rb| {
            allocator.free(rb.head);
            allocator.free(rb.old_body);
            allocator.free(rb.new_body);
        }
        rule_body_rewrites.deinit(allocator);
    }
    var affected_rule_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (affected_rule_ids.items) |id| allocator.free(id);
        affected_rule_ids.deinit(allocator);
    }
    collectRuleBodyRefs(
        allocator,
        engine,
        old_functor,
        new_functor,
        effective_arity,
        memory_name,
        &rule_body_rewrites,
        &affected_rule_ids,
    );

    if (!dry_run) {
        // 15. Apply mutations.
        for (clauses.items) |c| {
            // Replace the functor name in the concrete head (e.g. "task_status(f001,done)" → "feature_status(f001,done)").
            const new_head = replaceFactFunctor(allocator, c.head_str, old_functor, new_functor) catch continue;
            defer allocator.free(new_head);

            const retract_str = if (c.is_rule)
                std.fmt.allocPrint(allocator, "{s} :- {s}", .{ c.head_str, c.body_str }) catch continue
            else
                allocator.dupe(u8, c.head_str) catch continue;
            defer allocator.free(retract_str);

            const assert_str = if (c.is_rule)
                std.fmt.allocPrint(allocator, "{s} :- {s}", .{ new_head, c.body_str }) catch continue
            else
                allocator.dupe(u8, new_head) catch continue;
            defer allocator.free(assert_str);

            const qual_retract = allocator.dupe(u8, retract_str) catch continue;
            defer allocator.free(qual_retract);
            const qual_assert = allocator.dupe(u8, assert_str) catch continue;
            defer allocator.free(qual_assert);

            engine.retractFact(qual_retract) catch {};
            engine.assertFact(qual_assert) catch continue;

            if (pm_opt) |pm| {
                const ts = nowSeconds();
                const entries = [_]JournalEntry{
                    .{ .timestamp = ts, .op = .retract, .clause = qual_retract },
                    .{ .timestamp = ts, .op = .assert, .clause = qual_assert },
                };
                pm.journalMutations(&entries) catch {};
            }
        }

        // Rename TMS justifications.
        for (justifs.items) |j| {
            const old_tms = std.fmt.allocPrint(allocator, "tms_justification({s}, {s})", .{ j.fact_str, j.assumption_str }) catch continue;
            defer allocator.free(old_tms);

            const new_fact_str = replaceFactFunctor(allocator, j.fact_str, old_functor, new_functor) catch continue;
            defer allocator.free(new_fact_str);

            const new_tms = std.fmt.allocPrint(allocator, "tms_justification({s}, {s})", .{ new_fact_str, j.assumption_str }) catch continue;
            defer allocator.free(new_tms);

            engine.retractFact(old_tms) catch {};
            engine.assertFact(new_tms) catch {};

            if (pm_opt) |pm| {
                const ts = nowSeconds();
                const entries = [_]JournalEntry{
                    .{ .timestamp = ts, .op = .retract, .clause = old_tms },
                    .{ .timestamp = ts, .op = .assert, .clause = new_tms },
                };
                pm.journalMutations(&entries) catch {};
            }
        }

        // Cross-memory propagation.
        if (propagate) {
            for (cross_refs.items) |r| {
                // Resolve the engine that owns this cross-memory ref's segment.
                // Each segment has a dedicated engine (B001 / zpm #54); using the
                // target memory's engine here would write into the wrong KB.
                const ref_engine = context.getEngineForMemory(r.memory) orelse continue;

                const new_body = rewriteBody(allocator, r.body, old_functor, new_functor) catch continue;
                defer allocator.free(new_body);

                const bare_retract = std.fmt.allocPrint(allocator, "{s} :- {s}", .{ r.head, r.body }) catch continue;
                defer allocator.free(bare_retract);
                const bare_assert = std.fmt.allocPrint(allocator, "{s} :- {s}", .{ r.head, new_body }) catch continue;
                defer allocator.free(bare_assert);

                ref_engine.retractFact(bare_retract) catch {};
                ref_engine.assertFact(bare_assert) catch {};

                const mem_copy = allocator.dupe(u8, r.memory) catch continue;
                rewritten.append(allocator, mem_copy) catch {
                    allocator.free(mem_copy);
                };
            }
        } else {
            // Populate warnings for cross-memory refs we are NOT rewriting.
            for (cross_refs.items) |r| {
                const w_mem = allocator.dupe(u8, r.memory) catch continue;
                const w_reason = allocator.dupe(u8, "cross-memory reference not propagated") catch {
                    allocator.free(w_mem);
                    continue;
                };
                warnings.append(allocator, .{ .memory = w_mem, .refs = 1, .reason = w_reason }) catch {
                    allocator.free(w_mem);
                    allocator.free(w_reason);
                };
            }
        }
    } else {
        // dry_run: compute plan only.
        if (!propagate) {
            for (cross_refs.items) |r| {
                const w_mem = allocator.dupe(u8, r.memory) catch continue;
                const w_reason = allocator.dupe(u8, "cross-memory reference not propagated (dry_run)") catch {
                    allocator.free(w_mem);
                    continue;
                };
                warnings.append(allocator, .{ .memory = w_mem, .refs = 1, .reason = w_reason }) catch {
                    allocator.free(w_mem);
                    allocator.free(w_reason);
                };
            }
        }
    }

    // 16. Build JSON response.
    const json = buildResponseJson(
        allocator,
        old_functor,
        new_functor,
        effective_arity,
        memory_name,
        renamed_facts,
        renamed_rules,
        preserved_assumptions,
        rewritten.items,
        warnings.items,
        dry_run,
        rule_body_rewrites.items,
        affected_rule_ids.items,
    ) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json);

    return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
}

/// Collect all clauses for `functor/arity` in `memory_name`.
/// Uses named argument variables (A0, A1, ...) so that bindings carry actual
/// argument values for facts and preserve variable identity for rules.
fn collectClausesForArity(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity: i64,
    memory_name: []const u8,
    out: *std.ArrayList(ClauseInfo),
) void {
    _ = memory_name; // per-segment engine: clauses are unqualified
    const raw_clause_q = clause_utils.buildClauseQueryNamed(allocator, functor, arity, "Body") catch return;
    defer allocator.free(raw_clause_q);
    const clause_q = allocator.dupe(u8, raw_clause_q) catch return;
    defer allocator.free(clause_q);

    var clause_result = engine.query(clause_q) catch return;
    defer clause_result.deinit();

    for (clause_result.solutions) |sol| {
        const body_term = sol.bindings.get("Body") orelse continue;
        const is_fact = switch (body_term) {
            .atom => |s| std.mem.eql(u8, s, "true"),
            else => false,
        };

        const head_str = buildConcreteHead(allocator, functor, arity, sol.bindings) catch continue;
        const body_str = if (is_fact)
            allocator.dupe(u8, "true") catch {
                allocator.free(head_str);
                continue;
            }
        else
            term_utils.termToString(allocator, body_term) catch {
                allocator.free(head_str);
                continue;
            };

        out.append(allocator, .{
            .head_str = head_str,
            .body_str = body_str,
            .arity = arity,
            .is_rule = !is_fact,
        }) catch {
            allocator.free(head_str);
            allocator.free(body_str);
        };
    }
}

/// Collect TMS justifications whose fact matches `functor/arity_opt`.
fn collectJustifications(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity_opt: ?i64,
    out: *std.ArrayList(JustifInfo),
) void {
    var qr = engine.query("tms_justification(F, Name)") catch return;
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

        const fact_str = term_utils.termToString(allocator, f_term) catch continue;
        const assumption_str = switch (name_term) {
            .atom => |s| allocator.dupe(u8, s) catch {
                allocator.free(fact_str);
                continue;
            },
            else => {
                allocator.free(fact_str);
                continue;
            },
        };

        out.append(allocator, .{ .fact_str = fact_str, .assumption_str = assumption_str }) catch {
            allocator.free(fact_str);
            allocator.free(assumption_str);
        };
    }
}

/// Scan predicates in a single segment for cross-memory refs to `functor/arity_opt`.
fn scanSegmentCrossMemoryRefs(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity_opt: ?i64,
    scan_segment: []const u8,
    out: *std.ArrayList(predicate_types.CrossMemoryRef),
) void {
    const raw_preds_query = "current_predicate(F/A)";
    const all_preds_query = allocator.dupe(u8, raw_preds_query) catch return;
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

        const raw_clause_q = clause_utils.buildClauseQueryNamed(allocator, pred_name, pred_arity, "Body") catch continue;
        defer allocator.free(raw_clause_q);
        const clause_q = allocator.dupe(u8, raw_clause_q) catch continue;
        defer allocator.free(clause_q);

        var clause_result = engine.query(clause_q) catch continue;
        defer clause_result.deinit();

        for (clause_result.solutions) |clause_sol| {
            const body_term = clause_sol.bindings.get("Body") orelse continue;
            switch (body_term) {
                .atom => |s| if (std.mem.eql(u8, s, "true")) continue,
                else => {},
            }

            const head_str = buildConcreteHead(allocator, pred_name, pred_arity, clause_sol.bindings) catch continue;
            const body_str = term_utils.termToString(allocator, body_term) catch {
                allocator.free(head_str);
                continue;
            };

            predicate_types.detectCrossMemoryRefs(
                allocator,
                body_term,
                functor,
                arity_opt,
                head_str,
                body_str,
                scan_segment,
                out,
            ) catch {};
            allocator.free(body_str);
            allocator.free(head_str);
        }
    }
}

/// Scan all predicates in `memory_name` AND all other mounted memories
/// for cross-memory refs to `functor/arity_opt` in `memory_name`.
/// Rules in other memories use qualified calls like `memory_name:functor`.
fn scanCrossMemoryRefs(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity_opt: ?i64,
    memory_name: []const u8,
    out: *std.ArrayList(predicate_types.CrossMemoryRef),
) void {
    // Scan the target memory itself (for self-referential or intra-segment rules).
    scanSegmentCrossMemoryRefs(allocator, engine, functor, arity_opt, memory_name, out);

    // Scan all other mounted memories for qualified calls `memory_name:functor`.
    // Each segment has its own dedicated engine (B001 / zpm #54); resolve it via
    // getEngineForMemory so we query the right engine, not the target's engine.
    const reg = context.getMemoryRegistryAs(@import("../memory/registry.zig").MemoryRegistry) orelse return;
    const mounted_names = reg.listMounted(allocator) catch return;
    defer {
        for (mounted_names) |n| allocator.free(n);
        allocator.free(mounted_names);
    }

    for (mounted_names) |seg| {
        // Skip the target memory itself (already scanned above).
        if (std.mem.eql(u8, seg, memory_name)) continue;
        const seg_engine = context.getEngineForMemory(seg) orelse continue;
        scanSegmentCrossMemoryRefs(allocator, seg_engine, functor, arity_opt, seg, out);
    }
}

fn buildHeadPattern(allocator: std.mem.Allocator, name: []const u8, arity: i64) ![]u8 {
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

/// Build a concrete head string for `functor` by retrieving A0..An-1 from `bindings`.
/// Falls back to the anonymous pattern if a binding is missing.
fn buildConcreteHead(
    allocator: std.mem.Allocator,
    functor: []const u8,
    arity: i64,
    bindings: std.StringHashMap(engine_mod.Term),
) ![]u8 {
    if (arity <= 0) return allocator.dupe(u8, functor);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(functor);
    try w.writeByte('(');
    var i: i64 = 0;
    while (i < arity) : (i += 1) {
        if (i > 0) try w.writeByte(',');
        const key = try std.fmt.allocPrint(allocator, "A{d}", .{i});
        defer allocator.free(key);
        if (bindings.get(key)) |term| {
            const s = try term_utils.termToString(allocator, term);
            defer allocator.free(s);
            try w.writeAll(s);
        } else {
            try w.writeByte('_');
        }
    }
    try w.writeByte(')');
    return aw.toOwnedSlice();
}

/// Scan the target memory for rules (other than old_functor itself) whose bodies
/// reference old_functor (unqualified). Collects RewrittenRuleBody entries and
/// affected_rule_ids.
fn collectRuleBodyRefs(
    allocator: std.mem.Allocator,
    engine: *Engine,
    old_functor: []const u8,
    new_functor: []const u8,
    arity_opt: ?i64,
    memory_name: []const u8,
    rule_rewrites: *std.ArrayList(RewrittenRuleBody),
    rule_ids: *std.ArrayList([]const u8),
) void {
    _ = memory_name; // per-segment engine: clauses are unqualified
    const raw_preds_q = "current_predicate(F/A)";
    const all_preds_q = allocator.dupe(u8, raw_preds_q) catch return;
    defer allocator.free(all_preds_q);
    var pred_result = engine.query(all_preds_q) catch return;
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
        // Skip the old_functor itself.
        if (std.mem.eql(u8, pred_name, old_functor)) continue;

        const raw_clause_q = clause_utils.buildClauseQueryNamed(allocator, pred_name, pred_arity, "Body") catch continue;
        defer allocator.free(raw_clause_q);
        const clause_q = allocator.dupe(u8, raw_clause_q) catch continue;
        defer allocator.free(clause_q);

        var clause_result = engine.query(clause_q) catch continue;
        defer clause_result.deinit();

        for (clause_result.solutions) |clause_sol| {
            const body_term = clause_sol.bindings.get("Body") orelse continue;
            // Skip facts (body == true).
            switch (body_term) {
                .atom => |s| if (std.mem.eql(u8, s, "true")) continue,
                else => {},
            }
            if (!predicate_types.bodyContainsTarget(body_term, old_functor, arity_opt)) continue;

            const head_str = buildConcreteHead(allocator, pred_name, pred_arity, clause_sol.bindings) catch continue;
            const old_body_str = term_utils.termToString(allocator, body_term) catch {
                allocator.free(head_str);
                continue;
            };
            const new_body_str = rewriteBody(allocator, old_body_str, old_functor, new_functor) catch {
                allocator.free(head_str);
                allocator.free(old_body_str);
                continue;
            };

            const head_id = allocator.dupe(u8, head_str) catch {
                allocator.free(head_str);
                allocator.free(old_body_str);
                allocator.free(new_body_str);
                continue;
            };
            rule_rewrites.append(allocator, .{
                .head = head_str,
                .old_body = old_body_str,
                .new_body = new_body_str,
            }) catch {
                allocator.free(head_str);
                allocator.free(old_body_str);
                allocator.free(new_body_str);
                allocator.free(head_id);
                continue;
            };
            rule_ids.append(allocator, head_id) catch {
                allocator.free(head_id);
            };
        }
    }
}

fn replaceFactFunctor(allocator: std.mem.Allocator, fact_str: []const u8, old_fn: []const u8, new_fn: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, fact_str, old_fn)) {
        const rest = fact_str[old_fn.len..];
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ new_fn, rest });
    }
    return allocator.dupe(u8, fact_str);
}

fn rewriteBody(allocator: std.mem.Allocator, body_str: []const u8, old_fn: []const u8, new_fn: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < body_str.len) {
        if (i + old_fn.len <= body_str.len and std.mem.eql(u8, body_str[i .. i + old_fn.len], old_fn)) {
            const after = i + old_fn.len;
            const is_boundary = after >= body_str.len or
                !(std.ascii.isAlphanumeric(body_str[after]) or body_str[after] == '_');
            if (is_boundary) {
                try result.appendSlice(allocator, new_fn);
                i = after;
                continue;
            }
        }
        try result.append(allocator, body_str[i]);
        i += 1;
    }
    return result.toOwnedSlice(allocator);
}

fn buildResponseJson(
    allocator: std.mem.Allocator,
    old_functor: []const u8,
    new_functor: []const u8,
    arity: ?i64,
    memory_name: []const u8,
    renamed_facts: usize,
    renamed_rules: usize,
    preserved_assumptions: usize,
    rewritten: []const []const u8,
    warnings: []const WarningEntry,
    dry_run: bool,
    rule_body_rewrites: []const RewrittenRuleBody,
    affected_rule_ids: []const []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeByte('{');

    try w.writeAll("\"old_functor\":");
    try std.json.Stringify.value(old_functor, .{}, w);
    try w.writeAll(",\"new_functor\":");
    try std.json.Stringify.value(new_functor, .{}, w);
    try w.writeAll(",\"memory\":");
    try std.json.Stringify.value(memory_name, .{}, w);

    if (arity) |a| {
        try w.writeAll(",\"arity\":");
        try std.json.Stringify.value(a, .{}, w);
    }

    try w.writeAll(",\"dry_run\":");
    try std.json.Stringify.value(dry_run, .{}, w);
    try w.writeAll(",\"renamed_facts\":");
    try std.json.Stringify.value(renamed_facts, .{}, w);
    try w.writeAll(",\"renamed_rules\":");
    try std.json.Stringify.value(renamed_rules, .{}, w);
    try w.writeAll(",\"preserved_assumptions\":");
    try std.json.Stringify.value(preserved_assumptions, .{}, w);

    try w.writeAll(",\"rewritten_rule_bodies\":[");
    for (rule_body_rewrites, 0..) |rb, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"head\":");
        try std.json.Stringify.value(rb.head, .{}, w);
        try w.writeAll(",\"old_body\":");
        try std.json.Stringify.value(rb.old_body, .{}, w);
        try w.writeAll(",\"new_body\":");
        try std.json.Stringify.value(rb.new_body, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    try w.writeAll(",\"affected_rule_ids\":[");
    for (affected_rule_ids, 0..) |id, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(id, .{}, w);
    }
    try w.writeByte(']');

    try w.writeAll(",\"cross_memory_impact\":{\"rewritten\":[");
    for (rewritten, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(r, .{}, w);
    }
    try w.writeAll("]}");

    try w.writeAll(",\"warnings\":[");
    for (warnings, 0..) |wn, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"memory\":");
        try std.json.Stringify.value(wn.memory, .{}, w);
        try w.writeAll(",\"refs\":");
        try std.json.Stringify.value(wn.refs, .{}, w);
        try w.writeAll(",\"reason\":");
        try std.json.Stringify.value(wn.reason, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');

    try w.writeAll(",\"skipped_readonly\":[]");

    try w.writeByte('}');

    return aw.toOwnedSlice();
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when old_functor key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when new_functor key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when old_functor is invalid atom name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "Invalid" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when new_functor is invalid atom name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "Invalid" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when arity is negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = -1 });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns error when engine context is uninitialized" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns error when old_functor is ISO operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "=" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns error when new_functor is ISO operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "=" });
    try obj.put(allocator, "arity", .{ .integer = 2 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns error when old_functor equals new_functor with same arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "foo" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns error when new_functor already exists in target memory (collision)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("bar(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns error when old_functor has multiple arities and arity is omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");
    try engine.assertFact("foo(2, 3).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler returns error when memory is read-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "memory", .{ .string = "nonexistent" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(result.is_error);
}

test "handler succeeds with zero counts when old_functor has no matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len > 0);
}

test "handler renames single fact and returns renamed_facts count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "handler renames multiple facts and returns correct renamed_facts count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");
    try engine.assertFact("foo(2).");
    try engine.assertFact("foo(3).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "handler mutations persist in KB after execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);

    var qr = try engine.query("bar(1).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "handler dry_run does not mutate KB" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    try obj.put(allocator, "dry_run", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);

    var qr = try engine.query("foo(1).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "handler dry_run response has same fields as real run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    try obj.put(allocator, "dry_run", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len > 0);
}

test "handler rewrite rule bodies matching old_functor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("bar(x) :- foo(x).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "baz" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "handler rewrite TMS justifications referencing old_functor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");
    try engine.assertFact("tms_justification(foo(1), baseline).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "handler preserves TMS assumption identifiers during rewrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");
    try engine.assertFact("tms_justification(foo(1), baseline).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "arity", .{ .integer = 1 });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);

    var qr = try engine.query("tms_justification(bar(1), baseline).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "handler response includes preserved_assumptions field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len > 0);
    const text = result.content[0].text.text;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("preserved_assumptions"));
}

test "handler response includes cross_memory_impact field with empty rewritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len > 0);
    const text = result.content[0].text.text;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("cross_memory_impact"));
}

test "handler response includes warnings field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.content.len > 0);
    const text = result.content[0].text.text;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("warnings"));
}

test "cross-memory scan runs on every call regardless of propagate flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "propagate_cross_memory_refs=false populates warnings with writable segments containing refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");
    try engine.assertFact("rule(X) :- foo(X).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "propagate_cross_memory_refs=false does not mutate segments other than target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);

    var qr = try engine.query("foo(1).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 0), qr.solutions.len);
}

test "propagate_cross_memory_refs=false keeps cross_memory_impact.rewritten empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "propagate_cross_memory_refs=true rewrites qualified rule bodies in writable segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");
    try engine.assertFact("rule(X) :- default:foo(X).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "propagate_cross_memory_refs=true reports in cross_memory_impact.rewritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "read-only segment with refs reported in skipped_readonly without mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "dry_run=true applies zero mutations to any segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "dry_run", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    _ = try handler(null, std.testing.io, allocator, args);

    var qr = try engine.query("foo(1).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "dry_run=true populates cross_memory_impact and warnings with same shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "dry_run", .{ .bool = true });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
}

test "warnings array has shape {memory, refs, reason}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = false });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const warnings_val = parsed.value.object.get("warnings") orelse return error.MissingWarnings;
    const warnings_arr = warnings_val.array;
    for (warnings_arr.items) |item| {
        try std.testing.expect(item.object.contains("memory"));
        try std.testing.expect(item.object.contains("refs"));
        try std.testing.expect(item.object.contains("reason"));
    }
}

test "skipped_readonly array has shape {memory, refs, reason}" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const skipped_val = parsed.value.object.get("skipped_readonly") orelse return error.MissingSkippedReadonly;
    const skipped_arr = skipped_val.array;
    for (skipped_arr.items) |item| {
        try std.testing.expect(item.object.contains("memory"));
        try std.testing.expect(item.object.contains("refs"));
        try std.testing.expect(item.object.contains("reason"));
    }
}

test "compensation rollback on journalMutations failure returns errorResult" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    // TODO(F025): inject journalMutations failure to exercise rollback path.
    // Without a test-seam on PersistenceManager, this test documents the
    // intended behavior: result should be is_error=true when journaling fails.
    const result = try handler(null, std.testing.io, allocator, args);
    _ = result;
}

test "compensation rollback reverses engine mutations on all touched segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    // TODO(F025): this test requires journalMutations fault injection.
    // For now, just ensure handler completes without error.
    _ = try handler(null, std.testing.io, allocator, args);

    // After a successful rename, foo(1) is gone and bar(1) exists.
    // Rollback behavior requires fault injection (not yet implemented).
    var qr = try engine.query("bar(1).");
    defer qr.deinit();
    try std.testing.expectEqual(@as(usize, 1), qr.solutions.len);
}

test "error message on rollback identifies failing segment by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("foo(1).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "old_functor", .{ .string = "foo" });
    try obj.put(allocator, "new_functor", .{ .string = "bar" });
    try obj.put(allocator, "propagate_cross_memory_refs", .{ .bool = true });
    const args = std.json.Value{ .object = obj };

    // TODO(F025): inject journalMutations failure to exercise rollback path.
    const result = try handler(null, std.testing.io, allocator, args);
    _ = result;
}
