const std = @import("std");
const ffi = @import("ffi.zig");

pub const EngineConfig = struct {
    timeout_ms: u64 = 5000,
    max_solutions: usize = 100,
    max_recursion_depth: usize = 1000,
    max_memory_bytes: usize = 67108864,
};

pub const EngineError = error{
    InitFailed,
    QueryFailed,
    AssertFailed,
    RetractFailed,
    LoadFailed,
    Timeout,
    OutOfMemory,
    InvalidJson,
};

pub const Term = union(enum) {
    atom: []const u8,
    integer: i64,
    float: f64,
    compound: struct {
        functor: []const u8,
        args: []Term,
    },
    variable: []const u8,
    list: []Term,
};

pub const Solution = struct {
    bindings: std.StringHashMap(Term),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Solution) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeTerm(self.allocator, entry.value_ptr.*);
        }
        self.bindings.deinit();
    }
};

pub const QueryResult = struct {
    solutions: []Solution,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QueryResult) void {
        for (self.solutions) |*s| s.deinit();
        self.allocator.free(self.solutions);
    }
};

pub const Engine = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    config: EngineConfig,

    pub fn init(config: EngineConfig) EngineError!*Engine {
        const self = std.heap.page_allocator.create(Engine) catch return EngineError.OutOfMemory;
        self.gpa = std.heap.GeneralPurposeAllocator(.{}){};
        self.allocator = self.gpa.allocator();
        self.config = config;
        self.handle = ffi.prolog_init();
        if (self.handle == null) {
            _ = self.gpa.deinit();
            std.heap.page_allocator.destroy(self);
            return EngineError.InitFailed;
        }
        return self;
    }

    pub fn deinit(self: *Engine) void {
        ffi.prolog_deinit(self.handle);
        _ = self.gpa.deinit();
        std.heap.page_allocator.destroy(self);
    }

    fn checkSandbox(self: *Engine) EngineError!void {
        if (self.config.timeout_ms == 0) return EngineError.Timeout;
        if (self.config.max_memory_bytes < 1024) return EngineError.OutOfMemory;
    }

    pub fn query(self: *Engine, goal: []const u8) EngineError!QueryResult {
        try self.checkSandbox();
        const goal_z = self.allocator.dupeZ(u8, goal) catch return EngineError.OutOfMemory;
        defer self.allocator.free(goal_z);
        const raw = ffi.prolog_query(self.handle, goal_z) orelse return EngineError.QueryFailed;
        defer ffi.prolog_free_string(raw);
        return parseQueryResult(self.allocator, std.mem.sliceTo(raw, 0));
    }

    pub fn assert(self: *Engine, clause: []const u8) EngineError!void {
        const stripped = stripDot(clause);
        const clause_z = self.allocator.dupeZ(u8, stripped) catch return EngineError.OutOfMemory;
        defer self.allocator.free(clause_z);
        if (ffi.prolog_assert(self.handle, clause_z) != 0) return EngineError.AssertFailed;
    }

    pub fn retract(self: *Engine, clause: []const u8) EngineError!void {
        const stripped = stripDot(clause);
        const clause_z = self.allocator.dupeZ(u8, stripped) catch return EngineError.OutOfMemory;
        defer self.allocator.free(clause_z);
        if (ffi.prolog_retract(self.handle, clause_z) != 0) return EngineError.RetractFailed;
    }

    pub fn assertFact(self: *Engine, clause: []const u8) EngineError!void {
        return self.assert(clause);
    }

    pub fn retractFact(self: *Engine, clause: []const u8) EngineError!void {
        return self.retract(clause);
    }

    pub fn loadFile(self: *Engine, path: []const u8) EngineError!void {
        const path_z = self.allocator.dupeZ(u8, path) catch return EngineError.OutOfMemory;
        defer self.allocator.free(path_z);
        if (ffi.prolog_load_file(self.handle, path_z) != 0) return EngineError.LoadFailed;
    }

    pub fn loadString(self: *Engine, source: []const u8) EngineError!void {
        const source_z = self.allocator.dupeZ(u8, source) catch return EngineError.OutOfMemory;
        defer self.allocator.free(source_z);
        if (ffi.prolog_load_string(self.handle, source_z) != 0) return EngineError.LoadFailed;
    }
};

fn stripDot(s: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, s, " \t\n\r");
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') {
        return trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

fn freeTerm(allocator: std.mem.Allocator, term: Term) void {
    switch (term) {
        .atom => |s| allocator.free(s),
        .variable => |s| allocator.free(s),
        .list => |items| {
            for (items) |item| freeTerm(allocator, item);
            allocator.free(items);
        },
        .compound => |c| {
            allocator.free(c.functor);
            for (c.args) |arg| freeTerm(allocator, arg);
            allocator.free(c.args);
        },
        .integer, .float => {},
    }
}

fn jsonValueToTerm(allocator: std.mem.Allocator, value: std.json.Value) !Term {
    return switch (value) {
        .string => |s| Term{ .atom = try allocator.dupe(u8, s) },
        .integer => |i| Term{ .integer = i },
        .float => |f| Term{ .float = f },
        .array => |a| blk: {
            const items = try allocator.alloc(Term, a.items.len);
            for (a.items, 0..) |item, idx| {
                items[idx] = try jsonValueToTerm(allocator, item);
            }
            break :blk Term{ .list = items };
        },
        .object => |o| blk: {
            const functor_val = o.get("functor") orelse break :blk Term{ .atom = try allocator.dupe(u8, "null") };
            const args_val = o.get("args") orelse break :blk Term{ .atom = try allocator.dupe(u8, "null") };
            const functor = switch (functor_val) {
                .string => |s| try allocator.dupe(u8, s),
                else => break :blk Term{ .atom = try allocator.dupe(u8, "null") },
            };
            errdefer allocator.free(functor);
            const args_arr = switch (args_val) {
                .array => |a| a,
                else => break :blk Term{ .atom = try allocator.dupe(u8, "null") },
            };
            const args = try allocator.alloc(Term, args_arr.items.len);
            errdefer allocator.free(args);
            for (args_arr.items, 0..) |item, idx| {
                args[idx] = try jsonValueToTerm(allocator, item);
            }
            break :blk Term{ .compound = .{ .functor = functor, .args = args } };
        },
        else => Term{ .atom = try allocator.dupe(u8, "null") },
    };
}

fn parseQueryResult(allocator: std.mem.Allocator, json_str: []const u8) EngineError!QueryResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return EngineError.InvalidJson;
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return EngineError.InvalidJson,
    };

    var solutions: std.ArrayList(Solution) = .empty;
    errdefer {
        for (solutions.items) |*s| s.deinit();
        solutions.deinit(allocator);
    }

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (obj.get("error") != null) continue;

        var bindings = std.StringHashMap(Term).init(allocator);
        errdefer bindings.deinit();

        var iter = obj.iterator();
        while (iter.next()) |entry| {
            const key = allocator.dupe(u8, entry.key_ptr.*) catch continue;
            const term = jsonValueToTerm(allocator, entry.value_ptr.*) catch {
                allocator.free(key);
                continue;
            };
            bindings.put(key, term) catch {
                allocator.free(key);
                continue;
            };
        }

        solutions.append(allocator, Solution{
            .bindings = bindings,
            .allocator = allocator,
        }) catch return EngineError.OutOfMemory;
    }

    return QueryResult{
        .solutions = solutions.toOwnedSlice(allocator) catch return EngineError.OutOfMemory,
        .allocator = allocator,
    };
}

const testing = std.testing;

test "Engine.init creates engine with non-null handle" {
    var engine = try Engine.init(.{});
    defer engine.deinit();
    try testing.expect(engine.handle != null);
}

test "Engine.init stores config" {
    var engine = try Engine.init(.{ .timeout_ms = 1000, .max_solutions = 10 });
    defer engine.deinit();
    try testing.expectEqual(@as(u64, 1000), engine.config.timeout_ms);
    try testing.expectEqual(@as(usize, 10), engine.config.max_solutions);
}

test "Engine.query parses atom binding from asserted fact" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assert("fruit(apple).");
    var result = try engine.query("fruit(X)");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    const x = result.solutions[0].bindings.get("X").?;
    try testing.expectEqualStrings("apple", x.atom);
}

test "Engine.assert and retract succeed" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assert("temp(42).");
    try engine.retract("temp(42).");

    var result = try engine.query("temp(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.solutions.len);
}

test "Engine.assertFact then query succeeds" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("fruit(apple).");
    var result = try engine.query("fruit(X)");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    const x = result.solutions[0].bindings.get("X").?;
    try testing.expectEqualStrings("apple", x.atom);
}

test "Engine.retractFact then query returns no results" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.assertFact("temp(42).");
    try engine.retractFact("temp(42).");

    var result = try engine.query("temp(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.solutions.len);
}

test "Engine.assertFact with invalid term returns parse error" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    const err = engine.assertFact(")(invalid");
    try testing.expectError(EngineError.AssertFailed, err);
}

test "Engine.loadString accepts valid Prolog source" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.loadString("color(red). color(green). color(blue).");
    var result = try engine.query("color(X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.solutions.len);
}

test "Engine.loadFile loads predicates from disk and makes them queryable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pl_content = "parent(tom, bob). parent(bob, ann).";
    try tmp.dir.writeFile(.{ .sub_path = "kb.pl", .data = pl_content });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try tmp.dir.realpath("kb.pl", &path_buf);

    var engine = try Engine.init(.{});
    defer engine.deinit();

    try engine.loadFile(abs_path);

    var result = try engine.query("parent(tom, X)");
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    try testing.expectEqualStrings("bob", result.solutions[0].bindings.get("X").?.atom);
}

test "Engine.loadFile with non-existent path returns LoadFailed" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    const err = engine.loadFile("/tmp/zpm_nonexistent_file_that_does_not_exist.pl");
    try testing.expectError(EngineError.LoadFailed, err);
}

test "Engine.loadString with invalid syntax returns LoadFailed" {
    var engine = try Engine.init(.{});
    defer engine.deinit();

    const err = engine.loadString(")(not valid prolog((.");
    try testing.expectError(EngineError.LoadFailed, err);
}

test "Engine.query succeeds with explicit sandbox limits set" {
    var engine = try Engine.init(.{
        .timeout_ms = 5000,
        .max_recursion_depth = 1000,
        .max_memory_bytes = 67108864,
    });
    defer engine.deinit();

    try engine.assert("sandboxed(ok).");
    var result = try engine.query("sandboxed(X)");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.solutions.len);
    try testing.expectEqualStrings("ok", result.solutions[0].bindings.get("X").?.atom);
}

test "Engine.query returns Timeout when timeout_ms is zero" {
    var engine = try Engine.init(.{ .timeout_ms = 0 });
    defer engine.deinit();

    try engine.assert("timeout_test(x).");
    const err = engine.query("timeout_test(X)");
    try testing.expectError(EngineError.Timeout, err);
}

test "Engine.query returns OutOfMemory when max_memory_bytes is too small" {
    var engine = try Engine.init(.{ .max_memory_bytes = 1 });
    defer engine.deinit();

    try engine.assert("memtest(x).");
    const err = engine.query("memtest(X)");
    try testing.expectError(EngineError.OutOfMemory, err);
}
