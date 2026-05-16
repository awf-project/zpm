const std = @import("std");
const MemoryScope = @import("../memory/registry.zig").MemoryScope;
const MemoryMode = @import("../memory/registry.zig").MemoryMode;
const MemoryError = @import("../memory/registry.zig").MemoryError;
const isValidAtomName = @import("../tools/validation.zig").isValidAtomName;

pub const ManifestStatus = enum {
    active,
};

pub const ManifestError = error{
    ParseFailed,
    CorruptFile,
    WriteError,
    NotFound,
    NotWritable,
};

pub const ManifestEntry = struct {
    name: []const u8,
    path: []const u8,
    scope: MemoryScope,
    mode: MemoryMode,
};

const ManifestEntryJson = struct {
    name: []const u8,
    path: []const u8,
    scope: []const u8,
    mode: []const u8,
};

const ManifestFileJson = struct {
    version: u32,
    mounts: []const ManifestEntryJson,
};

var atomic_counter = std.atomic.Value(u32).init(0);

fn scopeTag(scope: MemoryScope) []const u8 {
    return switch (scope) {
        .project => "project",
        .global => "global",
    };
}

pub fn parseScope(s: []const u8) ?MemoryScope {
    if (std.mem.eql(u8, s, "project")) return .project;
    if (std.mem.eql(u8, s, "global")) return .global;
    return null;
}

fn modeTag(mode: MemoryMode) []const u8 {
    return switch (mode) {
        .rw => "rw",
        .ro => "ro",
    };
}

fn parseMode(s: []const u8) ?MemoryMode {
    if (std.mem.eql(u8, s, "rw")) return .rw;
    if (std.mem.eql(u8, s, "ro")) return .ro;
    return null;
}

pub const MountManifest = struct {
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    entries: std.ArrayList(ManifestEntry),
    status: ManifestStatus,

    pub fn init(allocator: std.mem.Allocator, manifest_path: []const u8) !MountManifest {
        const owned_path = try allocator.dupe(u8, manifest_path);
        errdefer allocator.free(owned_path);

        return .{
            .allocator = allocator,
            .manifest_path = owned_path,
            .entries = .empty,
            .status = .active,
        };
    }

    pub fn read(allocator: std.mem.Allocator, manifest_path: []const u8) (ManifestError || error{OutOfMemory})!MountManifest {
        const content = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return init(allocator, manifest_path),
            error.OutOfMemory => return error.OutOfMemory,
            else => return ManifestError.ParseFailed,
        };
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
            return ManifestError.ParseFailed;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return ManifestError.CorruptFile,
        };

        const version_val = root.get("version") orelse return ManifestError.CorruptFile;
        const version: i64 = switch (version_val) {
            .integer => |i| i,
            else => return ManifestError.CorruptFile,
        };
        if (version != 1) return ManifestError.CorruptFile;

        const mounts_val = root.get("mounts") orelse return ManifestError.CorruptFile;
        const mounts_arr = switch (mounts_val) {
            .array => |a| a,
            else => return ManifestError.CorruptFile,
        };

        var manifest = try init(allocator, manifest_path);
        errdefer manifest.deinit();

        for (mounts_arr.items) |item| {
            const entry_obj = switch (item) {
                .object => |o| o,
                else => return ManifestError.CorruptFile,
            };

            const name = switch (entry_obj.get("name") orelse return ManifestError.CorruptFile) {
                .string => |s| s,
                else => return ManifestError.CorruptFile,
            };
            if (!isValidAtomName(name)) return ManifestError.CorruptFile;

            const path = switch (entry_obj.get("path") orelse return ManifestError.CorruptFile) {
                .string => |s| s,
                else => return ManifestError.CorruptFile,
            };

            const scope_str = switch (entry_obj.get("scope") orelse return ManifestError.CorruptFile) {
                .string => |s| s,
                else => return ManifestError.CorruptFile,
            };
            const scope = parseScope(scope_str) orelse return ManifestError.CorruptFile;

            const mode_str = switch (entry_obj.get("mode") orelse return ManifestError.CorruptFile) {
                .string => |s| s,
                else => return ManifestError.CorruptFile,
            };
            const mode = parseMode(mode_str) orelse return ManifestError.CorruptFile;

            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const owned_path = try allocator.dupe(u8, path);
            errdefer allocator.free(owned_path);

            try manifest.entries.append(allocator, .{
                .name = owned_name,
                .path = owned_path,
                .scope = scope,
                .mode = mode,
            });
        }

        return manifest;
    }

    pub fn write(self: *MountManifest) ManifestError!void {
        const pid = std.c.getpid();
        const counter = atomic_counter.fetchAdd(1, .monotonic);

        var temp_path_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        const temp_path = std.fmt.bufPrint(
            &temp_path_buf,
            "{s}.tmp-{d}-{d}",
            .{ self.manifest_path, pid, counter },
        ) catch return ManifestError.WriteError;

        const entries_json = self.allocator.alloc(ManifestEntryJson, self.entries.items.len) catch return ManifestError.WriteError;
        defer self.allocator.free(entries_json);
        for (self.entries.items, 0..) |entry, i| {
            entries_json[i] = .{
                .name = entry.name,
                .path = entry.path,
                .scope = scopeTag(entry.scope),
                .mode = modeTag(entry.mode),
            };
        }

        var aw: std.io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        std.json.Stringify.value(
            ManifestFileJson{ .version = 1, .mounts = entries_json },
            .{ .whitespace = .indent_2 },
            &aw.writer,
        ) catch return ManifestError.WriteError;

        const buf = aw.toOwnedSlice() catch return ManifestError.WriteError;
        defer self.allocator.free(buf);

        const file = std.fs.cwd().createFile(temp_path, .{}) catch return ManifestError.WriteError;
        errdefer std.fs.cwd().deleteFile(temp_path) catch {};

        file.writeAll(buf) catch {
            file.close();
            return ManifestError.WriteError;
        };
        file.sync() catch {
            file.close();
            return ManifestError.WriteError;
        };
        file.close();

        std.fs.cwd().rename(temp_path, self.manifest_path) catch return ManifestError.WriteError;
    }

    pub fn addEntry(self: *MountManifest, entry: ManifestEntry) (MemoryError || ManifestError || error{OutOfMemory})!void {
        if (!isValidAtomName(entry.name)) return MemoryError.InvalidName;

        for (self.entries.items) |*existing| {
            if (std.mem.eql(u8, existing.name, entry.name)) {
                const new_path = try self.allocator.dupe(u8, entry.path);
                self.allocator.free(existing.path);
                existing.path = new_path;
                existing.scope = entry.scope;
                existing.mode = entry.mode;
                return;
            }
        }

        const owned_name = try self.allocator.dupe(u8, entry.name);
        errdefer self.allocator.free(owned_name);
        const owned_path = try self.allocator.dupe(u8, entry.path);
        errdefer self.allocator.free(owned_path);

        try self.entries.append(self.allocator, .{
            .name = owned_name,
            .path = owned_path,
            .scope = entry.scope,
            .mode = entry.mode,
        });
    }

    pub fn removeEntry(self: *MountManifest, name: []const u8) void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                const removed = self.entries.orderedRemove(i);
                self.allocator.free(removed.name);
                self.allocator.free(removed.path);
                return;
            }
        }
    }

    pub fn updateMode(self: *MountManifest, name: []const u8, mode: MemoryMode) ManifestError!void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.mode = mode;
                return;
            }
        }
        return ManifestError.NotFound;
    }

    pub fn findEntry(self: *const MountManifest, name: []const u8) ?*const ManifestEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    pub fn deinit(self: *MountManifest) void {
        self.allocator.free(self.manifest_path);
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }
        self.entries.deinit(self.allocator);
    }
};

test "MountManifest.init returns empty manifest without touching disk" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nonexistent/mounts.json";

    var manifest = try MountManifest.init(allocator, path);
    defer manifest.deinit();

    try std.testing.expectEqual(@as(usize, 0), manifest.entries.items.len);
    try std.testing.expectEqual(ManifestStatus.active, manifest.status);
}

test "MountManifest.read returns empty manifest on FileNotFound" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "nonexistent/mounts.json" });
    defer allocator.free(path);

    var manifest = try MountManifest.read(allocator, path);
    defer manifest.deinit();

    try std.testing.expectEqual(@as(usize, 0), manifest.entries.items.len);
}

test "MountManifest.read returns ManifestError.ParseFailed on malformed JSON" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "mounts.json",
        .data = "{ invalid json }",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mounts.json" });
    defer allocator.free(path);

    const result = MountManifest.read(allocator, path);
    try std.testing.expectError(ManifestError.ParseFailed, result);
}

test "MountManifest.read returns ManifestError.CorruptFile on missing version" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "mounts.json",
        .data = "{\"mounts\": []}",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mounts.json" });
    defer allocator.free(path);

    const result = MountManifest.read(allocator, path);
    try std.testing.expectError(ManifestError.CorruptFile, result);
}

test "MountManifest.read returns ManifestError.CorruptFile on wrong version" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "mounts.json",
        .data = "{\"version\": 2, \"mounts\": []}",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mounts.json" });
    defer allocator.free(path);

    const result = MountManifest.read(allocator, path);
    try std.testing.expectError(ManifestError.CorruptFile, result);
}

test "MountManifest.read returns ManifestError.CorruptFile on missing mounts field" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "mounts.json",
        .data = "{\"version\": 1}",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mounts.json" });
    defer allocator.free(path);

    const result = MountManifest.read(allocator, path);
    try std.testing.expectError(ManifestError.CorruptFile, result);
}

test "MountManifest.write produces JSON with version 1 and mounts envelope" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mounts.json" });
    defer allocator.free(path);

    var manifest = try MountManifest.init(allocator, path);
    defer manifest.deinit();

    const entry = ManifestEntry{
        .name = "default",
        .path = ".zpm/kb/default",
        .scope = .project,
        .mode = .rw,
    };
    try manifest.addEntry(entry);
    try manifest.write();

    const written = try tmp_dir.dir.readFileAlloc(allocator, "mounts.json", 4096);
    defer allocator.free(written);

    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"version\": 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"mounts\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"default\""));
}

test "MountManifest.write performs atomic temp file and rename" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mounts.json" });
    defer allocator.free(path);

    var manifest = try MountManifest.init(allocator, path);
    defer manifest.deinit();

    try manifest.write();

    // Zig 0.15 requires the dir be opened with .iterate = true to use lseek_SET
    var iterable_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });
    defer iterable_dir.close();

    var iter = iterable_dir.iterate();
    var found_final = false;
    var found_temp = false;
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "mounts.json")) {
            found_final = true;
        }
        if (std.mem.startsWith(u8, entry.name, "mounts.json.tmp-")) {
            found_temp = true;
        }
    }

    try std.testing.expect(found_final);
    try std.testing.expect(!found_temp);
}

test "MountManifest round-trip: write then read returns equal entries" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mounts.json" });
    defer allocator.free(path);

    var m1 = try MountManifest.init(allocator, path);
    const entry = ManifestEntry{
        .name = "default",
        .path = ".zpm/kb/default",
        .scope = .project,
        .mode = .rw,
    };
    try m1.addEntry(entry);
    try m1.write();
    m1.deinit();

    var m2 = try MountManifest.read(allocator, path);
    defer m2.deinit();

    try std.testing.expectEqual(@as(usize, 1), m2.entries.items.len);
    try std.testing.expectEqualStrings("default", m2.entries.items[0].name);
    try std.testing.expectEqualStrings(".zpm/kb/default", m2.entries.items[0].path);
    try std.testing.expectEqual(MemoryScope.project, m2.entries.items[0].scope);
    try std.testing.expectEqual(MemoryMode.rw, m2.entries.items[0].mode);
}

test "MountManifest.addEntry rejects invalid atom names with MemoryError.InvalidName" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");
    defer manifest.deinit();

    const invalid_names = [_][]const u8{
        "",
        "InvalidStart",
        "_underscore",
        "1digit",
        "has-dash",
        "has space",
    };

    for (invalid_names) |name| {
        const entry = ManifestEntry{
            .name = name,
            .path = "/tmp/path",
            .scope = .project,
            .mode = .rw,
        };
        const result = manifest.addEntry(entry);
        try std.testing.expectError(MemoryError.InvalidName, result);
    }
}

test "MountManifest.addEntry upserts: replaces existing entry by name without increasing len" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");
    defer manifest.deinit();

    const entry1 = ManifestEntry{
        .name = "default",
        .path = ".zpm/kb/default",
        .scope = .project,
        .mode = .rw,
    };
    try manifest.addEntry(entry1);
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);

    const entry2 = ManifestEntry{
        .name = "default",
        .path = ".zpm/kb/default2",
        .scope = .project,
        .mode = .ro,
    };
    try manifest.addEntry(entry2);
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);
    try std.testing.expectEqual(MemoryMode.ro, manifest.entries.items[0].mode);
}

test "MountManifest.addEntry duplicates name and path strings" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");
    defer manifest.deinit();

    var name_buf: [32]u8 = undefined;
    var path_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "test_entry", .{});
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/test_path", .{});

    const entry = ManifestEntry{
        .name = name,
        .path = path,
        .scope = .project,
        .mode = .rw,
    };

    try manifest.addEntry(entry);

    const stored_entry = manifest.entries.items[0];
    try std.testing.expect(stored_entry.name.ptr != name.ptr);
    try std.testing.expect(stored_entry.path.ptr != path.ptr);
    try std.testing.expectEqualStrings(name, stored_entry.name);
    try std.testing.expectEqualStrings(path, stored_entry.path);
}

test "MountManifest.removeEntry removes matching entry or is no-op" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");
    defer manifest.deinit();

    const entry = ManifestEntry{
        .name = "test",
        .path = "/tmp/path",
        .scope = .project,
        .mode = .rw,
    };
    try manifest.addEntry(entry);
    try std.testing.expectEqual(@as(usize, 1), manifest.entries.items.len);

    manifest.removeEntry("test");
    try std.testing.expectEqual(@as(usize, 0), manifest.entries.items.len);

    manifest.removeEntry("nonexistent");
    try std.testing.expectEqual(@as(usize, 0), manifest.entries.items.len);
}

test "MountManifest.updateMode returns NotFound for unknown name" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");
    defer manifest.deinit();

    const result = manifest.updateMode("nonexistent", .rw);
    try std.testing.expectError(ManifestError.NotFound, result);
}

test "MountManifest.updateMode updates mode for existing entry" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");
    defer manifest.deinit();

    const entry = ManifestEntry{
        .name = "test",
        .path = "/tmp/path",
        .scope = .project,
        .mode = .rw,
    };
    try manifest.addEntry(entry);
    try std.testing.expectEqual(MemoryMode.rw, manifest.entries.items[0].mode);

    try manifest.updateMode("test", .ro);
    try std.testing.expectEqual(MemoryMode.ro, manifest.entries.items[0].mode);
}

test "MountManifest.findEntry returns read-only lookup or null" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");
    defer manifest.deinit();

    const result1 = manifest.findEntry("nonexistent");
    try std.testing.expectEqual(@as(?*const ManifestEntry, null), result1);

    const entry = ManifestEntry{
        .name = "test",
        .path = "/tmp/path",
        .scope = .project,
        .mode = .rw,
    };
    try manifest.addEntry(entry);

    const result2 = manifest.findEntry("test");
    try std.testing.expect(result2 != null);
    if (result2) |e| {
        try std.testing.expectEqualStrings("test", e.name);
    }
}

test "MountManifest.deinit frees all allocations without leaks" {
    const allocator = std.testing.allocator;
    var manifest = try MountManifest.init(allocator, "/tmp/mounts.json");

    const entries = [_]ManifestEntry{
        .{ .name = "a", .path = "/a", .scope = .project, .mode = .rw },
        .{ .name = "b", .path = "/b", .scope = .global, .mode = .ro },
    };

    for (entries) |e| {
        try manifest.addEntry(e);
    }

    manifest.deinit();
}
