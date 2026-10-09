const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");

pub fn tool(allocator: std.mem.Allocator) !mcp.tools.Tool {
    var schema = mcp.schema.InputSchemaBuilder.init(allocator);
    defer schema.deinit(allocator);
    _ = try schema.addString(allocator, "fact", "The Prolog fact to check belief status for", true);
    _ = try schema.addString(allocator, "memory", "Target memory segment (optional, defaults to default memory)", false);
    const built = try schema.build(allocator);

    return .{
        .name = "get_belief_status",
        .description = "Query whether a belief is currently supported and which assumptions justify it",
        .inputSchema = .{
            .properties = built.object.get("properties"),
            .required = &.{"fact"},
        },
        .annotations = .{
            .readOnlyHint = true,
            .destructiveHint = false,
            .idempotentHint = true,
        },
        .handler = handler,
    };
}

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const fact = mcp.tools.getString(args, "fact") orelse return mcp.tools.ToolError.InvalidArguments;

    const engine = context.getEngineForMemory(context.resolveMemoryName(args)) orelse return mcp.tools.ToolError.ExecutionFailed;

    const query_str = std.fmt.allocPrint(allocator, "tms_justification({s}, A)", .{fact}) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(query_str);

    var qr = engine.query(query_str) catch {
        return buildResponse(allocator, false, &.{}, "unknown");
    };
    defer qr.deinit();

    var justifications: std.ArrayList([]const u8) = .empty;
    defer justifications.deinit(allocator);

    for (qr.solutions) |solution| {
        const assumption_term = solution.bindings.get("A") orelse continue;
        const assumption_str = switch (assumption_term) {
            .atom => |s| s,
            else => continue,
        };
        justifications.append(allocator, assumption_str) catch continue;
    }

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |s| allocator.free(s);

    const source: []const u8 = blk: {
        const source_query = std.fmt.allocPrint(allocator, "zpm_source({s}, S)", .{fact}) catch break :blk "unknown";
        defer allocator.free(source_query);
        var sqr = engine.query(source_query) catch break :blk "unknown";
        defer sqr.deinit();
        if (sqr.solutions.len > 0) {
            if (sqr.solutions[0].bindings.get("S")) |s_term| {
                const atom = switch (s_term) {
                    .atom => |s| s,
                    else => break :blk "unknown",
                };
                owned_source = allocator.dupe(u8, atom) catch break :blk "unknown";
                break :blk owned_source.?;
            }
        }
        break :blk "unknown";
    };

    return buildResponse(allocator, justifications.items.len > 0, justifications.items, source);
}

fn buildResponse(allocator: std.mem.Allocator, supported: bool, justifications: []const []const u8, source: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"status\":\"") catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, if (supported) "in" else "out") catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, "\",\"justifications\":[") catch return mcp.tools.ToolError.OutOfMemory;
    for (justifications, 0..) |j, i| {
        if (i > 0) buf.append(allocator, ',') catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
        buf.appendSlice(allocator, j) catch return mcp.tools.ToolError.OutOfMemory;
        buf.append(allocator, '"') catch return mcp.tools.ToolError.OutOfMemory;
    }
    buf.appendSlice(allocator, "],\"source\":\"") catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, source) catch return mcp.tools.ToolError.OutOfMemory;
    buf.appendSlice(allocator, "\"}") catch return mcp.tools.ToolError.OutOfMemory;

    return mcp.tools.textResult(allocator, buf.items) catch return mcp.tools.ToolError.OutOfMemory;
}

const Engine = @import("../prolog/engine.zig").Engine;
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

test "tool schema exposes memory as an optional string with the exact description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const t = try tool(allocator);
    const schema = t.inputSchema orelse return error.MissingSchema;
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

test "handler returns status in with justifications when fact is supported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("deployed(app, prod).");
    try engine.assertFact("tms_justification(deployed(app, prod), baseline).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "deployed(app, prod)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "baseline") != null);
}

test "handler returns status out with empty justifications when fact is unsupported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "unknown_fact(x)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"out\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "[]") != null);
}

test "handler returns multiple justifications when fact has multiple supporting assumptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("active(service).");
    try engine.assertFact("tms_justification(active(service), assumption_a).");
    try engine.assertFact("tms_justification(active(service), assumption_b).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "active(service)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "assumption_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "assumption_b") != null);
}

test "handler returns InvalidArguments when args are null" {
    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "handler returns InvalidArguments when fact key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj: std.json.ObjectMap = .{};
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.InvalidArguments, result);
}

test "source field is interactive when zpm_source metadata is asserted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("config(timeout, 30).");
    try engine.assertFact("zpm_source(config(timeout, 30), interactive).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "config(timeout, 30)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"interactive\"") != null);
}

test "source field is unknown when no zpm_source metadata exists for fact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const engine = try Engine.init(.{}, std.testing.io);
    defer engine.deinit();
    context.setEngine(engine);

    try engine.assertFact("config(timeout, 30).");

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "config(timeout, 30)" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"unknown\"") != null);
}

test "handler returns ExecutionFailed when engine is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    context.clearEngine();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "deployed(app, prod)" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}

test "handler returns belief status from explicitly named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);

    var kfile = try tmp.dir.createFile(std.testing.io, "knowledge.pl", .{});
    defer kfile.close(std.testing.io);
    try kfile.writeStreamingAll(std.testing.io, "tms_justification(named_fact, named_assumption).\n");

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    try registry.mount("feature_beliefs", path_buf[0..path_len], .project, .ro, std.testing.io);
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "named_fact" });
    try obj.put(allocator, "memory", .{ .string = "feature_beliefs" });
    const args = std.json.Value{ .object = obj };

    const result = try handler(null, std.testing.io, allocator, args);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "\"status\":\"in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "named_assumption") != null);
}

test "handler returns ExecutionFailed for unmounted named memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = MemoryRegistry.init(allocator);
    defer registry.deinit();
    context.setMemoryRegistry(@ptrCast(&registry));
    defer context.clearMemoryRegistry();

    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "fact", .{ .string = "named_fact" });
    try obj.put(allocator, "memory", .{ .string = "missing_memory" });
    const args = std.json.Value{ .object = obj };

    const result = handler(null, std.testing.io, allocator, args);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
