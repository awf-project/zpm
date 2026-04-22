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
