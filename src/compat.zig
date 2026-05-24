const std = @import("std");

const InitState = enum(u8) { uninitialized, initializing, done };

var threaded: std.Io.Threaded = undefined;
var state: std.atomic.Value(InitState) = .init(.uninitialized);

pub fn io() std.Io {
    if (state.load(.acquire) == .done) return threaded.io();

    if (state.cmpxchgStrong(.uninitialized, .initializing, .acquire, .monotonic) == null) {
        threaded = .init(std.heap.page_allocator, .{});
        state.store(.done, .release);
        return threaded.io();
    }

    // Another thread is initializing — spin until done.
    while (state.load(.acquire) != .done) std.atomic.spinLoopHint();
    return threaded.io();
}
