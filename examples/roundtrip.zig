const std = @import("std");
const Engine = @import("prolog/engine").Engine;

const print = std.debug.print;

pub fn main() !void {
    var engine = Engine.init(.{}) catch |err| {
        print("Failed to init engine: {}\n", .{err});
        return;
    };
    defer engine.deinit();

    // Insert facts
    const facts = [_][]const u8{
        "parent(tom, bob)",
        "parent(bob, ann)",
        "parent(bob, pat)",
    };
    for (facts) |fact| {
        engine.assert(fact) catch |err| {
            print("assert({s}) -> err: {}\n", .{ fact, err });
            continue;
        };
        print("assert({s}) -> ok\n", .{fact});
    }

    // Query them back
    const queries = [_][]const u8{
        "parent(tom, X)",
        "parent(bob, X)",
        "parent(X, ann)",
        "parent(ann, X)",
    };
    for (queries) |goal| {
        print("\n?- {s}\n", .{goal});
        var result = engine.query(goal) catch |err| {
            print("   error: {}\n", .{err});
            continue;
        };
        defer result.deinit();

        if (result.solutions.len == 0) {
            print("   false.\n", .{});
        } else {
            for (result.solutions) |sol| {
                var it = sol.bindings.iterator();
                while (it.next()) |entry| {
                    const val = entry.value_ptr.*;
                    switch (val) {
                        .atom => |a| print("   {s} = {s}\n", .{ entry.key_ptr.*, a }),
                        .integer => |n| print("   {s} = {d}\n", .{ entry.key_ptr.*, n }),
                        .float => |f| print("   {s} = {d}\n", .{ entry.key_ptr.*, f }),
                        .compound => print("   {s} = <compound>\n", .{entry.key_ptr.*}),
                        .variable => |v| print("   {s} = _{s}\n", .{ entry.key_ptr.*, v }),
                        .list => print("   {s} = <list>\n", .{entry.key_ptr.*}),
                    }
                }
            }
        }
    }
}
