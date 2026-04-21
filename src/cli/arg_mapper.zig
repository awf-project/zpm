const std = @import("std");
const mcp = @import("mcp");

pub const MapError = error{
    MissingRequired,
    UnknownFlag,
    OutOfMemory,
};

/// Out-param populated by `mapArgs` so the caller can name the offending
/// field in error messages. Only meaningful when `mapArgs` returns a
/// diagnostic error (MissingRequired / UnknownFlag).
pub const Diag = struct {
    field: ?[]const u8 = null,
};

fn resolvePositionalField(
    override: ?[]const u8,
    required: []const []const u8,
) ?[]const u8 {
    if (override) |f| return f;
    if (required.len > 0) return required[0];
    return null;
}

/// Match a `--flag` token against a property name, treating `_` in the prop
/// as `-` in the flag. No allocation.
fn matchFlagToProp(token: []const u8, props: std.json.ObjectMap) ?[]const u8 {
    if (!std.mem.startsWith(u8, token, "--")) return null;
    const tail = token[2..];
    var it = props.iterator();
    while (it.next()) |entry| {
        const prop = entry.key_ptr.*;
        if (prop.len != tail.len) continue;
        var matches = true;
        for (prop, tail) |p, t| {
            const pn: u8 = if (p == '_') '-' else p;
            if (pn != t) {
                matches = false;
                break;
            }
        }
        if (matches) return prop;
    }
    return null;
}

/// Map CLI argv to the JSON payload expected by an MCP tool handler.
/// Writes the offending field into `diag.field` when returning
/// MissingRequired or UnknownFlag.
pub fn mapArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    tool: mcp.tools.Tool,
    positional_field: ?[]const u8,
    diag: *Diag,
) MapError!?std.json.Value {
    const schema = tool.inputSchema orelse return null;
    const props_val = schema.properties orelse return null;
    if (props_val != .object or props_val.object.count() == 0) return null;
    const required = schema.required orelse &[_][]const u8{};
    const positional = resolvePositionalField(positional_field, required);

    var obj = std.json.ObjectMap.init(allocator);

    const has_positional_value = positional != null and argv.len > 0 and !std.mem.startsWith(u8, argv[0], "--");
    if (has_positional_value) {
        try obj.put(positional.?, .{ .string = argv[0] });
    }
    const flag_start: usize = if (has_positional_value) 1 else 0;

    var i: usize = flag_start;
    while (i < argv.len) {
        const token = argv[i];
        if (!std.mem.startsWith(u8, token, "--")) {
            i += 1;
            continue;
        }
        if (i + 1 >= argv.len) {
            diag.field = token;
            return MapError.UnknownFlag;
        }
        if (matchFlagToProp(token, props_val.object)) |field_name| {
            try obj.put(field_name, .{ .string = argv[i + 1] });
            i += 2;
        } else {
            diag.field = token;
            return MapError.UnknownFlag;
        }
    }

    for (required) |field| {
        if (!obj.contains(field)) {
            diag.field = field;
            return MapError.MissingRequired;
        }
    }

    return .{ .object = obj };
}

fn testHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = allocator;
    _ = args;
    return .{ .content = &.{}, .is_error = false };
}

test "mapArgs returns null for no-param tool with empty argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const t: mcp.tools.Tool = .{ .name = "no-params", .inputSchema = null, .handler = testHandler };
    const result = try mapArgs(arena.allocator(), &.{}, t, null, &diag);
    try std.testing.expectEqual(@as(?std.json.Value, null), result);
}

test "mapArgs maps positional arg to first required parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = mcp.schema.InputSchemaBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.addString("fact", "A Prolog fact", true);
    const schema = try builder.build();

    const t: mcp.tools.Tool = .{
        .name = "remember-fact",
        .inputSchema = .{ .properties = schema.object.get("properties"), .required = &.{"fact"} },
        .handler = testHandler,
    };
    var diag: Diag = .{};
    const result = try mapArgs(allocator, &.{"my_term(42)"}, t, null, &diag);
    try std.testing.expectEqualStrings("my_term(42)", result.?.object.get("fact").?.string);
}

test "mapArgs honours positional_field override when provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = mcp.schema.InputSchemaBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.addString("body", "Rule body", true);
    _ = try builder.addString("head", "Rule head", true);
    const schema = try builder.build();

    const t: mcp.tools.Tool = .{
        .name = "define-rule",
        .inputSchema = .{ .properties = schema.object.get("properties"), .required = &.{ "body", "head" } },
        .handler = testHandler,
    };
    var diag: Diag = .{};
    const result = try mapArgs(allocator, &.{ "grandparent(X,Z)", "--body", "parent(X,Y), parent(Y,Z)" }, t, "head", &diag);
    try std.testing.expectEqualStrings("grandparent(X,Z)", result.?.object.get("head").?.string);
    try std.testing.expectEqualStrings("parent(X,Y), parent(Y,Z)", result.?.object.get("body").?.string);
}

test "mapArgs maps second required field from --flag value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = mcp.schema.InputSchemaBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.addString("query", "A query", true);
    _ = try builder.addString("context", "Context", true);
    const schema = try builder.build();

    const t: mcp.tools.Tool = .{
        .name = "test-tool",
        .inputSchema = .{ .properties = schema.object.get("properties"), .required = &.{ "query", "context" } },
        .handler = testHandler,
    };
    var diag: Diag = .{};
    const result = try mapArgs(allocator, &.{ "my_query", "--context", "ctx_val" }, t, null, &diag);
    try std.testing.expectEqualStrings("my_query", result.?.object.get("query").?.string);
    try std.testing.expectEqualStrings("ctx_val", result.?.object.get("context").?.string);
}

test "mapArgs converts kebab-case flag to snake_case key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = mcp.schema.InputSchemaBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.addString("first_arg", "First", true);
    _ = try builder.addString("my_field", "My field", true);
    const schema = try builder.build();

    const t: mcp.tools.Tool = .{
        .name = "test-tool",
        .inputSchema = .{ .properties = schema.object.get("properties"), .required = &.{ "first_arg", "my_field" } },
        .handler = testHandler,
    };
    var diag: Diag = .{};
    const result = try mapArgs(allocator, &.{ "val1", "--my-field", "val2" }, t, null, &diag);
    try std.testing.expectEqualStrings("val1", result.?.object.get("first_arg").?.string);
    try std.testing.expectEqualStrings("val2", result.?.object.get("my_field").?.string);
}

test "mapArgs returns MissingRequired with field name when required arg omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = mcp.schema.InputSchemaBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.addString("fact", "A fact", true);
    const schema = try builder.build();

    const t: mcp.tools.Tool = .{
        .name = "remember-fact",
        .inputSchema = .{ .properties = schema.object.get("properties"), .required = &.{"fact"} },
        .handler = testHandler,
    };
    var diag: Diag = .{};
    try std.testing.expectError(MapError.MissingRequired, mapArgs(allocator, &.{}, t, null, &diag));
    try std.testing.expectEqualStrings("fact", diag.field.?);
}

test "mapArgs returns UnknownFlag for unmatched --flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder = mcp.schema.InputSchemaBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.addString("fact", "A fact", true);
    const schema = try builder.build();

    const t: mcp.tools.Tool = .{
        .name = "remember-fact",
        .inputSchema = .{ .properties = schema.object.get("properties"), .required = &.{"fact"} },
        .handler = testHandler,
    };
    var diag: Diag = .{};
    try std.testing.expectError(MapError.UnknownFlag, mapArgs(allocator, &.{ "my_fact", "--bogus", "x" }, t, null, &diag));
    try std.testing.expectEqualStrings("--bogus", diag.field.?);
}
