const std = @import("std");
const engine_mod = @import("../prolog/engine.zig");

fn looksLikeVariable(s: []const u8) bool {
    if (s.len == 0) return false;
    // Prolog variables start with uppercase or underscore
    if (s[0] >= 'A' and s[0] <= 'Z') return true;
    if (s[0] == '_') return true;
    return false;
}

fn isNumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    // Prolog variables (start with uppercase or _) must NOT be quoted
    if (looksLikeVariable(s)) return false;
    // Pure integers are valid Prolog numbers, don't quote
    if (isNumeric(s)) return false;
    // Non-numeric atoms starting with digit need quoting (e.g., "0.1.0")
    if (s[0] >= '0' and s[0] <= '9') return true;
    // Check all chars are simple identifier chars
    for (s) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) return true;
    }
    return false;
}

pub fn termToString(allocator: std.mem.Allocator, term: engine_mod.Term) ![]u8 {
    return switch (term) {
        .atom => |s| if (needsQuoting(s)) std.fmt.allocPrint(allocator, "'{s}'", .{s}) else allocator.dupe(u8, s),
        .variable => |s| allocator.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .compound => |c| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, c.functor);
            try buf.append(allocator, '(');
            for (c.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const arg_str = try termToString(allocator, arg);
                defer allocator.free(arg_str);
                try buf.appendSlice(allocator, arg_str);
            }
            try buf.append(allocator, ')');
            return buf.toOwnedSlice(allocator);
        },
        .list => |items| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try buf.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const item_str = try termToString(allocator, item);
                defer allocator.free(item_str);
                try buf.appendSlice(allocator, item_str);
            }
            try buf.append(allocator, ']');
            return buf.toOwnedSlice(allocator);
        },
    };
}
