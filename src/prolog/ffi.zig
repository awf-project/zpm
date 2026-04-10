const std = @import("std");

pub extern "C" fn prolog_init() ?*anyopaque;
pub extern "C" fn prolog_deinit(handle: ?*anyopaque) void;
pub extern "C" fn prolog_query(handle: ?*anyopaque, goal: [*:0]const u8) ?[*:0]u8;
pub extern "C" fn prolog_assert(handle: ?*anyopaque, clause: [*:0]const u8) i32;
pub extern "C" fn prolog_retract(handle: ?*anyopaque, clause: [*:0]const u8) i32;
pub extern "C" fn prolog_load_file(handle: ?*anyopaque, path: [*:0]const u8) i32;
pub extern "C" fn prolog_load_string(handle: ?*anyopaque, source: [*:0]const u8) i32;
pub extern "C" fn prolog_free_string(s: ?[*:0]u8) void;

test "prolog_init returns non-null handle" {
    const handle = prolog_init();
    try std.testing.expect(handle != null);
    prolog_deinit(handle);
}

test "prolog_query member/2 returns JSON array with solutions" {
    const handle = prolog_init();
    try std.testing.expect(handle != null);
    defer prolog_deinit(handle);

    const result = prolog_query(handle, "member(X, [a,b,c])");
    try std.testing.expect(result != null);
    defer prolog_free_string(result);

    const json = std.mem.sliceTo(result.?, 0);
    try std.testing.expectStringStartsWith(json, "[");
    try std.testing.expect(json.len > 2);
}

test "prolog_assert succeeds and query finds asserted fact" {
    const handle = prolog_init();
    try std.testing.expect(handle != null);
    defer prolog_deinit(handle);

    const rc = prolog_assert(handle, "test_fact(hello)");
    try std.testing.expectEqual(@as(i32, 0), rc);

    const result = prolog_query(handle, "test_fact(X)");
    try std.testing.expect(result != null);
    defer prolog_free_string(result);

    const json = std.mem.sliceTo(result.?, 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "hello") != null);
}
