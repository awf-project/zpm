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
    /// Each named segment owns a dedicated Prolog engine. Facts are stored
    /// UNQUALIFIED in this engine (no `mod:` prefix), which is what makes
    /// `clear_context`/`retractAll` on a segment work — Trealla cannot retract
    /// module-qualified clauses (zpm #54 / B001), so isolation comes from
    /// separate engines, not separate modules in one shared engine. The
    /// `default` entry is the exception: it references the global engine and
    /// does NOT own it (`owns_engine = false`), so its lifetime stays with the
    /// bootstrap Context.
    engine: *Engine,
    owns_engine: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MemoryEntry) void {
        self.pm.deinit();
        if (self.owns_engine) self.engine.deinit();
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

    pub fn create(_: *MemoryRegistry, io: std.Io, name: []const u8, disk_path: []const u8) !void {
        if (!isValidAtomName(name)) return MemoryError.InvalidName;

        std.Io.Dir.cwd().createDir(io, disk_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => return MemoryError.AlreadyExists,
            else => return err,
        };

        var dir = try std.Io.Dir.openDirAbsolute(io, disk_path, .{});
        defer dir.close(io);

        // Per-segment engines store clauses UNQUALIFIED (B001 / zpm #54).
        // No :- module(...) directive: each segment owns a dedicated engine,
        // so module isolation is engine-level, not Prolog-module-level.
        // A :- module(...) directive would cause Trealla to module-qualify facts
        // loaded from the file, making retractAll on unqualified patterns miss them.
        const file = try dir.createFile(io, "knowledge.pl", .{});
        file.close(io);
    }

    /// Mount a named segment. The registry creates a dedicated engine for the
    /// segment and loads its knowledge.pl + journal into it. The caller no
    /// longer supplies a shared engine — see MemoryEntry.engine.
    pub fn mount(
        self: *MemoryRegistry,
        name: []const u8,
        disk_path: []const u8,
        scope: MemoryScope,
        mode: MemoryMode,
        io: std.Io,
    ) !void {
        if (self.mounted.contains(name)) return MemoryError.AlreadyMounted;
        if (!isValidAtomName(name)) return MemoryError.InvalidName;

        const owned_key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_key);

        const owned_path = try self.allocator.dupe(u8, disk_path);
        errdefer self.allocator.free(owned_path);

        const engine = try Engine.init(.{}, io);
        errdefer engine.deinit();

        // Segments co-locate WAL and snapshots in their own directory, so
        // data_dir and snapshot_dir are both disk_path. The default memory
        // splits them (see context.default_memory_name) for bootstrap parity.
        var pm = try PersistenceManager.init(self.allocator, disk_path, disk_path, io);
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
            .engine = engine,
            .owns_engine = true,
            .allocator = self.allocator,
        });
    }

    /// Mount the `default` memory against the already-initialized global engine.
    /// The default entry references that engine WITHOUT owning it (bootstrap has
    /// already loaded the KB and restored the WAL into it), so `deinit` must not
    /// destroy it. Used only by bootstrap for the `default` entry.
    ///
    /// INVARIANT: `name` must be `"default"`. Calling this for any other segment
    /// would silently mount it with an empty KB (no `loadFile`/`pm.restore`) and
    /// a non-owned foreign engine — both incorrect. Use `mount()` for named
    /// segments. The assert below enforces this at debug time; callers that need
    /// to be extended to support other names must convert to `mount()` instead.
    pub fn mountShared(
        self: *MemoryRegistry,
        name: []const u8,
        disk_path: []const u8,
        scope: MemoryScope,
        mode: MemoryMode,
        engine: *Engine,
        io: std.Io,
    ) !void {
        // context.default_memory_name == "default"; we avoid importing context
        // here (lower-level module) and use the literal directly.
        std.debug.assert(std.mem.eql(u8, name, "default"));
        if (self.mounted.contains(name)) return MemoryError.AlreadyMounted;
        if (!isValidAtomName(name)) return MemoryError.InvalidName;

        const owned_key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_key);

        const owned_path = try self.allocator.dupe(u8, disk_path);
        errdefer self.allocator.free(owned_path);

        var pm = try PersistenceManager.init(self.allocator, disk_path, disk_path, io);
        errdefer pm.deinit();

        try self.mounted.put(owned_key, .{
            .name = owned_key,
            .scope = scope,
            .mode = mode,
            .disk_path = owned_path,
            .pm = pm,
            .engine = engine,
            .owns_engine = false,
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

    /// Return a pointer to the named entry, or null if not mounted.
    ///
    /// STABILITY: the returned `*MemoryEntry` is a direct pointer into the
    /// StringHashMap backing array. It remains valid only until the next
    /// structural mutation of `self.mounted` (i.e. `mount`, `mountShared`, or
    /// `unmount`). Callers must not hold this pointer across any call that
    /// could trigger a rehash. This is safe in the current MCP server because
    /// all requests are processed sequentially on a single STDIO goroutine —
    /// no concurrent mounts can occur between a `getMounted` call and the
    /// use of its result within the same handler invocation.
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
    try std.testing.expectError(MemoryError.InvalidName, reg.create(std.testing.io, "my-memory", "/tmp/x"));
    try std.testing.expectError(MemoryError.InvalidName, reg.create(std.testing.io, "123abc", "/tmp/x"));
    try std.testing.expectError(MemoryError.InvalidName, reg.create(std.testing.io, "", "/tmp/x"));
}

test "MemoryRegistry.create with valid name creates directory and knowledge.pl" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];
    const mem_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/mymem", .{base});
    defer std.testing.allocator.free(mem_path);

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.create(std.testing.io, "mymem", mem_path);
    var mem_dir = try tmp.dir.openDir(std.testing.io, "mymem", .{});
    defer mem_dir.close(std.testing.io);
    const content = try mem_dir.readFileAlloc(std.testing.io, "knowledge.pl", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(content);
    // Per-segment engines are UNQUALIFIED — no :- module(...) directive (B001 / zpm #54).
    try std.testing.expect(std.mem.indexOf(u8, content, ":- module(") == null);
}

test "MemoryRegistry.create rejects duplicate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];
    const mem_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/dup", .{base});
    defer std.testing.allocator.free(mem_path);

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.create(std.testing.io, "dup", mem_path);
    try std.testing.expectError(MemoryError.AlreadyExists, reg.create(std.testing.io, "dup", mem_path));
}

test "MemoryRegistry.mount and getMounted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("myns", base, .project, .rw, std.testing.io);
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
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("myns", base, .project, .rw, std.testing.io);
    try std.testing.expectError(MemoryError.AlreadyMounted, reg.mount("myns", base, .project, .rw, std.testing.io));
}

test "MemoryRegistry.unmount removes entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("myns", base, .project, .rw, std.testing.io);
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
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("ns1", base, .project, .rw, std.testing.io);
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
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("global_mem", base, .global, .rw, std.testing.io);
    const entry = reg.getMounted("global_mem");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryScope.global, entry.?.scope);
}

test "MemoryRegistry.mount rejects invalid names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expectError(MemoryError.InvalidName, reg.mount("my-invalid", base, .project, .rw, std.testing.io));
    try std.testing.expectError(MemoryError.InvalidName, reg.mount("123bad", base, .project, .rw, std.testing.io));
}

test "MemoryRegistry.mount with read-only mode stores MemoryMode.ro" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.mount("readonly_mem", base, .project, .ro, std.testing.io);
    const entry = reg.getMounted("readonly_mem");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(MemoryMode.ro, entry.?.mode);
}

// B001 / zpm #54: facts loaded from knowledge.pl and facts asserted via the API
// must live in the same namespace so that retractAll clears both.
// Regression guard: if create() emits :- module(...), Trealla module-qualifies
// file-loaded facts and retractAll("foo(_)") silently misses them.
test "MemoryRegistry.create then mount: API-asserted and file-loaded facts are in same namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPathFile(std.testing.io, ".", &path_buf);
    const base = path_buf[0..base_len];
    const mem_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/nstest", .{base});
    defer std.testing.allocator.free(mem_path);

    var reg = MemoryRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // create() writes an empty (no module directive) knowledge.pl
    try reg.create(std.testing.io, "nstest", mem_path);

    // Write a fact directly into knowledge.pl before mounting
    {
        var mem_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, mem_path, .{});
        defer mem_dir.close(std.testing.io);
        const kf = try mem_dir.createFile(std.testing.io, "knowledge.pl", .{});
        defer kf.close(std.testing.io);
        try kf.writeStreamingAll(std.testing.io, ":- dynamic(color/1).\ncolor(red).\n");
    }

    // mount() loads knowledge.pl into the dedicated engine
    try reg.mount("nstest", mem_path, .project, .rw, std.testing.io);
    const seg = reg.getMounted("nstest").?;

    // Assert a second fact via the API (unqualified, same engine)
    try seg.engine.assertFact("color(blue).");

    // Both must be visible in a single query
    var qr_all = try seg.engine.query("color(X)");
    defer qr_all.deinit();
    try std.testing.expectEqual(@as(usize, 2), qr_all.solutions.len);

    // retractAll must clear BOTH (the file-loaded one and the API one)
    try seg.engine.retractAll("color(_)");
    var qr_after = try seg.engine.query("color(X)");
    defer qr_after.deinit();
    try std.testing.expectEqual(@as(usize, 0), qr_after.solutions.len);
}
