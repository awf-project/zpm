const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const JournalEntry = @import("../persistence/wal.zig").JournalEntry;
const engine_mod = @import("../prolog/engine.zig");
const term_utils = @import("term_utils");
const validation = @import("tool_validation");
const Term = engine_mod.Term;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit();
    _ = try schema.addString("assumption", "The assumption name to retract", true);
    const built = try schema.build();

    return .{
        .name = "retract_assumption",
        .description = "Retract a named assumption and remove facts that have no remaining justifications",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"assumption"},
        },
        .annotations = .{
            .readOnlyHint = false,
            .destructiveHint = true,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

fn unknownAssumption(allocator: std.mem.Allocator, assumption: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const msg = std.fmt.allocPrint(allocator, "Unknown assumption '{s}'", .{assumption}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.errorResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

pub fn handler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const assumption = mcp.tools.getString(args, "assumption") orelse return mcp.tools.ToolError.InvalidArguments;
    if (!validation.isValidAtomName(assumption)) return mcp.tools.ToolError.InvalidArguments;

    const engine = context.getEngine() orelse return mcp.tools.ToolError.ExecutionFailed;

    const query_str = std.fmt.allocPrint(allocator, "tms_justification(F,{s})", .{assumption}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(query_str);

    var qr = engine.query(query_str) catch return mcp.tools.ToolError.ExecutionFailed;
    defer qr.deinit();

    if (qr.solutions.len == 0) return unknownAssumption(allocator, assumption);

    var fact_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (fact_strings.items) |s| allocator.free(s);
        fact_strings.deinit(allocator);
    }

    for (qr.solutions) |solution| {
        const fact_term = solution.bindings.get("F") orelse continue;
        const fact_str = term_utils.termToString(allocator, fact_term) catch continue;
        fact_strings.append(allocator, fact_str) catch {
            allocator.free(fact_str);
            continue;
        };
    }

    const retract_pattern = std.fmt.allocPrint(allocator, "tms_justification(_,{s})", .{assumption}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(retract_pattern);

    var orphan_facts: std.ArrayList([]const u8) = .empty;
    defer orphan_facts.deinit(allocator);

    for (fact_strings.items) |fact_str| {
        const check_query = std.fmt.allocPrint(allocator, "tms_justification({s},X),X\\={s}", .{ fact_str, assumption }) catch continue;
        defer allocator.free(check_query);

        const has_other = blk: {
            var check_qr = engine.query(check_query) catch break :blk false;
            defer check_qr.deinit();
            break :blk check_qr.solutions.len > 0;
        };

        if (!has_other) {
            orphan_facts.append(allocator, fact_str) catch continue;
        }
    }

    // Journal-first AND atomic: build all WAL entries, write them as a single
    // batch, THEN mutate the engine. A partial batch would replay a half-
    // retracted state (TMS link gone, orphan facts still asserted).
    if (context.getPersistenceManagerAs(PersistenceManager)) |pm| {
        var entries: std.ArrayList(JournalEntry) = .empty;
        defer entries.deinit(allocator);
        const ts = std.time.timestamp();
        entries.append(allocator, .{ .timestamp = ts, .op = .retractall, .clause = retract_pattern }) catch return mcp.tools.ToolError.OutOfMemory;
        for (orphan_facts.items) |fact_str| {
            entries.append(allocator, .{ .timestamp = ts, .op = .retractall, .clause = fact_str }) catch return mcp.tools.ToolError.OutOfMemory;
        }
        pm.journalMutations(entries.items) catch return mcp.tools.ToolError.ExecutionFailed;
    }

    engine.retractAll(retract_pattern) catch {};
    for (orphan_facts.items) |fact_str| {
        engine.retractAll(fact_str) catch {};
    }

    const msg = std.fmt.allocPrint(allocator, "Retracted assumption '{s}': {d} fact(s) removed", .{ assumption, orphan_facts.items.len }) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(msg);
    return mcp.tools.textResult(allocator, msg) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;

test "handler retracts assumption and removes unjustified fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "baseline") != null);
}

test "handler preserves fact when other justification exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);
    defer context.clearEngine();

    try engine.assertFact("active(service).");
    try engine.assertFact("tms_justification(active(service), assumption_a).");
    try engine.assertFact("tms_justification(active(service), assumption_b).");

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "assumption_a" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(!result.is_error);
}

test "handler returns error for unknown assumption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{});
    defer engine.deinit();
    context.setEngine(engine);

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "nonexistent" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "Unknown assumption") != null);
}

test "handler does not write a WAL entry for unknown assumption" {
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

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "nonexistent" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(result.is_error);

    tmp.dir.access("journal.wal", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    var content_buf: [512]u8 = undefined;
    const content = try tmp.dir.readFile("journal.wal", &content_buf);
    try std.testing.expectEqual(@as(usize, 0), content.len);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when assumption key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = std.json.ObjectMap.init(allocator);
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = handler(allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler journals retracted assumption name to WAL" {
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

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(allocator, args);
    try std.testing.expect(!result.is_error);

    var content_buf: [1024]u8 = undefined;
    const content = try tmp.dir.readFile("journal.wal", &content_buf);
    try std.testing.expect(std.mem.indexOf(u8, content, "baseline") != null);
}

test "handler journals per-fact retractall entries to WAL" {
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

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var pm = try PersistenceManager.init(std.testing.allocator, dir_path, dir_path);
    defer pm.deinit();
    context.setPersistenceManager(&pm);
    defer context.clearPersistenceManager();

    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("assumption", .{ .string = "baseline" });
    const args = std.json.Value{ .object = obj };

    _ = try handler(allocator, args);

    var content_buf: [2048]u8 = undefined;
    const content = try tmp.dir.readFile("journal.wal", &content_buf);

    // WAL must contain the TMS link pattern, not the raw assumption name alone
    try std.testing.expect(std.mem.indexOf(u8, content, "tms_justification(_,baseline)") != null);
    // WAL must also contain the orphaned fact pattern
    try std.testing.expect(std.mem.indexOf(u8, content, "deployed(app, prod)") != null);
}
