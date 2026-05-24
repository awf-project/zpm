const std = @import("std");
const mcp = @import("mcp");
const context = @import("context.zig");
const MemoryRegistry = @import("../memory/registry.zig").MemoryRegistry;

pub const tool = mcp.tools.Tool{
    .name = "list_memories",
    .description = "List all currently mounted memory modules with their scope and mode",
    .inputSchema = .{},
    .annotations = .{
        .readOnlyHint = true,
        .destructiveHint = false,
        .idempotentHint = true,
    },
    .handler = handler,
};

pub fn handler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = args;

    const reg = context.getMemoryRegistryAs(MemoryRegistry) orelse return mcp.tools.ToolError.ExecutionFailed;

    const names = reg.listMounted(allocator) catch return mcp.tools.ToolError.ExecutionFailed;
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    for (names, 0..) |name, i| {
        const entry = reg.getMounted(name) orelse continue;
        const scope_str = @tagName(entry.scope);
        const mode_str = @tagName(entry.mode);
        if (i > 0) buf.appendSlice(allocator, ", ") catch return mcp.tools.ToolError.OutOfMemory;
        const line = std.fmt.allocPrint(allocator, "{s} (scope={s}, mode={s}, mounted=true)", .{ name, scope_str, mode_str }) catch return mcp.tools.ToolError.OutOfMemory;
        defer allocator.free(line);
        buf.appendSlice(allocator, line) catch return mcp.tools.ToolError.OutOfMemory;
    }

    if (names.len == 0) {
        buf.appendSlice(allocator, "No memories mounted") catch return mcp.tools.ToolError.OutOfMemory;
    }

    return mcp.tools.textResult(allocator, buf.items) catch return mcp.tools.ToolError.OutOfMemory;
}

test "list_memories tool has no input schema" {
    try std.testing.expectEqualStrings("list_memories", tool.name);
}

test "list_memories tool is read-only" {
    if (tool.annotations) |ann| {
        try std.testing.expect(ann.readOnlyHint);
    }
}

test "list_memories handler returns ExecutionFailed without registry" {
    context.clearMemoryRegistry();

    const result = handler(null, std.testing.io, std.testing.allocator, null);
    try std.testing.expectError(mcp.tools.ToolError.ExecutionFailed, result);
}
