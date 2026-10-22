const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const engine_mod = @import("../prolog/engine.zig");
const clause_utils = @import("tool_clause_utils");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "get_knowledge_schema",
        .description = "Introspect the knowledge base to discover all defined predicates, their arities, and whether they are facts, rules, or both",
        .inputSchema = .{
            .properties = built.object.get("properties"),
        },
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

const PredicateEntry = clause_utils.PredicateEntry;

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const engine = context.getEngineForMemory(context.resolveMemoryName(args)) orelse
        return mcp.tools.errorResult(allocator, "Prolog engine is not initialized") catch return mcp.tools.ToolError.OutOfMemory;

    var predicates = clause_utils.discoverPredicates(engine, allocator) catch
        return mcp.tools.ToolError.ExecutionFailed;
    defer predicates.deinit(allocator);

    const json = buildSchemaJson(allocator, predicates.entries.items) catch
        return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(json);
    return mcp.tools.textResult(allocator, json) catch return mcp.tools.ToolError.OutOfMemory;
}

fn buildSchemaJson(allocator: std.mem.Allocator, entries: []const PredicateEntry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"predicates\":[");
    for (entries, 0..) |entry, i| {
        if (i > 0) try w.writeByte(',');
        const pred_type = clause_utils.predicateKind(entry.fact_count, entry.rule_count);
        const count = entry.fact_count + entry.rule_count;
        try w.writeAll("{\"name\":");
        try std.json.Stringify.value(entry.name, .{}, w);
        try w.writeAll(",\"arity\":");
        try std.json.Stringify.value(entry.arity, .{}, w);
        try w.writeAll(",\"type\":");
        try std.json.Stringify.value(pred_type, .{}, w);
        try w.writeAll(",\"count\":");
        try std.json.Stringify.value(count, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("],\"total\":");
    try std.json.Stringify.value(entries.len, .{}, w);
    try w.writeByte('}');

    return aw.toOwnedSlice();
}

const Engine = engine_mod.Engine;

test "get_knowledge_schema tool exposes memory as an optional JSON-schema string with exact description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const built_tool = try tool(arena.allocator());
    const schema = built_tool.inputSchema orelse return error.MissingSchema;
    const properties = schema.properties orelse return error.MissingProperties;
    const properties_object = switch (properties) {
        .object => |object| object,
        else => return error.UnexpectedPropertiesType,
    };
    const memory = properties_object.get("memory") orelse return error.MissingMemoryProperty;
    const memory_object = switch (memory) {
        .object => |object| object,
        else => return error.UnexpectedMemoryPropertyType,
    };

    try std.testing.expectEqualStrings("string", memory_object.get("type").?.string);
    try std.testing.expectEqualStrings(
        "Target memory segment (optional, defaults to default memory)",
        memory_object.get("description").?.string,
    );
    for (schema.required orelse &.{}) |required| {
        try std.testing.expect(!std.mem.eql(u8, required, "memory"));
    }
}

test "handler returns predicate list when facts are asserted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("person(alice)");
    try engine.assertFact("person(bob)");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "default" });
    const args = std.json.Value{ .object = obj };
    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "predicates") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "person") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"arity\":1") != null);
}

fn schemaPredicate(parsed: std.json.Value, name: []const u8) ?std.json.ObjectMap {
    const predicates = parsed.object.get("predicates") orelse return null;
    for (predicates.array.items) |predicate| {
        const object = predicate.object;
        const candidate = object.get("name") orelse continue;
        if (std.mem.eql(u8, candidate.string, name)) return object;
    }
    return null;
}

test "schema reports file-loaded and post-mount API-asserted predicates from an isolated writable memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);

    var knowledge = try tmp.dir.createFile(std.testing.io, "knowledge.pl", .{});
    try knowledge.writeStreamingAll(
        std.testing.io,
        "habitat(otter, river).\nhabitat(heron, marsh).\nwetland(X) :- habitat(X, marsh).\n",
    );
    knowledge.close(std.testing.io);

    const default_engine = try Engine.init(.{}, std.testing.io);
    defer default_engine.deinit();
    context.setEngine(default_engine);
    defer context.clearEngine();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("schema_memory", path_buf[0..path_len], .project, .rw, std.testing.io);
    try registry.getMounted("schema_memory").?.engine.assertFact("observed(kingfisher)");
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "schema_memory" });
    const args = std.json.Value{ .object = obj };
    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.content[0].text.text, .{});
    defer parsed.deinit();

    const habitat = schemaPredicate(parsed.value, "habitat") orelse return error.MissingHabitat;
    try std.testing.expectEqual(@as(i64, 2), habitat.get("arity").?.integer);
    try std.testing.expectEqualStrings("fact", habitat.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 2), habitat.get("count").?.integer);

    const wetland = schemaPredicate(parsed.value, "wetland") orelse return error.MissingWetland;
    try std.testing.expectEqual(@as(i64, 1), wetland.get("arity").?.integer);
    try std.testing.expectEqualStrings("rule", wetland.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), wetland.get("count").?.integer);

    const observed = schemaPredicate(parsed.value, "observed") orelse return error.MissingObserved;
    try std.testing.expectEqual(@as(i64, 1), observed.get("arity").?.integer);
    try std.testing.expectEqualStrings("fact", observed.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), observed.get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("total").?.integer);
    try std.testing.expect(habitat.get("fact_count") == null);
    try std.testing.expect(habitat.get("rule_count") == null);

    const default_result = try handler(null, std.testing.io, allocator, null);
    var default_parsed = try std.json.parseFromSlice(std.json.Value, allocator, default_result.content[0].text.text, .{});
    defer default_parsed.deinit();
    try std.testing.expect(schemaPredicate(default_parsed.value, "habitat") == null);
    try std.testing.expect(schemaPredicate(default_parsed.value, "observed") == null);
}

test "schema reads file-loaded predicates from a read-only memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);

    var knowledge = try tmp.dir.createFile(std.testing.io, "knowledge.pl", .{});
    try knowledge.writeStreamingAll(std.testing.io, "protected_species(lynx).\n");
    knowledge.close(std.testing.io);

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("archive", path_buf[0..path_len], .project, .ro, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "archive" });
    const result = try handler(null, std.testing.io, allocator, .{ .object = obj });
    try std.testing.expect(!result.is_error);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.content[0].text.text, .{});
    defer parsed.deinit();
    const predicate = schemaPredicate(parsed.value, "protected_species") orelse return error.MissingProtectedSpecies;
    try std.testing.expectEqual(@as(i64, 1), predicate.get("arity").?.integer);
    try std.testing.expectEqualStrings("fact", predicate.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), predicate.get("count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("total").?.integer);
}

test "handler reports unavailable named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "memory", .{ .string = "missing_memory" });
    const args = std.json.Value{ .object = obj };
    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("Prolog engine is not initialized", result.content[0].text.text);
}

test "schema distinguishes empty knowledge from introspection failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("{\"predicates\":[],\"total\":0}", result.content[0].text.text);

    {
        const saved_handle = engine.handle;
        engine.handle = null;
        defer engine.handle = saved_handle;
        try std.testing.expectError(
            mcp.tools.ToolError.ExecutionFailed,
            handler(null, std.testing.io, allocator, null),
        );
    }

    {
        const saved_max_memory = engine.config.max_memory_bytes;
        engine.config.max_memory_bytes = 0;
        defer engine.config.max_memory_bytes = saved_max_memory;
        try std.testing.expectError(
            mcp.tools.ToolError.ExecutionFailed,
            handler(null, std.testing.io, allocator, null),
        );
    }

    // An empty real engine has no discovered entries, so discovery performs no
    // response allocations. These failures therefore cover schema JSON and
    // text-result presentation independently of discovery.
    var json_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        mcp.tools.ToolError.OutOfMemory,
        handler(null, std.testing.io, json_failing.allocator(), null),
    );
    var text_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        mcp.tools.ToolError.OutOfMemory,
        handler(null, std.testing.io, text_failing.allocator(), null),
    );
}

test "handler classifies rule-only predicate as rule type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assert("grandparent(X,Z) :- parent(X,Y), parent(Y,Z)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "grandparent") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"rule\"") != null);
}

test "handler returns valid result when args are null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
}

test "handler returns error message when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    const result = try handler(null, std.testing.io, allocator, null);
    try std.testing.expect(result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "not initialized") != null);
}

test "handler classifies fact-only predicate as fact type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("animal(dog)");
    try engine.assertFact("animal(cat)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"fact\"") != null);
}

test "handler classifies predicate with facts and rules as both type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("vehicle(car)");
    try engine.assert("vehicle(X) :- motorbike(X)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\":\"both\"") != null);
}

test "handler includes accurate clause count in schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("color(red)");
    try engine.assertFact("color(blue)");
    try engine.assertFact("color(green)");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"count\":3") != null);
}

test "handler reports arity 0 for zero-argument predicate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("is_ready");

    const result = try handler(null, std.testing.io, allocator, null);

    try std.testing.expect(!result.is_error);
    const text = result.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"is_ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"arity\":0") != null);
}
