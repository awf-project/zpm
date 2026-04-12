const std = @import("std");
const Engine = @import("../prolog/engine.zig").Engine;

var mutex = std.Thread.Mutex{};
var engine: ?*Engine = null;

pub fn setEngine(e: *Engine) void {
    mutex.lock();
    defer mutex.unlock();
    engine = e;
}

pub fn clearEngine() void {
    mutex.lock();
    defer mutex.unlock();
    engine = null;
}

pub fn getEngine() ?*Engine {
    mutex.lock();
    defer mutex.unlock();
    return engine;
}

test "getEngine returns null before setEngine is called" {
    clearEngine();
    try std.testing.expectEqual(@as(?*Engine, null), getEngine());
}

test "getEngine returns engine pointer after setEngine is called" {
    clearEngine();
    defer clearEngine();
    var dummy: Engine = undefined;
    setEngine(&dummy);
    const result = getEngine();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(&dummy, result.?);
}
