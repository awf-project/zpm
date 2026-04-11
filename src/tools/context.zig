const std = @import("std");
const Engine = @import("../prolog/engine.zig").Engine;

var engine: ?*Engine = null;

pub fn setEngine(e: *Engine) void {
    engine = e;
}

pub fn clearEngine() void {
    engine = null;
}

pub fn getEngine() ?*Engine {
    return engine;
}

test "getEngine returns null before setEngine is called" {
    engine = null;
    try std.testing.expectEqual(@as(?*Engine, null), getEngine());
}

test "getEngine returns engine pointer after setEngine is called" {
    engine = null;
    defer engine = null;
    var dummy: Engine = undefined;
    setEngine(&dummy);
    const result = getEngine();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(&dummy, result.?);
}
