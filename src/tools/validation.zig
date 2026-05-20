const std = @import("std");

/// Assumption names flow straight into Prolog query text, so reject anything
/// that isn't a lower-case atom to prevent goal injection (e.g. a name like
/// `x),assert(evil(1))` would otherwise execute arbitrary Prolog).
pub fn isValidAtomName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => return false,
        }
    }
    return true;
}

/// Glob patterns for `retract_assumptions`: same charset as atom names plus
/// the wildcards `*` and `?`. First character may also be a wildcard (a
/// bare `*` must match everything).
pub fn isValidGlobPattern(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    const first = pattern[0];
    const first_ok = (first >= 'a' and first <= 'z') or first == '*' or first == '?';
    if (!first_ok) return false;
    for (pattern[1..]) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '*', '?' => {},
            else => return false,
        }
    }
    return true;
}

test "isValidAtomName accepts lowercase letters, digits, underscores" {
    try std.testing.expect(isValidAtomName("baseline"));
    try std.testing.expect(isValidAtomName("hyp_1"));
    try std.testing.expect(isValidAtomName("aB_9"));
}

test "isValidAtomName rejects empty, uppercase-start, and special chars" {
    try std.testing.expect(!isValidAtomName(""));
    try std.testing.expect(!isValidAtomName("Baseline"));
    try std.testing.expect(!isValidAtomName("_leading"));
    try std.testing.expect(!isValidAtomName("1bad"));
    try std.testing.expect(!isValidAtomName("x),assert(evil(1))"));
    try std.testing.expect(!isValidAtomName("has space"));
    try std.testing.expect(!isValidAtomName("has-dash"));
}

test "isValidGlobPattern accepts atoms and wildcards" {
    try std.testing.expect(isValidGlobPattern("hyp_*"));
    try std.testing.expect(isValidGlobPattern("*"));
    try std.testing.expect(isValidGlobPattern("?"));
    try std.testing.expect(isValidGlobPattern("session?_*"));
    try std.testing.expect(isValidGlobPattern("a"));
}

test "isValidGlobPattern rejects injection characters" {
    try std.testing.expect(!isValidGlobPattern(""));
    try std.testing.expect(!isValidGlobPattern("x),assert(evil)"));
    try std.testing.expect(!isValidGlobPattern("bad space"));
    try std.testing.expect(!isValidGlobPattern("Uppercase"));
    try std.testing.expect(!isValidGlobPattern("-dash"));
}

pub fn parseBoolArg(obj: std.json.ObjectMap, key: []const u8, default_val: bool) bool {
    const val = obj.get(key) orelse return default_val;
    return switch (val) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "true"),
        else => default_val,
    };
}

test "parseBoolArg returns default when key missing" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(parseBoolArg(map, "missing", true));
    try std.testing.expect(!parseBoolArg(map, "missing", false));
}

test "parseBoolArg handles bool true value" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .bool = true });
    try std.testing.expect(parseBoolArg(map, "flag", false));
}

test "parseBoolArg handles bool false value" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .bool = false });
    try std.testing.expect(!parseBoolArg(map, "flag", true));
}

test "parseBoolArg handles string true value" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .string = "true" });
    try std.testing.expect(parseBoolArg(map, "flag", false));
}

test "parseBoolArg handles string false value as false" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .string = "false" });
    try std.testing.expect(!parseBoolArg(map, "flag", true));
}

test "parseBoolArg returns default for non-bool non-string values" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("flag", .{ .integer = 1 });
    try std.testing.expect(parseBoolArg(map, "flag", true));
    try std.testing.expect(!parseBoolArg(map, "flag", false));
}
