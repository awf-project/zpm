const std = @import("std");
const mcp = @import("mcp");

pub const OutputFormat = enum {
    text,
    json,
};

pub fn renderWriter(
    result: mcp.tools.ToolResult,
    format: OutputFormat,
    writer: *std.io.Writer,
) !u8 {
    switch (format) {
        .text => {
            if (result.is_error) try writer.writeAll("ERROR: ");
            for (result.content) |block| {
                if (block.asText()) |text| {
                    try writer.writeAll(text);
                    try writer.writeAll("\n");
                }
            }
        },
        .json => {
            try writer.writeAll("[");
            var first = true;
            for (result.content) |block| {
                if (block.asText()) |text| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try std.json.Stringify.value(text, .{}, writer);
                }
            }
            try writer.writeAll("]\n");
        },
    }
    return if (result.is_error) 1 else 0;
}

pub fn render(
    result: mcp.tools.ToolResult,
    format: OutputFormat,
) !u8 {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    var buf: [4096]u8 = undefined;
    var fw = stdout.writer(&buf);
    const code = try renderWriter(result, format, &fw.interface);
    try fw.interface.flush();
    return code;
}

test "renderWriter writes text content to writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try mcp.tools.textResult(allocator, "hello output");
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const code = try renderWriter(result, .text, &aw.writer);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "hello output") != null);
}

test "renderWriter prefixes ERROR: on is_error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try mcp.tools.errorResult(allocator, "execution failed");
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const code = try renderWriter(result, .text, &aw.writer);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), "ERROR: "));
}

test "renderWriter json outputs array with JSON-escaped text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try mcp.tools.textResult(allocator, "line1\nline2\"");
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    _ = try renderWriter(result, .json, &aw.writer);
    const written = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, written, "["));
    try std.testing.expect(std.mem.indexOf(u8, written, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\\\"") != null);
}
