const std = @import("std");
const PersistenceManager = @import("../persistence/manager.zig").PersistenceManager;
const Engine = @import("../prolog/engine.zig").Engine;
const isValidAtomName = @import("../tools/validation.zig").isValidAtomName;

pub const MemoryScope = enum {
    project,
    global,
};

pub const MemoryMode = enum {
    rw,
    ro,
};

pub const MemoryError = error{
    NotFound,
    AlreadyMounted,
    AlreadyExists,
    ReadOnly,
    Ambiguous,
    InvalidName,
    NotMounted,
    DefaultProtected,
};

pub const MemoryEntry = struct {
    name: []const u8,
    scope: MemoryScope,
    mode: MemoryMode,
    disk_path: []const u8,
    pm: PersistenceManager,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MemoryEntry) void {
        self.pm.deinit();
        self.allocator.free(self.disk_path);
        // self.name is the same allocation as the HashMap key;
        // it is freed by MemoryRegistry.deinit via entry.key_ptr.*.
    }
};

pub const MemoryRegistry = struct {
    allocator: std.mem.Allocator,
    mounted: std.StringHashMap(MemoryEntry),

    pub fn init(allocator: std.mem.Allocator) MemoryRegistry {
        return .{
            .allocator = allocator,
            .mounted = std.StringHashMap(MemoryEntry).init(allocator),
        };
    }

    pub fn deinit(self: *MemoryRegistry) void {
        var it = self.mounted.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.mounted.deinit();
    }

    pub fn create(self: *MemoryRegistry, name: []const u8, disk_path: []const u8) !void {
        if (!isValidAtomName(name)) return MemoryError.InvalidName;

        std.fs.makeDirAbsolute(disk_path) catch |err| switch (err) {
            error.PathAlreadyExists => return MemoryError.AlreadyExists,
            else => return err,
        };

        var dir = try std.fs.openDirAbsolute(disk_path, .{});
        defer dir.close();

        const header = try std.fmt.allocPrint(self.allocator, ":- module({s}, []).\n", .{name});
        defer self.allocator.free(header);

        var file = try dir.createFile("knowledge.pl", .{});
        defer file.close();
        try file.writeAll(header);
    }

    pub fn mount(
        self: *MemoryRegistry,
        name: []const u8,
        disk_path: []const u8,
        scope: MemoryScope,
        mode: MemoryMode,
        engine: *Engine,
    ) !void {
        if (self.mounted.contains(name)) return MemoryError.AlreadyMounted;
        if (!isValidAtomName(name)) return MemoryError.InvalidName;

        const owned_key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_key);

        const owned_path = try self.allocator.dupe(u8, disk_path);
        errdefer self.allocator.free(owned_path);

        var pm = try PersistenceManager.init(self.allocator, disk_path, disk_path);
        errdefer pm.deinit();

        {
            const kp = try std.fmt.allocPrint(self.allocator, "{s}/knowledge.pl", .{disk_path});
            defer self.allocator.free(kp);
            engine.loadFile(kp) catch |err| switch (err) {
                error.LoadFailed => {}, // OK: knowledge.pl is optional when mounting a pre-existing dir
                else => return err,
            };
        }

        try pm.restore(engine);

        try self.mounted.put(owned_key, .{
            .name = owned_key,
            .scope = scope,
            .mode = mode,
            .disk_path = owned_path,
            .pm = pm,
            .allocator = self.allocator,
        });
    }

    pub fn unmount(self: *MemoryRegistry, name: []const u8) MemoryError!void {
        if (std.mem.eql(u8, name, "default")) return MemoryError.DefaultProtected;
        const kv = self.mounted.fetchRemove(name) orelse return MemoryError.NotMounted;
        self.allocator.free(kv.key);
        var entry = kv.value;
        entry.deinit();
    }

    pub fn getMounted(self: *MemoryRegistry, name: []const u8) ?*MemoryEntry {
        return self.mounted.getPtr(name);
    }

    pub fn listMounted(self: *MemoryRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        const count = self.mounted.count();
        const names = try allocator.alloc([]const u8, count);
        var built: usize = 0;
        errdefer {
            for (names[0..built]) |n| allocator.free(n);
            allocator.free(names);
        }
        var it = self.mounted.iterator();
        while (it.next()) |entry| {
            names[built] = try allocator.dupe(u8, entry.key_ptr.*);
            built += 1;
        }
        return names;
    }
};

test "MemoryRegistry.init and deinit without leaks" {
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
}

test "MemoryRegistry.getMounted returns null for unknown" {
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(reg.getMounted("unknown") == null);
}

test "MemoryRegistry.create rejects invalid names" {
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectError(MemoryError.InvalidName, reg.create("my-memory", "/tmp/x"));
    try std.testing.expectError(MemoryError.InvalidName, reg.create("123abc", "/tmp/x"));
    try std.testing.expectError(MemoryError.InvalidName, reg.create("", "/tmp/x"));
}

test "MemoryRegistry.create with valid name creates directory and knowledge.pl" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);
    const mem_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/mymem", .{base});
    defer std.testing.allocator.free(mem_path);

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.create("mymem", mem_path);
    var mem_dir = try tmp.dir.openDir("mymem", .{});
    defer mem_dir.close();
    var file = try mem_dir.openFile("knowledge.pl", .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, ":- module(mymem, []).") != null);
}

test "MemoryRegistry.create rejects duplicate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);
    const mem_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dup", .{base});
    defer std.testing.allocator.free(mem_path);

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.create("dup", mem_path);
    try std.testing.expectError(MemoryError.AlreadyExists, reg.create("dup", mem_path));
}

test "MemoryRegistry.mount and getMounted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("myns", base, .project, .rw, engine);
    const entry = reg.getMounted("myns");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("myns", entry.?.name);
    try std.testing.expectEqual(MemoryScope.project, entry.?.scope);
    try std.testing.expectEqual(MemoryMode.rw, entry.?.mode);
}

test "MemoryRegistry.mount rejects already-mounted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("myns", base, .project, .rw, engine);
    try std.testing.expectError(MemoryError.AlreadyMounted, reg.mount("myns", base, .project, .rw, engine));
}

test "MemoryRegistry.unmount removes entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("myns", base, .project, .rw, engine);
    try reg.unmount("myns");
    try std.testing.expect(reg.getMounted("myns") == null);
}

test "MemoryRegistry.unmount rejects default" {
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectError(MemoryError.DefaultProtected, reg.unmount("default"));
}

test "MemoryRegistry.unmount rejects non-mounted" {
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectError(MemoryError.NotMounted, reg.unmount("nonexistent"));
}

test "MemoryRegistry.listMounted returns names of mounted memories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("ns1", base, .project, .rw, engine);
    const names = try reg.listMounted(std.testing.allocator);
    defer {
        for (names) |n| std.testing.allocator.free(n);
        std.testing.allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
}

test "MemoryRegistry.mount with global scope stores MemoryScope.global" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("global_mem", base, .global, .rw, engine);
    const entry = reg.getMounted("global_mem");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryScope.global, entry.?.scope);
}

test "MemoryRegistry.mount rejects invalid names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(MemoryError.InvalidName, reg.mount("my-invalid", base, .project, .rw, engine));
    try std.testing.expectError(MemoryError.InvalidName, reg.mount("123bad", base, .project, .rw, engine));
}

test "MemoryRegistry.mount with read-only mode stores MemoryMode.ro" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &path_buf);

    const engine = try Engine.init(.{});
    defer engine.deinit();
    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("readonly_mem", base, .project, .ro, engine);
    const entry = reg.getMounted("readonly_mem");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryMode.ro, entry.?.mode);
}
