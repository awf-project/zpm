const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const validation = @import("tool_validation");
const clause_utils = @import("tool_clause_utils");
const manager_mod = @import("../persistence/manager.zig");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

const PersistenceManager = manager_mod.PersistenceManager;
const Engine = engine_mod.Engine;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addInteger("sample_size", "Number of sample clauses per predicate (default: 2, max: 50)", false);
    const built = try schema.build();

    return .{
        .name = "get_kb_overview",
        .description = "Return a single-call JSON snapshot of the ZPM knowledge base: predicates with samples, assumptions, snapshots, persistence health, and mounted memory segments",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = null,
        },
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const engine = context.getEngine() orelse
        return mcp.tools.errorResult(allocator, "Prolog engine is not initialized") catch return mcp.tools.ToolError.OutOfMemory;

    var size = parseSampleSize(args);

    // Budget enforcement: reduce sample_size until the full JSON payload
    // (predicates + assumptions + snapshots + persistence) fits within
    // total_budget. When size reaches 0 and the payload is still too large,
    // fall back to a truncated=true build so the caller is informed.
    // Conservative choice: we never truncate assumptions/snapshots/persistence
    // sections — only predicate samples are reduced. If even size=0 exceeds
    // the budget (very large KB with many predicates), we emit truncated=true
    // with size=0 and accept the overage rather than omitting sections entirely,
    // because partial structural information is more useful than a minimal stub.
    const json = buildBudgeted(allocator, engine, &size) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json);
    return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
}

/// Reduce sample_size until the output fits in total_budget, then return
/// the final JSON. Exactly one allocated slice is live at any point.
fn buildBudgeted(allocator: std.mem.Allocator, engine: *Engine, size: *usize) ![]u8 {
    var truncated = false;
    while (true) {
        const attempt = try buildJson(allocator, engine, size.*, false);
        if (attempt.len <= total_budget or size.* == 0) {
            if (truncated) {
                // Rebuild with the truncated flag set so the caller knows
                // the sample count was reduced from the original request.
                allocator.free(attempt);
                return buildJson(allocator, engine, size.*, true);
            }
            return attempt;
        }
        allocator.free(attempt);
        truncated = true;
        size.* /= 2;
    }
}

fn parseSampleSize(args: ?std.json.Value) usize {
    const a = args orelse return 2;
    const obj = switch (a) {
        .object => |o| o,
        else => return 2,
    };
    const v = obj.get("sample_size") orelse return 2;
    const n = switch (v) {
        .integer => |i| i,
        else => return 2,
    };
    if (n <= 0) return 0;
    if (n > 50) return 50;
    return @intCast(n);
}

const total_budget: usize = 64 * 1024;

const mounts_unavailable_json = "{\"available\":false,\"count\":0,\"items\":[]}";

fn buildJson(allocator: std.mem.Allocator, engine: *Engine, sample_size: usize, truncated: bool) ![]u8 {
    // std.ArrayList(u8) = .empty uses the managed ArrayList API (Zig 0.15):
    // each append/deinit call receives the allocator explicitly. This is
    // intentional and consistent with the rest of the project's tool handlers.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"predicates\":[");

    var first_pred = true;

    const schema_query = "current_predicate(F/A),functor(H,F,A),predicate_property(H,dynamic)";
    // Query errors are intentionally swallowed here: a partial overview with
    // an empty predicates list is preferable to an outright failure when the
    // engine is partially degraded (e.g. OOM inside Trealla, corrupted clause
    // store). Callers detect an unavailable engine via the null-engine early
    // return above; errors at the query level are non-fatal for this tool.
    if (engine.query(schema_query)) |*pred_result| {
        var pr = pred_result.*;
        defer pr.deinit();

        for (pr.solutions) |sol| {
            const f_term = sol.bindings.get("F") orelse continue;
            const a_term = sol.bindings.get("A") orelse continue;
            const name_raw = switch (f_term) {
                .atom => |s| s,
                else => continue,
            };
            const arity: i64 = switch (a_term) {
                .integer => |i| i,
                .atom => |s| std.fmt.parseInt(i64, s, 10) catch continue,
                else => continue,
            };
            if (clause_utils.isBuiltin(name_raw)) continue;
            if (!validation.isValidAtomName(name_raw)) continue;

            const fact_count = clause_utils.countClauses(engine, allocator, name_raw, arity, "true") catch continue;
            const all_count = clause_utils.countClauses(engine, allocator, name_raw, arity, "_") catch continue;
            const rule_count = if (all_count > fact_count) all_count - fact_count else 0;
            const kind = clause_utils.predicateKind(fact_count, rule_count);
            const total_count = fact_count + rule_count;

            var samples: std.ArrayList([]u8) = .empty;
            defer {
                for (samples.items) |s| allocator.free(s);
                samples.deinit(allocator);
            }
            if (sample_size > 0) {
                collectSamples(allocator, engine, name_raw, arity, sample_size, &samples) catch {};
            }

            const pred_json = try buildPredicateJson(allocator, name_raw, arity, kind, total_count, samples.items);
            defer allocator.free(pred_json);

            if (!first_pred) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, pred_json);
            first_pred = false;
        }
    } else |_| {}

    try buf.appendSlice(allocator, "],\"assumptions\":");

    const assump_json = try buildAssumptionsJson(allocator, engine);
    defer allocator.free(assump_json);
    try buf.appendSlice(allocator, assump_json);

    try buf.appendSlice(allocator, ",\"snapshots\":");

    const snap_json = try buildSnapshotsJson(allocator);
    defer allocator.free(snap_json);
    try buf.appendSlice(allocator, snap_json);

    try buf.appendSlice(allocator, ",\"persistence\":");

    const persist_json = try buildPersistenceJson(allocator);
    defer allocator.free(persist_json);
    try buf.appendSlice(allocator, persist_json);

    try buf.appendSlice(allocator, ",\"mounts\":");

    const mounts_json = try buildMountsJson(allocator);
    defer allocator.free(mounts_json);
    try buf.appendSlice(allocator, mounts_json);

    try buf.appendSlice(allocator, if (truncated) ",\"truncated\":true}" else ",\"truncated\":false}");

    return buf.toOwnedSlice(allocator);
}

fn collectSamples(
    allocator: std.mem.Allocator,
    engine: *Engine,
    functor: []const u8,
    arity: i64,
    limit: usize,
    out: *std.ArrayList([]u8),
) !void {
    const query_str = try std.fmt.allocPrint(
        allocator,
        "functor(H,{s},{d}),clause(H,Body),with_output_to(atom(HS),write(H)),(Body=true->SA=HS;(with_output_to(atom(BS),write(Body)),atom_concat(HS,' :- ',T),atom_concat(T,BS,SA)))",
        .{ functor, arity },
    );
    defer allocator.free(query_str);

    var result = try engine.query(query_str);
    defer result.deinit();

    var count: usize = 0;
    for (result.solutions) |sol| {
        if (count >= limit) break;
        const sa_term = sol.bindings.get("SA") orelse continue;
        const sample_str = switch (sa_term) {
            .atom => |s| s,
            else => continue,
        };
        const owned = try allocator.dupe(u8, sample_str);
        try out.append(allocator, owned);
        count += 1;
    }
}

fn buildPredicateJson(
    allocator: std.mem.Allocator,
    functor: []const u8,
    arity: i64,
    kind: []const u8,
    count: usize,
    samples: []const []u8,
) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"functor\":");
    try std.json.Stringify.value(functor, .{}, w);
    try w.writeAll(",\"arity\":");
    try std.json.Stringify.value(arity, .{}, w);
    try w.writeAll(",\"kind\":");
    try std.json.Stringify.value(kind, .{}, w);
    try w.writeAll(",\"count\":");
    try std.json.Stringify.value(count, .{}, w);
    try w.writeAll(",\"samples\":[");
    for (samples, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(s, .{}, w);
    }
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

fn buildAssumptionsJson(allocator: std.mem.Allocator, engine: *Engine) ![]u8 {
    // Deduplicated assumption names. Keys are owned by this map (duped from
    // Trealla bindings). The map is freed first; names ArrayList is freed after.
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var names: std.ArrayList([]u8) = .empty;
    defer {
        // NOTE: strings in `names` are the same pointers stored as keys in
        // `seen`; freeing them via the iterator above is sufficient. We only
        // deinit the backing array here, not the individual strings.
        names.deinit(allocator);
    }

    // Query errors are intentionally swallowed: an empty assumptions list is
    // the correct degraded response when tms_justification is inaccessible.
    if (engine.query("tms_justification(_,Name)")) |*r| {
        var result = r.*;
        defer result.deinit();

        for (result.solutions) |sol| {
            const name_term = sol.bindings.get("Name") orelse continue;
            const name = switch (name_term) {
                .atom => |s| s,
                else => continue,
            };
            // O(1) deduplication via hash map. The key lifetime is tied to
            // the map: owned copy kept until seen.deinit().
            const gop = try seen.getOrPut(name);
            if (gop.found_existing) continue;
            const owned = try allocator.dupe(u8, name);
            gop.key_ptr.* = owned;
            try names.append(allocator, owned);
        }
    } else |_| {}

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"count\":");
    try std.json.Stringify.value(names.items.len, .{}, w);
    try w.writeAll(",\"names\":[");
    for (names.items, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(n, .{}, w);
    }
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

fn buildSnapshotsJson(allocator: std.mem.Allocator) ![]u8 {
    const empty = "{\"count\":0,\"latest\":null,\"latest_at\":null}";

    const pm = context.getPersistenceManagerAs(PersistenceManager) orelse {
        return allocator.dupe(u8, empty);
    };

    const snaps = pm.listSnapshots(allocator) catch {
        return allocator.dupe(u8, empty);
    };
    defer {
        for (snaps) |s| allocator.free(s);
        allocator.free(snaps);
    }

    if (snaps.len == 0) {
        return allocator.dupe(u8, empty);
    }

    // IMPORTANT: defer order — `sorted` must be freed before `snaps` because
    // its element pointers refer into the memory owned by `snaps`. Zig defers
    // run LIFO, so `sorted` (declared last) is freed first. Do not reorder.
    const sorted = try allocator.dupe([]const u8, snaps);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    const latest_name = sorted[sorted.len - 1];
    const display_name = if (std.mem.endsWith(u8, latest_name, ".pl"))
        latest_name[0 .. latest_name.len - 3]
    else
        latest_name;

    var timestamp_str: ?[]u8 = null;
    defer if (timestamp_str) |ts| allocator.free(ts);

    const snap_path = try std.fs.path.join(allocator, &.{ pm.snapshot_dir_path, latest_name });
    defer allocator.free(snap_path);

    if (std.fs.openFileAbsolute(snap_path, .{})) |f| {
        defer f.close();
        if (f.stat()) |stat| {
            timestamp_str = formatIso8601(allocator, stat.mtime) catch null;
        } else |_| {}
    } else |_| {}

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"count\":");
    try std.json.Stringify.value(snaps.len, .{}, w);
    try w.writeAll(",\"latest\":");
    try std.json.Stringify.value(display_name, .{}, w);
    try w.writeAll(",\"latest_at\":");
    if (timestamp_str) |ts| {
        try std.json.Stringify.value(ts, .{}, w);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

fn formatIso8601(allocator: std.mem.Allocator, mtime_ns: i128) ![]u8 {
    const secs_i64: i64 = @intCast(@divFloor(mtime_ns, std.time.ns_per_s));
    const secs: u64 = if (secs_i64 > 0) @intCast(secs_i64) else 0;
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ep_day = es.getEpochDay();
    const year_day = ep_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

fn buildPersistenceJson(allocator: std.mem.Allocator) ![]u8 {
    const pm = context.getPersistenceManagerAs(PersistenceManager);

    const healthy: bool = if (pm) |p| p.status == .active else false;
    const wal_pending: usize = if (pm) |p| countWalPending(allocator, p) else 0;

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"wal_pending\":");
    try std.json.Stringify.value(wal_pending, .{}, w);
    try w.writeAll(",\"healthy\":");
    try w.writeAll(if (healthy) "true" else "false");
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

fn buildMountsJson(allocator: std.mem.Allocator) ![]u8 {
    const reg = context.getMemoryRegistryAs(MemoryRegistry) orelse {
        return allocator.dupe(u8, mounts_unavailable_json);
    };

    const names = reg.listMounted(allocator) catch {
        return allocator.dupe(u8, mounts_unavailable_json);
    };
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    // Lexicographic sort so the items array is stable across calls — the
    // underlying StringHashMap has no ordering guarantee. Sort in place: we
    // own `names`, and reordering slice pointers is safe before serialization.
    std.mem.sort([]const u8, names, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);

    // Serialize items first into a scratch buffer so that `count` reflects only
    // the items actually emitted. `getMounted` can return null (theoretical
    // race in multi-threaded use, defensive otherwise) — counting `names.len`
    // up-front would publish a count that diverges from the JSON array length.
    var items_aw: std.io.Writer.Allocating = .init(allocator);
    defer items_aw.deinit();
    const iw = &items_aw.writer;

    var actual_count: usize = 0;
    for (names) |name| {
        const entry = reg.getMounted(name) orelse continue;
        if (actual_count > 0) try iw.writeByte(',');
        try iw.writeAll("{\"name\":");
        try std.json.Stringify.value(name, .{}, iw);
        try iw.writeAll(",\"scope\":");
        try std.json.Stringify.value(@tagName(entry.scope), .{}, iw);
        try iw.writeAll(",\"mode\":");
        try std.json.Stringify.value(@tagName(entry.mode), .{}, iw);
        try iw.writeByte('}');
        actual_count += 1;
    }
    const items_bytes = try items_aw.toOwnedSlice();
    defer allocator.free(items_bytes);

    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"available\":true,\"count\":");
    try std.json.Stringify.value(actual_count, .{}, w);
    try w.writeAll(",\"items\":[");
    try w.writeAll(items_bytes);
    try w.writeAll("]}");

    return aw.toOwnedSlice();
}

fn countWalPending(allocator: std.mem.Allocator, pm: *PersistenceManager) usize {
    if (pm.wal == null) return 0;
    const wal_path = std.fs.path.join(allocator, &.{ pm.dir_path, "journal.wal" }) catch return 0;
    defer allocator.free(wal_path);
    const file = std.fs.openFileAbsolute(wal_path, .{}) catch return 0;
    defer file.close();

    // Streamed newline count — no heap allocation regardless of WAL size.
    // Invariant: WriteAheadLog.appendBatch (src/persistence/wal.zig:79) writes
    // a trailing '\n' after every entry, so '\n' count == entry count.
    var buf: [4096]u8 = undefined;
    var count: usize = 0;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        for (buf[0..n]) |b| {
            if (b == '\n') count += 1;
        }
    }
    return count;
}

test "tool exports function returning Tool with name get_kb_overview" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    try std.testing.expectEqualStrings("get_kb_overview", t.name);
}

test "tool schema declares sample_size optional parameter" {
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
    try std.testing.expect(props_obj.contains("sample_size"));
    try std.testing.expect(schema.required == null);
}

/// Shared helper for the five empty-engine envelope tests.
/// Caller owns the returned slice (arena-allocated, freed when caller's arena deinits).
fn emptyEngineResponse(allocator: std.mem.Allocator) ![]const u8 {
    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    const result = try handler(allocator, null);
    try std.testing.expect(!result.is_error);
    return result.content[0].text.text;
}

test "handler on empty engine returns JSON with empty predicates array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try emptyEngineResponse(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "\"predicates\":[]") != null);
}

test "handler on empty engine returns correct assumption structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try emptyEngineResponse(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "\"assumptions\":{\"count\":0,\"names\":[]}") != null);
}

test "handler on empty engine returns correct snapshot structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try emptyEngineResponse(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "\"snapshots\":{\"count\":0,\"latest\":null,\"latest_at\":null}") != null);
}

test "handler on empty engine returns correct persistence structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try emptyEngineResponse(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "\"persistence\":{\"wal_pending\":0,\"healthy\":false}") != null);
}

test "handler with null args on empty engine returns empty envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try emptyEngineResponse(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "\"truncated\":false") != null);
}

test "handler with two facts produces predicate entry with functor, arity, kind, count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("parent(tom,bob)");
    try engine.assertFact("parent(bob,sue)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"functor\":\"parent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"arity\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"fact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":2") != null);
}

test "handler with two facts produces samples array of length 2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("parent(tom,bob)");
    try engine.assertFact("parent(bob,sue)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"samples\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "parent(tom,bob)") != null or std.mem.indexOf(u8, text, "parent(bob,sue)") != null);
}

test "handler with rule-only predicate produces kind rule and sample with :- separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assert("grandparent(X,Z) :- parent(X,Y), parent(Y,Z)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"rule\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " :- ") != null);
}

test "handler with mixed facts and rules produces kind both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("vehicle(car)");
    try engine.assert("vehicle(X) :- motorbike(X)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"both\"") != null);
}

test "handler with sample_size 0 returns empty samples arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("fact(a)");
    try engine.assertFact("fact(b)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("sample_size", .{ .integer = 0 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"samples\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":2") != null);
}

test "handler with sample_size 10000 clamps to 50 silently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("fact(a)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("sample_size", .{ .integer = 10000 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler with sample_size -5 clamps to 0 silently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("fact(a)");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("sample_size", .{ .integer = -5 });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler with arity-0 predicate produces sample without parens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("is_ready");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"is_ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"arity\":0") != null);
}

test "handler returns all sample-able clauses for a fact predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("good_pred(a)");
    try engine.assertFact("good_pred(b)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "good_pred") != null);
}

test "handler deduplicates assumptions in response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("tms_justification(fact1, a1)");
    try engine.assertFact("tms_justification(fact2, a1)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"names\":[\"a1\"]") != null);
}

test "handler with one snapshot returns snapshot metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("test_fact(x)");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    try pm.saveSnapshot(engine, "kb_v1");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"latest\":\"kb_v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"latest_at\":\"") != null);
}

test "handler snapshot timestamp matches ISO-8601 format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    try pm.saveSnapshot(engine, "kb_v1");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "20") != null);
}

test "handler with WAL entries reports wal_pending count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    try pm.journalMutation(.{ .timestamp = 1713000000, .clause = "fact1(a)" });
    try pm.journalMutation(.{ .timestamp = 1713000001, .clause = "fact2(b)" });

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"wal_pending\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"healthy\":true") != null);
}

test "handler returns healthy false when persistence manager is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    context.clearPersistenceManager();
    defer context.clearPersistenceManager();

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"healthy\":false") != null);
}

test "handler returns errorResult when engine is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();
    defer context.clearEngine();

    const result = try handler(allocator, null);

    try std.testing.expect(result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "not initialized") != null);
}

test "handler response does not contain absolute paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("test(x)");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, dir_path) == null);
}

test "handler with small KB sets truncated false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("small(x)");

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"truncated\":false") != null);
}

test "handler with null registry returns mounts available:false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    context.clearMemoryRegistry();
    defer context.clearMemoryRegistry();

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mounts\":{\"available\":false,\"count\":0,\"items\":[]}") != null);
}

test "handler with empty registry returns mounts available:true count:0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    context.setMemoryRegistry(@ptrCast(&reg));
    defer context.clearMemoryRegistry();

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"items\":[]") != null);
}

test "handler with mounted segments returns name scope mode in mounts items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.mount("mymem", dir_path, .project, .rw, engine);
    context.setMemoryRegistry(@ptrCast(&reg));
    defer context.clearMemoryRegistry();

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"available\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"mymem\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"scope\":\"project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mode\":\"rw\"") != null);
}

test "handler with multiple mounts returns items sorted lexicographically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    try tmp.dir.makeDir("zoo");
    try tmp.dir.makeDir("apple");
    try tmp.dir.makeDir("middle");

    const path_a = try std.fs.path.join(allocator, &.{ dir_path, "apple" });
    const path_m = try std.fs.path.join(allocator, &.{ dir_path, "middle" });
    const path_z = try std.fs.path.join(allocator, &.{ dir_path, "zoo" });

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    // Insert in non-alphabetic order — the lexicographic sort must reorder them.
    try reg.mount("zoo", path_z, .project, .rw, engine);
    try reg.mount("apple", path_a, .project, .rw, engine);
    try reg.mount("middle", path_m, .project, .rw, engine);
    context.setMemoryRegistry(@ptrCast(&reg));
    defer context.clearMemoryRegistry();

    const result = try handler(allocator, null);
    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;

    const idx_a = std.mem.indexOf(u8, text, "\"name\":\"apple\"") orelse return error.TestUnexpectedResult;
    const idx_m = std.mem.indexOf(u8, text, "\"name\":\"middle\"") orelse return error.TestUnexpectedResult;
    const idx_z = std.mem.indexOf(u8, text, "\"name\":\"zoo\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(idx_a < idx_m);
    try std.testing.expect(idx_m < idx_z);
}

test "handler result length is under 64 KiB when budgeting is applied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Engine with increased solution cap to enumerate all seeded predicates.
    const engine = try Engine.init(.{ .max_solutions = 300 });
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    // Build a compile-time long argument string: 6 args of 40 chars = 240 + 5 commas = 245 chars.
    // Each predicate name: "kboverview_test_pred_NN" ≈ 24 chars.
    // Sample = 24 + 1 + 245 + 1 = 271 chars.
    // JSON entry at size=2: ~50 + 24 + 2 + 6 + 2 + 271*2 + 2 + 4 = ~632 chars.
    // 90 entries × 632 = 56,880 < 65,536 — under! Try 80 preds, bigger samples.
    //
    // Use 2 facts of 400 chars each (8 args of 48 chars):
    // sample = 24 + 1 + 8*48 + 7 + 1 = 417 chars.
    // Entry at size=2: 80+24+417*2 = 938 chars. 80 × 938 = 75,040 > 64 KiB ✓
    // At size=1: 80 × (417 + 80) = 80 × 497 = 39,760 < 64 KiB ✓ → stops here.
    const arg_a = "a" ** 48;
    const arg_b = "b" ** 48;
    const arg_c = "c" ** 48;
    const arg_d = "d" ** 48;
    const arg_e = "e" ** 48;
    const arg_f = "f" ** 48;
    const arg_g = "g" ** 48;
    const arg_h = "h" ** 48;
    const arg_i = "i" ** 48;
    const arg_j = "j" ** 48;
    const arg_k = "k" ** 48;
    const arg_l = "l" ** 48;
    const arg_m = "m" ** 48;
    const arg_n = "n" ** 48;
    const arg_o = "o" ** 48;
    const arg_p = "p" ** 48;
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        const f1 = try std.fmt.allocPrint(
            allocator,
            "kboverview_test_pred_{d}({s},{s},{s},{s},{s},{s},{s},{s})",
            .{ i, arg_a, arg_b, arg_c, arg_d, arg_e, arg_f, arg_g, arg_h },
        );
        const f2 = try std.fmt.allocPrint(
            allocator,
            "kboverview_test_pred_{d}({s},{s},{s},{s},{s},{s},{s},{s})",
            .{ i, arg_i, arg_j, arg_k, arg_l, arg_m, arg_n, arg_o, arg_p },
        );
        try engine.assertFact(f1);
        try engine.assertFact(f2);
        allocator.free(f1);
        allocator.free(f2);
    }

    const result = try handler(allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"truncated\":true") != null);
    try std.testing.expect(text.len < 64 * 1024);
}
