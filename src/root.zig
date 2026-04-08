const std = @import("std");

pub fn greet(name: []const u8, writer: anytype) !void {
    try writer.print("Hello, {s}!\n", .{name});
}

test "greet writes greeting" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try greet("World", stream.writer());
    try std.testing.expectEqualStrings("Hello, World!\n", stream.getWritten());
}

test "greet with empty name" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try greet("", stream.writer());
    try std.testing.expectEqualStrings("Hello, !\n", stream.getWritten());
}
