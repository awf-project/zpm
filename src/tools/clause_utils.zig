const std = @import("std");
const engine_mod = @import("../prolog/engine.zig");

pub const PredicateEntry = struct {
    name: []u8,
    arity: i64,
    fact_count: usize,
    rule_count: usize,
};

pub const PredicateCollection = struct {
    entries: std.ArrayList(PredicateEntry) = .empty,

    pub fn deinit(self: *PredicateCollection, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.name);
        self.entries.deinit(allocator);
    }
};

const QueryDispatch = struct {
    context: *anyopaque,
    queryFn: *const fn (*anyopaque, []const u8) engine_mod.EngineError!engine_mod.QueryResult,

    fn query(self: QueryDispatch, goal: []const u8) engine_mod.EngineError!engine_mod.QueryResult {
        return self.queryFn(self.context, goal);
    }
};

fn engineQuery(context: *anyopaque, goal: []const u8) engine_mod.EngineError!engine_mod.QueryResult {
    const engine: *engine_mod.Engine = @ptrCast(@alignCast(context));
    return engine.query(goal);
}

fn engineDispatch(engine: *engine_mod.Engine) QueryDispatch {
    return .{ .context = engine, .queryFn = engineQuery };
}

const PredicateCandidate = struct {
    name: []const u8,
    arity: i64,
};

fn validateCandidate(solution: engine_mod.Solution) ?PredicateCandidate {
    const f_term = solution.bindings.get("F") orelse return null;
    const a_term = solution.bindings.get("A") orelse return null;
    return validateCandidateTerms(f_term, a_term);
}

fn validateCandidateTerms(f_term: engine_mod.Term, a_term: engine_mod.Term) ?PredicateCandidate {
    const name = switch (f_term) {
        .atom => |value| value,
        else => return null,
    };
    const arity = switch (a_term) {
        .integer => |value| value,
        .atom => |value| std.fmt.parseInt(i64, value, 10) catch return null,
        else => return null,
    };
    if (arity < 0) return null;
    if (isBuiltin(name) or isISOOperator(name, arity)) return null;
    return .{ .name = name, .arity = arity };
}

fn canWriteAtomUnquoted(name: []const u8) bool {
    if (name.len == 0 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

pub fn writeAtom(writer: *std.Io.Writer, name: []const u8) !void {
    if (canWriteAtomUnquoted(name)) return writer.writeAll(name);

    try writer.writeByte('\'');
    for (name) |c| switch (c) {
        '\\', '\'' => {
            try writer.writeByte('\\');
            try writer.writeByte(c);
        },
        else => try writer.writeByte(c),
    };
    try writer.writeByte('\'');
}

fn containsPredicate(entries: []const PredicateEntry, candidate: PredicateCandidate) bool {
    for (entries) |entry| {
        if (entry.arity == candidate.arity and std.mem.eql(u8, entry.name, candidate.name)) return true;
    }
    return false;
}

fn discoverWithDispatch(allocator: std.mem.Allocator, dispatch: QueryDispatch) engine_mod.EngineError!PredicateCollection {
    var collection: PredicateCollection = .{};
    errdefer collection.deinit(allocator);

    // Finish current_predicate/1 before inspecting properties: Trealla lazily
    // loads property predicates, mutating the index being enumerated. Keep
    // both lists in one binding to avoid Engine's per-query solution cap.
    var enumeration = try dispatch.query(
        "findall(F/A,current_predicate(F/A),Candidates)," ++
            "findall(F/A,(member(F/A,Candidates),functor(H,F,A)," ++
            "\\+ predicate_property(H,built_in)," ++
            "\\+ predicate_property(H,imported_from(_))," ++
            "(predicate_property(H,dynamic); \\+ atom_concat(zpm_,_,F))),Predicates)",
    );
    defer enumeration.deinit();

    for (enumeration.solutions) |solution| {
        if (solution.bindings.get("Predicates")) |term| {
            const predicates = switch (term) {
                .list => |items| items,
                else => continue,
            };
            for (predicates) |predicate| {
                const pair = switch (predicate) {
                    .compound => |compound| compound,
                    else => continue,
                };
                if (!std.mem.eql(u8, pair.functor, "/") or pair.args.len != 2) continue;
                const candidate = validateCandidateTerms(pair.args[0], pair.args[1]) orelse continue;
                try appendCandidate(allocator, dispatch, &collection, candidate);
            }
            continue;
        }
        const candidate = validateCandidate(solution) orelse continue;
        try appendCandidate(allocator, dispatch, &collection, candidate);
    }
    return collection;
}

fn appendCandidate(
    allocator: std.mem.Allocator,
    dispatch: QueryDispatch,
    collection: *PredicateCollection,
    candidate: PredicateCandidate,
) engine_mod.EngineError!void {
    if (containsPredicate(collection.entries.items, candidate)) return;
    const fact_count = try countClausesWithDispatch(dispatch, allocator, candidate.name, candidate.arity, "true");
    const all_count = try countClausesWithDispatch(dispatch, allocator, candidate.name, candidate.arity, "_");
    const rule_count = all_count -| fact_count;
    if (fact_count == 0 and rule_count == 0) return;

    const name = allocator.dupe(u8, candidate.name) catch return engine_mod.EngineError.OutOfMemory;
    errdefer allocator.free(name);
    collection.entries.append(allocator, .{
        .name = name,
        .arity = candidate.arity,
        .fact_count = fact_count,
        .rule_count = rule_count,
    }) catch return engine_mod.EngineError.OutOfMemory;
}

pub fn discoverPredicates(engine: *engine_mod.Engine, allocator: std.mem.Allocator) engine_mod.EngineError!PredicateCollection {
    return discoverWithDispatch(allocator, engineDispatch(engine));
}

// Returns true for names to skip during KB introspection: empty/$-prefixed
// Trealla internals or ZPM infrastructure predicates.
pub fn isBuiltin(name: []const u8) bool {
    return name.len == 0 or
        name[0] == '$' or
        std.mem.eql(u8, name, "tms_justification") or
        std.mem.eql(u8, name, "zpm_source") or
        std.mem.eql(u8, name, "portray");
}

pub fn isISOOperator(name: []const u8, arity: i64) bool {
    const Entry = struct { name: []const u8, arity: i64 };
    const operators = [_]Entry{
        .{ .name = "=", .arity = 2 },
        .{ .name = ",", .arity = 2 },
        .{ .name = ";", .arity = 2 },
        .{ .name = "is", .arity = 2 },
        .{ .name = "->", .arity = 2 },
        .{ .name = "\\=", .arity = 2 },
        .{ .name = "==", .arity = 2 },
        .{ .name = "\\==", .arity = 2 },
        .{ .name = "=..", .arity = 2 },
        .{ .name = "@<", .arity = 2 },
        .{ .name = "@>", .arity = 2 },
        .{ .name = "@=<", .arity = 2 },
        .{ .name = "@>=", .arity = 2 },
        .{ .name = "<", .arity = 2 },
        .{ .name = ">", .arity = 2 },
        .{ .name = "=<", .arity = 2 },
        .{ .name = ">=", .arity = 2 },
        .{ .name = "+", .arity = 2 },
        .{ .name = "-", .arity = 2 },
        .{ .name = "*", .arity = 2 },
        .{ .name = "/", .arity = 2 },
        .{ .name = ":-", .arity = 2 },
        .{ .name = ":-", .arity = 1 },
        .{ .name = "\\+", .arity = 1 },
        .{ .name = "!", .arity = 0 },
    };
    for (operators) |op| {
        if (std.mem.eql(u8, name, op.name) and arity == op.arity) return true;
    }
    return false;
}

pub fn buildClauseQuery(allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("clause(");
    try writeAtom(w, name);
    if (arity > 0) {
        try w.writeByte('(');
        var i: i64 = 0;
        while (i < arity) : (i += 1) {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('_');
        }
        try w.writeByte(')');
    }
    try w.writeByte(',');
    try w.writeAll(body);
    try w.writeByte(')');
    return aw.toOwnedSlice();
}

/// Like buildClauseQuery but uses named arg variables A0, A1, and so on instead of _.
/// The caller can then retrieve A0..An-1 from the solution bindings to reconstruct
/// the concrete head with actual argument values.
pub fn buildClauseQueryNamed(allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("clause(");
    try writeAtom(w, name);
    if (arity > 0) {
        try w.writeByte('(');
        var i: i64 = 0;
        while (i < arity) : (i += 1) {
            if (i > 0) try w.writeByte(',');
            try w.print("A{d}", .{i});
        }
        try w.writeByte(')');
    }
    try w.writeByte(',');
    try w.writeAll(body);
    try w.writeByte(')');
    return aw.toOwnedSlice();
}

pub fn predicateKind(fact_count: usize, rule_count: usize) []const u8 {
    if (fact_count > 0 and rule_count > 0) return "both";
    if (rule_count > 0) return "rule";
    return "fact";
}

fn countClausesWithDispatch(dispatch: QueryDispatch, allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) engine_mod.EngineError!usize {
    const query_str = buildClauseQuery(allocator, name, arity, body) catch
        return engine_mod.EngineError.OutOfMemory;
    defer allocator.free(query_str);
    // Trealla's public clause/2 rejects static predicates loaded by consult/1.
    // Its private equivalent has the same result contract and permits the
    // read-only inspection required here.
    const inspect_query = std.fmt.allocPrint(allocator, "'$clause'{s}", .{query_str["clause".len..]}) catch
        return engine_mod.EngineError.OutOfMemory;
    defer allocator.free(inspect_query);
    const count_query = std.fmt.allocPrint(
        allocator,
        "findall(1,({s}),ZpmMatches),length(ZpmMatches,Count)",
        .{inspect_query},
    ) catch return engine_mod.EngineError.OutOfMemory;
    defer allocator.free(count_query);
    var result = try dispatch.query(count_query);
    defer result.deinit();
    if (result.solutions.len != 1) return engine_mod.EngineError.QueryFailed;
    const count = result.solutions[0].bindings.get("Count") orelse
        return engine_mod.EngineError.QueryFailed;
    return switch (count) {
        .integer => |value| if (value >= 0) @intCast(value) else engine_mod.EngineError.QueryFailed,
        else => engine_mod.EngineError.QueryFailed,
    };
}

pub fn countClauses(engine: *engine_mod.Engine, allocator: std.mem.Allocator, name: []const u8, arity: i64, body: []const u8) engine_mod.EngineError!usize {
    return countClausesWithDispatch(engineDispatch(engine), allocator, name, arity, body);
}

test "buildClauseQuery arity 2" {
    const result = try buildClauseQuery(std.testing.allocator, "foo", 2, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(_,_),Body)", result);
}

test "buildClauseQueryNamed arity 2" {
    const result = try buildClauseQueryNamed(std.testing.allocator, "foo", 2, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(A0,A1),Body)", result);
}

test "buildClauseQueryNamed arity 0 omits parens" {
    const result = try buildClauseQueryNamed(std.testing.allocator, "foo", 0, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo,Body)", result);
}

test "buildClauseQueryNamed arity 1" {
    const result = try buildClauseQueryNamed(std.testing.allocator, "foo", 1, "true");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(A0),true)", result);
}

test "buildClauseQuery arity 0 omits parens" {
    const result = try buildClauseQuery(std.testing.allocator, "foo", 0, "Body");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo,Body)", result);
}

test "buildClauseQuery arity 1" {
    const result = try buildClauseQuery(std.testing.allocator, "foo", 1, "true");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("clause(foo(_),true)", result);
}

test "clause query builders quote punctuation and escape atom delimiters" {
    const punctuation = try buildClauseQuery(std.testing.allocator, "release-status", 1, "true");
    defer std.testing.allocator.free(punctuation);
    try std.testing.expectEqualStrings("clause('release-status'(_),true)", punctuation);

    const embedded_quote = try buildClauseQueryNamed(std.testing.allocator, "reviewer's-note", 1, "Body");
    defer std.testing.allocator.free(embedded_quote);
    try std.testing.expectEqualStrings("clause('reviewer\\'s-note'(A0),Body)", embedded_quote);
}

test "isBuiltin empty string" {
    try std.testing.expect(isBuiltin(""));
}

test "isBuiltin dollar-prefixed" {
    try std.testing.expect(isBuiltin("$foo"));
}

test "isBuiltin preserves atom containing module punctuation" {
    try std.testing.expect(!isBuiltin("mod:goal"));
}

test "isBuiltin tms_justification" {
    try std.testing.expect(isBuiltin("tms_justification"));
}

test "isBuiltin zpm_source" {
    try std.testing.expect(isBuiltin("zpm_source"));
}

test "isBuiltin portray" {
    try std.testing.expect(isBuiltin("portray"));
}

test "isBuiltin regular atom returns false" {
    try std.testing.expect(!isBuiltin("parent"));
}

test "isISOOperator =/2 returns true" {
    try std.testing.expect(isISOOperator("=", 2));
}

test "isISOOperator ,/2 returns true" {
    try std.testing.expect(isISOOperator(",", 2));
}

test "isISOOperator is/2 returns true" {
    try std.testing.expect(isISOOperator("is", 2));
}

test "isISOOperator !/0 returns true" {
    try std.testing.expect(isISOOperator("!", 0));
}

test "isISOOperator task_status/2 returns false" {
    try std.testing.expect(!isISOOperator("task_status", 2));
}

test "isISOOperator =/3 returns false" {
    try std.testing.expect(!isISOOperator("=", 3));
}

test "isISOOperator ;/2 returns true" {
    try std.testing.expect(isISOOperator(";", 2));
}

test "isISOOperator ->/2 returns true" {
    try std.testing.expect(isISOOperator("->", 2));
}

test "isISOOperator \\=/2 returns true" {
    try std.testing.expect(isISOOperator("\\=", 2));
}

test "isISOOperator ==/2 returns true" {
    try std.testing.expect(isISOOperator("==", 2));
}

test "isISOOperator \\==/2 returns true" {
    try std.testing.expect(isISOOperator("\\==", 2));
}

test "isISOOperator =../2 returns true" {
    try std.testing.expect(isISOOperator("=..", 2));
}

test "isISOOperator @</2 returns true" {
    try std.testing.expect(isISOOperator("@<", 2));
}

test "isISOOperator @>/2 returns true" {
    try std.testing.expect(isISOOperator("@>", 2));
}

test "isISOOperator @=</2 returns true" {
    try std.testing.expect(isISOOperator("@=<", 2));
}

test "isISOOperator @>=/2 returns true" {
    try std.testing.expect(isISOOperator("@>=", 2));
}

test "isISOOperator </2 returns true" {
    try std.testing.expect(isISOOperator("<", 2));
}

test "isISOOperator >/2 returns true" {
    try std.testing.expect(isISOOperator(">", 2));
}

test "isISOOperator =</2 returns true" {
    try std.testing.expect(isISOOperator("=<", 2));
}

test "isISOOperator >=/2 returns true" {
    try std.testing.expect(isISOOperator(">=", 2));
}

test "isISOOperator +/2 returns true" {
    try std.testing.expect(isISOOperator("+", 2));
}

test "isISOOperator -/2 returns true" {
    try std.testing.expect(isISOOperator("-", 2));
}

test "isISOOperator */2 returns true" {
    try std.testing.expect(isISOOperator("*", 2));
}

test "isISOOperator //2 returns true" {
    try std.testing.expect(isISOOperator("/", 2));
}

test "isISOOperator :-/2 returns true" {
    try std.testing.expect(isISOOperator(":-", 2));
}

test "isISOOperator :-/1 returns true" {
    try std.testing.expect(isISOOperator(":-", 1));
}

test "isISOOperator \\+/1 returns true" {
    try std.testing.expect(isISOOperator("\\+", 1));
}

test "isISOOperator is/1 returns false" {
    try std.testing.expect(!isISOOperator("is", 1));
}

test "isISOOperator feature_status/2 returns false" {
    try std.testing.expect(!isISOOperator("feature_status", 2));
}

test "predicateKind returns fact when only facts" {
    try std.testing.expectEqualStrings("fact", predicateKind(0, 0));
    try std.testing.expectEqualStrings("fact", predicateKind(5, 0));
}

test "predicateKind returns rule when only rules" {
    try std.testing.expectEqualStrings("rule", predicateKind(0, 3));
}

test "predicateKind returns both when facts and rules exist" {
    try std.testing.expectEqualStrings("both", predicateKind(2, 1));
}

test "countClauses returns correct count for asserted facts" {
    const engine = try engine_mod.Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    try engine.assertFact("foo(1).");
    try engine.assertFact("foo(2).");
    try engine.assertFact("foo(3).");

    const count = try countClauses(engine, std.testing.allocator, "foo", 1, "true");
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "countClauses returns zero when no clauses match" {
    const engine = try engine_mod.Engine.init(.{}, std.testing.io);
    defer engine.deinit();

    const count = try countClauses(engine, std.testing.allocator, "nonexistent", 1, "true");
    try std.testing.expectEqual(@as(usize, 0), count);
}

fn findPredicate(entries: []const PredicateEntry, name: []const u8, arity: i64) ?PredicateEntry {
    for (entries) |entry| {
        if (entry.arity == arity and std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

test "predicate discovery includes file-loaded and API-asserted clauses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "knowledge.pl",
        .data =
        \\habitat(oak).
        \\habitat(X) :- tree(X).
        ,
    });
    const knowledge_path = try tmp.dir.realPathFileAlloc(std.testing.io, "knowledge.pl", std.testing.allocator);
    defer std.testing.allocator.free(knowledge_path);

    const engine = try engine_mod.Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.loadFile(knowledge_path);
    try engine.assertFact("api_color(green).");

    var predicates = try discoverPredicates(engine, std.testing.allocator);
    defer predicates.deinit(std.testing.allocator);

    const habitat = findPredicate(predicates.entries.items, "habitat", 1) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("habitat", habitat.name);
    try std.testing.expectEqual(@as(i64, 1), habitat.arity);
    try std.testing.expectEqual(@as(usize, 1), habitat.fact_count);
    try std.testing.expectEqual(@as(usize, 1), habitat.rule_count);
    try std.testing.expectEqualStrings("both", predicateKind(habitat.fact_count, habitat.rule_count));

    const api_color = findPredicate(predicates.entries.items, "api_color", 1) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("api_color", api_color.name);
    try std.testing.expectEqual(@as(i64, 1), api_color.arity);
    try std.testing.expectEqual(@as(usize, 1), api_color.fact_count);
    try std.testing.expectEqual(@as(usize, 0), api_color.rule_count);
    try std.testing.expectEqualStrings("fact", predicateKind(api_color.fact_count, api_color.rule_count));
}

test "predicate discovery preserves quoted file-loaded and API-asserted functors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "knowledge.pl",
        .data = "'release-status'(stable).\n",
    });
    const knowledge_path = try tmp.dir.realPathFileAlloc(std.testing.io, "knowledge.pl", std.testing.allocator);
    defer std.testing.allocator.free(knowledge_path);

    const engine = try engine_mod.Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.loadFile(knowledge_path);
    try engine.assertFact("'reviewer\\'s-note'(accepted).");

    var predicates = try discoverPredicates(engine, std.testing.allocator);
    defer predicates.deinit(std.testing.allocator);

    const file_loaded = findPredicate(predicates.entries.items, "release-status", 1) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), file_loaded.fact_count);
    try std.testing.expectEqual(@as(usize, 0), file_loaded.rule_count);

    const asserted = findPredicate(predicates.entries.items, "reviewer's-note", 1) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), asserted.fact_count);
    try std.testing.expectEqual(@as(usize, 0), asserted.rule_count);
}

test "first discovery preserves every runtime predicate before property metadata is loaded" {
    const allocator = std.testing.allocator;
    const engine = try engine_mod.Engine.init(.{ .max_solutions = 1 }, std.testing.io);
    defer engine.deinit();

    // Do not query predicate properties before the first discovery.
    for (0..32) |i| {
        const fact = try std.fmt.allocPrint(allocator, "discovery_probe_{d}(value)", .{i});
        defer allocator.free(fact);
        try engine.assertFact(fact);
    }

    for (0..2) |_| {
        var predicates = try discoverPredicates(engine, allocator);
        defer predicates.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 32), predicates.entries.items.len);
        for (0..32) |i| {
            const name = try std.fmt.allocPrint(allocator, "discovery_probe_{d}", .{i});
            defer allocator.free(name);
            const entry = findPredicate(predicates.entries.items, name, 1) orelse
                return error.MissingRuntimePredicate;
            try std.testing.expectEqual(@as(usize, 1), entry.fact_count);
            try std.testing.expectEqual(@as(usize, 0), entry.rule_count);
        }
    }
}

test "predicate discovery is exhaustive beyond engine solution limit" {
    const engine = try engine_mod.Engine.init(.{ .max_solutions = 2 }, std.testing.io);
    defer engine.deinit();

    try engine.assertFact("limit_alpha(one).");
    try engine.assertFact("limit_alpha(two).");
    try engine.assertFact("limit_alpha(three).");
    try engine.assert("limit_alpha(X) :- limit_beta(X).");
    try engine.assertFact("limit_beta(value).");
    try engine.assertFact("limit_gamma(value).");

    var predicates = try discoverPredicates(engine, std.testing.allocator);
    defer predicates.deinit(std.testing.allocator);

    const alpha = findPredicate(predicates.entries.items, "limit_alpha", 1) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), alpha.fact_count);
    try std.testing.expectEqual(@as(usize, 1), alpha.rule_count);
    try std.testing.expectEqualStrings("both", predicateKind(alpha.fact_count, alpha.rule_count));
    try std.testing.expect(findPredicate(predicates.entries.items, "limit_beta", 1) != null);
    try std.testing.expect(findPredicate(predicates.entries.items, "limit_gamma", 1) != null);
}

test "predicate discovery excludes builtins helpers and operators" {
    const engine = try engine_mod.Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    try engine.assertFact("visible_candidate(value).");
    try engine.assertFact("tms_justification(subject, reason).");
    try engine.assertFact("zpm_source(subject, source).");

    var predicates = try discoverPredicates(engine, std.testing.allocator);
    defer predicates.deinit(std.testing.allocator);

    try std.testing.expect(findPredicate(predicates.entries.items, "visible_candidate", 1) != null);
    try std.testing.expect(findPredicate(predicates.entries.items, "tms_justification", 2) == null);
    try std.testing.expect(findPredicate(predicates.entries.items, "zpm_source", 2) == null);
    try std.testing.expect(findPredicate(predicates.entries.items, "portray", 1) == null);
    try std.testing.expect(findPredicate(predicates.entries.items, "is", 2) == null);
    try std.testing.expect(findPredicate(predicates.entries.items, ":-", 2) == null);
    try std.testing.expect(!isBuiltin("module:private"));
    try std.testing.expect(isBuiltin("$internal"));
    try std.testing.expect(isISOOperator("=", 2));

    const malformed = std.StringHashMap(engine_mod.Term).init(std.testing.allocator);
    var solution = engine_mod.Solution{ .bindings = malformed, .allocator = std.testing.allocator };
    defer solution.bindings.deinit();
    try std.testing.expect(validateCandidate(solution) == null);

    try solution.bindings.put("F", .{ .integer = 1 });
    try solution.bindings.put("A", .{ .integer = 1 });
    try std.testing.expect(validateCandidate(solution) == null);
    _ = solution.bindings.remove("F");
    try solution.bindings.put("F", .{ .atom = "valid_after_malformed" });
    solution.bindings.getPtr("A").?.* = .{ .integer = -1 };
    try std.testing.expect(validateCandidate(solution) == null);
    solution.bindings.getPtr("A").?.* = .{ .atom = "not_an_arity" };
    try std.testing.expect(validateCandidate(solution) == null);
    solution.bindings.getPtr("A").?.* = .{ .atom = "1" };
    const valid = validateCandidate(solution) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("valid_after_malformed", valid.name);
    try std.testing.expectEqual(@as(i64, 1), valid.arity);
}

const FailingQueryDispatch = struct {
    allocator: std.mem.Allocator,
    call_index: usize = 0,
    fail_index: usize,
    failure: engine_mod.EngineError,

    fn query(context: *anyopaque, _: []const u8) engine_mod.EngineError!engine_mod.QueryResult {
        const self: *FailingQueryDispatch = @ptrCast(@alignCast(context));
        const call_index = self.call_index;
        self.call_index += 1;
        if (call_index == self.fail_index) return self.failure;

        const solutions = self.allocator.alloc(engine_mod.Solution, 1) catch
            return engine_mod.EngineError.OutOfMemory;
        errdefer self.allocator.free(solutions);
        var solution = engine_mod.Solution{
            .bindings = std.StringHashMap(engine_mod.Term).init(self.allocator),
            .allocator = self.allocator,
        };
        errdefer solution.deinit();
        if (call_index == 0) {
            try putOwnedBinding(self.allocator, &solution.bindings, "F", .{ .atom = "dispatch_candidate" });
            try putOwnedBinding(self.allocator, &solution.bindings, "A", .{ .integer = 1 });
        } else {
            try putOwnedBinding(self.allocator, &solution.bindings, "Count", .{ .integer = 1 });
        }
        solutions[0] = solution;
        return .{ .solutions = solutions, .allocator = self.allocator };
    }

    fn dispatch(self: *FailingQueryDispatch) QueryDispatch {
        return .{ .context = self, .queryFn = query };
    }
};

fn putOwnedBinding(
    allocator: std.mem.Allocator,
    bindings: *std.StringHashMap(engine_mod.Term),
    key: []const u8,
    term: engine_mod.Term,
) engine_mod.EngineError!void {
    const owned_key = allocator.dupe(u8, key) catch return engine_mod.EngineError.OutOfMemory;
    errdefer allocator.free(owned_key);
    const owned_term: engine_mod.Term = switch (term) {
        .atom => |value| .{ .atom = allocator.dupe(u8, value) catch return engine_mod.EngineError.OutOfMemory },
        else => term,
    };
    errdefer switch (owned_term) {
        .atom => |value| allocator.free(value),
        else => {},
    };
    bindings.put(owned_key, owned_term) catch return engine_mod.EngineError.OutOfMemory;
}

const MalformedCandidateDispatch = struct {
    allocator: std.mem.Allocator,
    call_index: usize = 0,

    fn query(context: *anyopaque, _: []const u8) engine_mod.EngineError!engine_mod.QueryResult {
        const self: *MalformedCandidateDispatch = @ptrCast(@alignCast(context));
        const call_index = self.call_index;
        self.call_index += 1;
        if (call_index != 0) {
            const solutions = self.allocator.alloc(engine_mod.Solution, 1) catch
                return engine_mod.EngineError.OutOfMemory;
            errdefer self.allocator.free(solutions);
            var bindings = std.StringHashMap(engine_mod.Term).init(self.allocator);
            errdefer bindings.deinit();
            try putOwnedBinding(self.allocator, &bindings, "Count", .{ .integer = 1 });
            solutions[0] = .{ .bindings = bindings, .allocator = self.allocator };
            return .{ .solutions = solutions, .allocator = self.allocator };
        }

        const solutions = self.allocator.alloc(engine_mod.Solution, 7) catch
            return engine_mod.EngineError.OutOfMemory;
        var made: usize = 0;
        errdefer {
            for (solutions[0..made]) |*solution| solution.deinit();
            self.allocator.free(solutions);
        }
        while (made < solutions.len) : (made += 1) {
            solutions[made] = .{
                .bindings = std.StringHashMap(engine_mod.Term).init(self.allocator),
                .allocator = self.allocator,
            };
            const bindings = &solutions[made].bindings;
            switch (made) {
                0 => try putOwnedBinding(self.allocator, bindings, "A", .{ .integer = 1 }),
                1 => try putOwnedBinding(self.allocator, bindings, "F", .{ .atom = "missing_arity" }),
                2 => {
                    try putOwnedBinding(self.allocator, bindings, "F", .{ .integer = 7 });
                    try putOwnedBinding(self.allocator, bindings, "A", .{ .integer = 1 });
                },
                3 => {
                    try putOwnedBinding(self.allocator, bindings, "F", .{ .atom = "negative_arity" });
                    try putOwnedBinding(self.allocator, bindings, "A", .{ .integer = -1 });
                },
                4 => {
                    try putOwnedBinding(self.allocator, bindings, "F", .{ .atom = "float_arity" });
                    try putOwnedBinding(self.allocator, bindings, "A", .{ .float = 1.5 });
                },
                5 => {
                    try putOwnedBinding(self.allocator, bindings, "F", .{ .atom = "bad:atom" });
                    try putOwnedBinding(self.allocator, bindings, "A", .{ .atom = "not-a-number" });
                },
                6 => {
                    try putOwnedBinding(self.allocator, bindings, "F", .{ .atom = "valid_after_malformed" });
                    try putOwnedBinding(self.allocator, bindings, "A", .{ .atom = "1" });
                },
                else => unreachable,
            }
        }
        return .{ .solutions = solutions, .allocator = self.allocator };
    }

    fn dispatch(self: *MalformedCandidateDispatch) QueryDispatch {
        return .{ .context = self, .queryFn = query };
    }
};

test "predicate discovery skips malformed dispatch solutions before clause queries" {
    var synthetic = MalformedCandidateDispatch{ .allocator = std.testing.allocator };
    var predicates = try discoverWithDispatch(std.testing.allocator, synthetic.dispatch());
    defer predicates.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), predicates.entries.items.len);
    try std.testing.expectEqualStrings("valid_after_malformed", predicates.entries.items[0].name);
    try std.testing.expectEqual(@as(i64, 1), predicates.entries.items[0].arity);
    try std.testing.expectEqual(@as(usize, 3), synthetic.call_index);
}

test "predicate discovery propagates enumeration and clause-count failures" {
    const cases = [_]struct { fail_index: usize, failure: engine_mod.EngineError }{
        .{ .fail_index = 0, .failure = engine_mod.EngineError.QueryFailed },
        .{ .fail_index = 1, .failure = engine_mod.EngineError.Timeout },
        .{ .fail_index = 2, .failure = engine_mod.EngineError.InvalidJson },
    };
    for (cases) |case| {
        var failing = FailingQueryDispatch{
            .allocator = std.testing.allocator,
            .fail_index = case.fail_index,
            .failure = case.failure,
        };
        try std.testing.expectError(
            case.failure,
            discoverWithDispatch(std.testing.allocator, failing.dispatch()),
        );
        try std.testing.expectEqual(case.fail_index + 1, failing.call_index);
    }
}

const GrowthFailureDispatch = struct {
    allocator: std.mem.Allocator,
    failing_allocator: *std.testing.FailingAllocator,
    candidate_count: usize,
    growth_candidate: usize,
    call_index: usize = 0,

    fn query(context: *anyopaque, _: []const u8) engine_mod.EngineError!engine_mod.QueryResult {
        const self: *GrowthFailureDispatch = @ptrCast(@alignCast(context));
        const call_index = self.call_index;
        self.call_index += 1;
        if (call_index == 0) {
            const solutions = self.allocator.alloc(engine_mod.Solution, self.candidate_count) catch
                return engine_mod.EngineError.OutOfMemory;
            var made: usize = 0;
            errdefer {
                for (solutions[0..made]) |*solution| solution.deinit();
                self.allocator.free(solutions);
            }
            while (made < solutions.len) : (made += 1) {
                solutions[made] = .{
                    .bindings = std.StringHashMap(engine_mod.Term).init(self.allocator),
                    .allocator = self.allocator,
                };
                const name = std.fmt.allocPrint(self.allocator, "growth_candidate_{d}", .{made}) catch
                    return engine_mod.EngineError.OutOfMemory;
                defer self.allocator.free(name);
                try putOwnedBinding(self.allocator, &solutions[made].bindings, "F", .{ .atom = name });
                try putOwnedBinding(self.allocator, &solutions[made].bindings, "A", .{ .integer = 1 });
            }
            return .{ .solutions = solutions, .allocator = self.allocator };
        }

        if (call_index == self.growth_candidate * 2) {
            // The next allocation duplicates the accepted name; the following
            // allocation is the known ArrayList growth point.
            self.failing_allocator.fail_index = self.failing_allocator.alloc_index + 1;
        }
        const solutions = self.allocator.alloc(engine_mod.Solution, 1) catch
            return engine_mod.EngineError.OutOfMemory;
        errdefer self.allocator.free(solutions);
        var bindings = std.StringHashMap(engine_mod.Term).init(self.allocator);
        errdefer bindings.deinit();
        try putOwnedBinding(self.allocator, &bindings, "Count", .{ .integer = 1 });
        solutions[0] = .{ .bindings = bindings, .allocator = self.allocator };
        return .{ .solutions = solutions, .allocator = self.allocator };
    }

    fn dispatch(self: *GrowthFailureDispatch) QueryDispatch {
        return .{ .context = self, .queryFn = query };
    }
};

test "predicate discovery propagates allocation failure" {
    var capacity_probe: std.ArrayList(PredicateEntry) = .empty;
    defer capacity_probe.deinit(std.testing.allocator);
    var growth_candidate: usize = 0;
    while (growth_candidate == 0) {
        const old_capacity = capacity_probe.capacity;
        try capacity_probe.append(std.testing.allocator, .{
            .name = @constCast("probe"),
            .arity = 0,
            .fact_count = 0,
            .rule_count = 0,
        });
        if (old_capacity > 0 and capacity_probe.capacity != old_capacity) {
            growth_candidate = capacity_probe.items.len;
        }
    }

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var synthetic = GrowthFailureDispatch{
        .allocator = std.testing.allocator,
        .failing_allocator = &failing,
        .candidate_count = growth_candidate,
        .growth_candidate = growth_candidate,
    };
    try std.testing.expectError(
        engine_mod.EngineError.OutOfMemory,
        discoverWithDispatch(failing.allocator(), synthetic.dispatch()),
    );
    try std.testing.expect(growth_candidate > 1);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(1 + growth_candidate * 2, synthetic.call_index);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
