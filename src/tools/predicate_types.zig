const std = @import("std");
const engine_mod = @import("../prolog/engine.zig");

const Term = engine_mod.Term;

pub const RuleRef = struct {
    head: []const u8,
    body: []const u8,
    memory: []const u8,
};

pub const AssumptionRef = struct {
    assumption: []const u8,
    fact: []const u8,
    memory: []const u8,
};

pub const CrossMemoryRef = struct {
    head: []const u8,
    body: []const u8,
    /// The memory segment that owns the referencing rule (the segment being scanned).
    memory: []const u8,
    /// The module qualifier used in the cross-memory call (e.g. "default", "tasks").
    qualifier: []const u8,
};

// Trealla automatically wraps any module-qualified call with an extra `user:`
// prefix: `default:f(X)` becomes `:(user, :(default, f(X)))`. We skip the
// `user` qualifier (Trealla's internal current-module marker) so that each
// user-written qualifier produces exactly one entry.
pub fn detectCrossMemoryRefs(
    allocator: std.mem.Allocator,
    body: Term,
    target_functor: []const u8,
    target_arity: ?i64,
    head_str: []const u8,
    body_str: []const u8,
    owner_segment: []const u8,
    out: *std.ArrayList(CrossMemoryRef),
) !void {
    switch (body) {
        .compound => |c| {
            if (std.mem.eql(u8, c.functor, ":") and c.args.len == 2) {
                switch (c.args[0]) {
                    .atom => |mod_name| {
                        // Skip the `user` module: Trealla adds it automatically as
                        // a wrapper around any module-qualified call. It is not a
                        // user-defined segment name and would produce a spurious
                        // duplicate entry alongside the real qualifier beneath it.
                        if (!std.mem.eql(u8, mod_name, "user")) {
                            if (bodyContainsTarget(c.args[1], target_functor, target_arity)) {
                                const qualifier_str = try allocator.dupe(u8, mod_name);
                                errdefer allocator.free(qualifier_str);
                                const mem_str = try allocator.dupe(u8, owner_segment);
                                errdefer allocator.free(mem_str);
                                const head_copy = try allocator.dupe(u8, head_str);
                                errdefer allocator.free(head_copy);
                                const body_copy = try allocator.dupe(u8, body_str);
                                errdefer allocator.free(body_copy);
                                try out.append(allocator, .{
                                    .head = head_copy,
                                    .body = body_copy,
                                    .memory = mem_str,
                                    .qualifier = qualifier_str,
                                });
                            }
                        }
                        try detectCrossMemoryRefs(allocator, c.args[1], target_functor, target_arity, head_str, body_str, owner_segment, out);
                        return;
                    },
                    else => {},
                }
            }
            for (c.args) |arg| {
                try detectCrossMemoryRefs(allocator, arg, target_functor, target_arity, head_str, body_str, owner_segment, out);
            }
        },
        .list => |items| {
            for (items) |item| {
                try detectCrossMemoryRefs(allocator, item, target_functor, target_arity, head_str, body_str, owner_segment, out);
            }
        },
        else => {},
    }
}

pub fn bodyContainsTarget(body: Term, target_functor: []const u8, target_arity: ?i64) bool {
    return switch (body) {
        .atom => |s| blk: {
            if (!std.mem.eql(u8, s, target_functor)) break :blk false;
            break :blk if (target_arity) |a| a == 0 else true;
        },
        .compound => |c| blk: {
            const arity: i64 = @intCast(c.args.len);
            if (std.mem.eql(u8, c.functor, target_functor)) {
                if (target_arity == null or target_arity.? == arity) break :blk true;
            }
            for (c.args) |arg| {
                if (bodyContainsTarget(arg, target_functor, target_arity)) break :blk true;
            }
            break :blk false;
        },
        .list => |items| blk: {
            for (items) |item| {
                if (bodyContainsTarget(item, target_functor, target_arity)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

test "bodyContainsTarget returns true when target atom matches at arity null" {
    const t: Term = .{ .atom = "foo" };
    try std.testing.expect(bodyContainsTarget(t, "foo", null));
}

test "bodyContainsTarget returns true when target atom matches at arity 0" {
    const t: Term = .{ .atom = "foo" };
    try std.testing.expect(bodyContainsTarget(t, "foo", 0));
}

test "bodyContainsTarget returns false when different functor in atom" {
    const t: Term = .{ .atom = "bar" };
    try std.testing.expect(!bodyContainsTarget(t, "foo", null));
}

test "bodyContainsTarget returns false when same functor but wrong arity" {
    var arg = [_]Term{.{ .atom = "x" }};
    const t: Term = .{ .compound = .{ .functor = "foo", .args = &arg } };
    try std.testing.expect(!bodyContainsTarget(t, "foo", 2));
}

test "bodyContainsTarget returns true when compound matches functor and arity" {
    var arg = [_]Term{.{ .atom = "x" }};
    const t: Term = .{ .compound = .{ .functor = "foo", .args = &arg } };
    try std.testing.expect(bodyContainsTarget(t, "foo", 1));
}

test "bodyContainsTarget finds target nested in compound args" {
    var inner_arg = [_]Term{.{ .atom = "x" }};
    var inner = [_]Term{.{ .compound = .{ .functor = "target", .args = &inner_arg } }};
    const outer: Term = .{ .compound = .{ .functor = "wrapper", .args = &inner } };
    try std.testing.expect(bodyContainsTarget(outer, "target", 1));
    try std.testing.expect(!bodyContainsTarget(outer, "target", 2));
}

test "bodyContainsTarget finds target inside list" {
    var item_arg = [_]Term{.{ .atom = "x" }};
    var items = [_]Term{.{ .compound = .{ .functor = "target", .args = &item_arg } }};
    const t: Term = .{ .list = &items };
    try std.testing.expect(bodyContainsTarget(t, "target", 1));
    try std.testing.expect(!bodyContainsTarget(t, "other", null));
}

test "RuleRef instantiation has correct fields" {
    const rule: RuleRef = .{
        .head = "foo(_,_)",
        .body = "bar(X), baz(X)",
        .memory = "default",
    };
    try std.testing.expectEqualStrings("foo(_,_)", rule.head);
    try std.testing.expectEqualStrings("bar(X), baz(X)", rule.body);
    try std.testing.expectEqualStrings("default", rule.memory);
}

test "AssumptionRef instantiation has correct fields" {
    const ref: AssumptionRef = .{
        .assumption = "hyp_1",
        .fact = "goal(data)",
        .memory = "default",
    };
    try std.testing.expectEqualStrings("hyp_1", ref.assumption);
    try std.testing.expectEqualStrings("goal(data)", ref.fact);
    try std.testing.expectEqualStrings("default", ref.memory);
}

test "CrossMemoryRef instantiation has correct fields" {
    const ref: CrossMemoryRef = .{
        .head = "wrapper(_)",
        .body = "tasks:worker(X)",
        .memory = "default",
        .qualifier = "tasks",
    };
    try std.testing.expectEqualStrings("wrapper(_)", ref.head);
    try std.testing.expectEqualStrings("tasks:worker(X)", ref.body);
    try std.testing.expectEqualStrings("default", ref.memory);
    try std.testing.expectEqualStrings("tasks", ref.qualifier);
}

test "detectCrossMemoryRefs finds cross-memory ref in compound with colon functor" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(CrossMemoryRef) = .empty;
    defer {
        for (out.items) |item| {
            allocator.free(item.head);
            allocator.free(item.body);
            allocator.free(item.memory);
            allocator.free(item.qualifier);
        }
        out.deinit(allocator);
    }

    var target_arg = [_]Term{.{ .atom = "x" }};
    var colon_args = [_]Term{
        .{ .atom = "tasks" },
        .{ .compound = .{ .functor = "target", .args = &target_arg } },
    };
    const body: Term = .{ .compound = .{ .functor = ":", .args = &colon_args } };

    try detectCrossMemoryRefs(allocator, body, "target", 1, "wrapper(_)", "tasks:target(X)", "default", &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("tasks", out.items[0].qualifier);
    try std.testing.expectEqualStrings("default", out.items[0].memory);
}

test "detectCrossMemoryRefs skips user module qualifier" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(CrossMemoryRef) = .empty;
    defer {
        for (out.items) |item| {
            allocator.free(item.head);
            allocator.free(item.body);
            allocator.free(item.memory);
            allocator.free(item.qualifier);
        }
        out.deinit(allocator);
    }

    var target_arg = [_]Term{.{ .atom = "x" }};
    var colon_args = [_]Term{
        .{ .atom = "user" },
        .{ .compound = .{ .functor = "target", .args = &target_arg } },
    };
    const body: Term = .{ .compound = .{ .functor = ":", .args = &colon_args } };

    try detectCrossMemoryRefs(allocator, body, "target", 1, "wrapper(_)", "user:target(X)", "default", &out);

    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "detectCrossMemoryRefs handles non-compound bodies" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(CrossMemoryRef) = .empty;
    defer {
        for (out.items) |item| {
            allocator.free(item.head);
            allocator.free(item.body);
            allocator.free(item.memory);
            allocator.free(item.qualifier);
        }
        out.deinit(allocator);
    }

    const body: Term = .{ .atom = "simple_atom" };
    try detectCrossMemoryRefs(allocator, body, "target", null, "test_head", "test_body", "default", &out);

    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "detectCrossMemoryRefs finds module-qualified call with null arity" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(CrossMemoryRef) = .empty;
    defer {
        for (out.items) |item| {
            allocator.free(item.head);
            allocator.free(item.body);
            allocator.free(item.memory);
            allocator.free(item.qualifier);
        }
        out.deinit(allocator);
    }

    var inner_arg = [_]Term{.{ .atom = "x" }};
    var colon_args = [_]Term{
        .{ .atom = "mymodule" },
        .{ .compound = .{ .functor = "target", .args = &inner_arg } },
    };
    const body: Term = .{ .compound = .{ .functor = ":", .args = &colon_args } };

    try detectCrossMemoryRefs(allocator, body, "target", null, "test_head", "test_body", "default", &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("mymodule", out.items[0].qualifier);
    try std.testing.expectEqualStrings("default", out.items[0].memory);
}

test "detectCrossMemoryRefs finds nothing when target not in body" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(CrossMemoryRef) = .empty;
    defer {
        for (out.items) |item| {
            allocator.free(item.head);
            allocator.free(item.body);
            allocator.free(item.memory);
            allocator.free(item.qualifier);
        }
        out.deinit(allocator);
    }

    var other_arg = [_]Term{.{ .atom = "x" }};
    var colon_args = [_]Term{
        .{ .atom = "tasks" },
        .{ .compound = .{ .functor = "other", .args = &other_arg } },
    };
    const body: Term = .{ .compound = .{ .functor = ":", .args = &colon_args } };

    try detectCrossMemoryRefs(allocator, body, "target", 1, "wrapper(_)", "tasks:other(X)", "default", &out);

    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
