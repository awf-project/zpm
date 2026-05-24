const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli");
const version_info = @import("../version.zig");

var channel_slot: Channel = .stable;
var dry_run_slot: bool = false;

pub const UpgradeError = error{
    UnsupportedPlatform,
    NoStableRelease,
    NoRelease,
    ChecksumMismatch,
    ChecksumNotFound,
    SHA256SUMSMissing,
    NetworkError,
    InvalidSelfPath,
};

pub const Channel = enum {
    stable,
    dev,
};

pub fn assetBasename(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) UpgradeError![]const u8 {
    if (os == .macos) return "zpm-darwin-universal";
    if (os == .linux and arch == .x86_64) return "zpm-linux-x86_64";
    if (os == .linux and arch == .aarch64) return "zpm-linux-arm64";
    return UpgradeError.UnsupportedPlatform;
}

pub fn detectPlatform() UpgradeError![]const u8 {
    if (std.c.getenv("ZPM_OVERRIDE_PLATFORM")) |override_raw| {
        const override_val = std.mem.span(override_raw);
        if (std.mem.eql(u8, override_val, "zpm-linux-x86_64")) return "zpm-linux-x86_64";
        if (std.mem.eql(u8, override_val, "zpm-linux-arm64")) return "zpm-linux-arm64";
        if (std.mem.eql(u8, override_val, "zpm-darwin-universal")) return "zpm-darwin-universal";
        return UpgradeError.UnsupportedPlatform;
    }
    return assetBasename(builtin.os.tag, builtin.cpu.arch);
}

pub const ChecksumEntry = struct {
    hash: []const u8,
    filename: []const u8,
};

pub fn parseChecksumLine(line: []const u8) ?ChecksumEntry {
    const sep_idx = std.mem.indexOf(u8, line, "  ") orelse return null;
    const hash = line[0..sep_idx];
    var filename = line[sep_idx + 2 ..];
    if (std.mem.startsWith(u8, filename, "./")) filename = filename[2..];
    if (std.mem.lastIndexOf(u8, filename, "/")) |slash| filename = filename[slash + 1 ..];
    return .{ .hash = hash, .filename = filename };
}

pub fn findChecksumFor(sums_contents: []const u8, target_filename: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums_contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const entry = parseChecksumLine(line) orelse continue;
        if (std.mem.eql(u8, entry.filename, target_filename)) return entry.hash;
    }
    return null;
}

pub fn verifySha256(allocator: std.mem.Allocator, path: []const u8, expected: []const u8, io: std.Io) !void {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(contents);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected)) return UpgradeError.ChecksumMismatch;
}

pub const ReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
    size: u64,
};

pub const Release = struct {
    tag_name: []const u8,
    assets: []const ReleaseAsset,
    published_at: []const u8,
    prerelease: bool,
};

pub const ReleaseClient = struct {
    ptr: *anyopaque,
    fetchLatestFn: *const fn (*anyopaque, Channel) anyerror!Release,
    downloadToFileFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,

    pub fn fetchLatest(self: ReleaseClient, channel: Channel) anyerror!Release {
        return self.fetchLatestFn(self.ptr, channel);
    }

    pub fn downloadToFile(self: ReleaseClient, url: []const u8, dest: []const u8) anyerror!void {
        return self.downloadToFileFn(self.ptr, url, dest);
    }
};

pub const default_api_base = "https://api.github.com/repos/awf-project/zpm";

pub const HttpReleaseClient = struct {
    allocator: std.mem.Allocator,
    api_base: []const u8,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) HttpReleaseClient {
        const api_base = if (std.c.getenv("ZPM_GITHUB_API_URL")) |raw| std.mem.span(raw) else default_api_base;
        return .{
            .allocator = allocator,
            .api_base = api_base,
            .io = io,
        };
    }

    pub fn deinit(self: *HttpReleaseClient) void {
        _ = self;
    }

    fn fetchLatestFn(ptr: *anyopaque, channel: Channel) anyerror!Release {
        const self: *HttpReleaseClient = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;

        const url = try std.fmt.allocPrint(allocator, "{s}/releases", .{self.api_base});
        defer allocator.free(url);

        // Fresh std.http.Client per request — reusing one across requests that
        // each follow a redirect chain causes Zig 0.15.x stdlib to send a
        // malformed header on the second redirect, which Azure rejects with
        // HTTP 400 "Invalid Header".
        var http_client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer http_client.deinit();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const result = try http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = "zpm-upgrade/1.0" },
                .{ .name = "Accept", .value = "application/vnd.github+json" },
            },
        });

        if (result.status != .ok) return UpgradeError.NetworkError;

        const body = aw.written();
        const parsed = try std.json.parseFromSlice(
            []Release,
            allocator,
            body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const selected = try selectRelease(parsed.value, channel);
        return dupeRelease(allocator, selected);
    }

    fn downloadToFileFn(ptr: *anyopaque, url: []const u8, dest: []const u8) anyerror!void {
        const self: *HttpReleaseClient = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;

        var http_client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer http_client.deinit();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const result = try http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = "zpm-upgrade/1.0" },
            },
        });

        if (result.status != .ok) return UpgradeError.NetworkError;

        const file = try std.Io.Dir.cwd().createFile(self.io, dest, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, aw.written());
    }

    pub fn releaseClient(self: *HttpReleaseClient) ReleaseClient {
        return .{
            .ptr = self,
            .fetchLatestFn = fetchLatestFn,
            .downloadToFileFn = downloadToFileFn,
        };
    }
};

pub fn selectRelease(releases: []const Release, channel: Channel) UpgradeError!Release {
    switch (channel) {
        .stable => {
            for (releases) |release| {
                if (!release.prerelease) return release;
            }
            return UpgradeError.NoStableRelease;
        },
        .dev => {
            var latest: ?Release = null;
            for (releases) |release| {
                if (latest == null or std.mem.order(u8, release.published_at, latest.?.published_at) == .gt) {
                    latest = release;
                }
            }
            return latest orelse UpgradeError.NoRelease;
        },
    }
}

fn dupeRelease(allocator: std.mem.Allocator, release: Release) !Release {
    const tag_name = try allocator.dupe(u8, release.tag_name);
    errdefer allocator.free(tag_name);

    const published_at = try allocator.dupe(u8, release.published_at);
    errdefer allocator.free(published_at);

    const assets = try allocator.alloc(ReleaseAsset, release.assets.len);
    errdefer allocator.free(assets);

    var dup_count: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < dup_count) : (i += 1) {
            allocator.free(assets[i].name);
            allocator.free(assets[i].browser_download_url);
        }
    }

    for (release.assets, 0..) |asset, i| {
        const name = try allocator.dupe(u8, asset.name);
        errdefer allocator.free(name);
        const url = try allocator.dupe(u8, asset.browser_download_url);
        assets[i] = .{
            .name = name,
            .browser_download_url = url,
            .size = asset.size,
        };
        dup_count = i + 1;
    }

    return .{
        .tag_name = tag_name,
        .assets = assets,
        .published_at = published_at,
        .prerelease = release.prerelease,
    };
}

fn freeRelease(allocator: std.mem.Allocator, release: Release) void {
    allocator.free(release.tag_name);
    allocator.free(release.published_at);
    for (release.assets) |asset| {
        allocator.free(asset.name);
        allocator.free(asset.browser_download_url);
    }
    allocator.free(release.assets);
}

pub fn install(allocator: std.mem.Allocator, src_path: []const u8, io: std.Io) !void {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path_len = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &self_buf);
    const dest_path = self_buf[0..dest_path_len];
    return installTo(allocator, src_path, dest_path, io);
}

pub fn installTo(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8, io: std.Io) !void {
    const dest_stat = blk: {
        const dest_file = try std.Io.Dir.openFileAbsolute(io, dest_path, .{});
        defer dest_file.close(io);
        break :blk try dest_file.stat(io);
    };

    const tmp_path = try std.mem.concat(allocator, u8, &.{ dest_path, ".new" });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    const content = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .unlimited);
    defer allocator.free(content);

    const tmp_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .exclusive = true });
    {
        defer tmp_file.close(io);
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        try tmp_file.writeStreamingAll(io, content);
        try tmp_file.setPermissions(io, dest_stat.permissions);
    }

    try std.Io.Dir.renameAbsolute(tmp_path, dest_path, io);
}

pub const UpgradeOptions = struct {
    channel: Channel,
    dry_run: bool,
};

pub fn printDryRunInfo(
    writer: *std.Io.Writer,
    version: []const u8,
    asset_url: []const u8,
    checksum: []const u8,
    install_path: []const u8,
) !void {
    try writer.print("version: {s}\nasset_url: {s}\nchecksum: {s}\ninstall_path: {s}\n", .{
        version, asset_url, checksum, install_path,
    });
}

pub fn printUpgradeSuccess(
    writer: *std.Io.Writer,
    prev_version: []const u8,
    new_tag: []const u8,
    channel: Channel,
    install_path: []const u8,
) !void {
    const channel_str = switch (channel) {
        .stable => "stable",
        .dev => "dev",
    };
    try writer.print("Upgraded zpm from {s} to {s} ({s} channel) at {s}\n", .{
        prev_version, new_tag, channel_str, install_path,
    });
}

pub fn printAlreadyUpToDate(writer: *std.Io.Writer, tag: []const u8) !void {
    try writer.print("zpm is already up to date ({s})\n", .{tag});
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        UpgradeError.UnsupportedPlatform => "unsupported platform (supported: linux-x86_64, linux-arm64, darwin-universal)",
        UpgradeError.NoStableRelease => "no stable release published; re-run with --channel dev to opt into prereleases",
        UpgradeError.NoRelease => "no releases published for the selected channel",
        UpgradeError.ChecksumMismatch => "checksum verification failed; downloaded binary does not match the published SHA256SUMS entry",
        UpgradeError.ChecksumNotFound => "SHA256SUMS has no entry for the selected platform asset",
        UpgradeError.SHA256SUMSMissing => "release has no SHA256SUMS asset; cannot verify integrity",
        UpgradeError.NetworkError => "network request failed; check connectivity and GitHub API availability",
        UpgradeError.InvalidSelfPath => "cannot resolve the running binary's directory; reinstall zpm manually",
        else => "",
    };
}

fn writeError(err: anyerror) void {
    const msg = errorMessage(err);
    if (msg.len > 0) {
        std.debug.print("ERROR: {s}\n", .{msg});
    } else {
        std.debug.print("ERROR: upgrade failed: {s}\n", .{@errorName(err)});
    }
}

pub fn upgradeExecAction() anyerror!void {
    const allocator = std.heap.page_allocator;
    const opts = UpgradeOptions{ .channel = channel_slot, .dry_run = dry_run_slot };
    upgradeAction(allocator, opts) catch |err| {
        writeError(err);
        return err;
    };
}

pub fn upgradeAction(allocator: std.mem.Allocator, opts: UpgradeOptions) anyerror!void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var http_client = HttpReleaseClient.init(allocator, io);
    defer http_client.deinit();
    const stdout = std.Io.File.stdout();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_fw = stdout.writer(io, &stdout_buf);
    try upgradeActionWithClient(allocator, opts, http_client.releaseClient(), &stdout_fw.interface, io);
    try stdout_fw.interface.flush();
}

fn findAssetUrl(assets: []const ReleaseAsset, name: []const u8) ?[]const u8 {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) return asset.browser_download_url;
    }
    return null;
}

pub fn upgradeActionWithClient(
    allocator: std.mem.Allocator,
    opts: UpgradeOptions,
    client: ReleaseClient,
    out: *std.Io.Writer,
    io: std.Io,
) anyerror!void {
    const release = try client.fetchLatest(opts.channel);
    defer freeRelease(allocator, release);

    const release_version = if (std.mem.startsWith(u8, release.tag_name, "v"))
        release.tag_name[1..]
    else
        release.tag_name;

    if (std.mem.eql(u8, release_version, version_info.version)) {
        try printAlreadyUpToDate(out, release.tag_name);
        return;
    }

    const asset_name = try detectPlatform();
    const asset_url = findAssetUrl(release.assets, asset_name) orelse return UpgradeError.UnsupportedPlatform;
    const sums_url = findAssetUrl(release.assets, "SHA256SUMS") orelse return UpgradeError.SHA256SUMSMissing;

    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path_len = try std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &self_buf);
    const self_path = self_buf[0..self_path_len];
    const self_dir = std.fs.path.dirname(self_path) orelse return UpgradeError.InvalidSelfPath;

    var sums_tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sums_tmp_path = try std.fmt.bufPrint(&sums_tmp_buf, "{s}/.zpm-sha256sums-{x}", .{ self_dir, blk: {
        var rb: [4]u8 = undefined;
        io.random(&rb);
        break :blk std.mem.readInt(u32, &rb, .little);
    } });
    try client.downloadToFile(sums_url, sums_tmp_path);
    defer std.Io.Dir.cwd().deleteFile(io, sums_tmp_path) catch {};

    const sums_contents = try std.Io.Dir.cwd().readFileAlloc(io, sums_tmp_path, allocator, .limited(1024 * 1024));
    defer allocator.free(sums_contents);

    const expected_hash = findChecksumFor(sums_contents, asset_name) orelse return UpgradeError.ChecksumNotFound;

    if (opts.dry_run) {
        try printDryRunInfo(out, release.tag_name, asset_url, expected_hash, self_path);
        return;
    }

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}/.zpm-upgrade-{x}", .{ self_dir, blk: {
        var rb: [4]u8 = undefined;
        io.random(&rb);
        break :blk std.mem.readInt(u32, &rb, .little);
    } });
    try client.downloadToFile(asset_url, tmp_path);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    try verifySha256(allocator, tmp_path, expected_hash, io);
    try installTo(allocator, tmp_path, self_path, io);

    try printUpgradeSuccess(out, version_info.version, release.tag_name, opts.channel, self_path);
}

test "detectPlatform returns zpm-linux-x86_64 on linux x86_64" {
    if (std.c.getenv("ZPM_OVERRIDE_PLATFORM") != null) return error.SkipZigTest;
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const name = try detectPlatform();
    try std.testing.expectEqualStrings("zpm-linux-x86_64", name);
}

test "detectPlatform returns zpm-linux-arm64 on linux aarch64" {
    if (std.c.getenv("ZPM_OVERRIDE_PLATFORM") != null) return error.SkipZigTest;
    if (builtin.os.tag != .linux or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const name = try detectPlatform();
    try std.testing.expectEqualStrings("zpm-linux-arm64", name);
}

test "detectPlatform returns zpm-darwin-universal on macos" {
    if (std.c.getenv("ZPM_OVERRIDE_PLATFORM") != null) return error.SkipZigTest;
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const name = try detectPlatform();
    try std.testing.expectEqualStrings("zpm-darwin-universal", name);
}

test "assetBasename maps linux x86_64 to zpm-linux-x86_64" {
    const name = try assetBasename(.linux, .x86_64);
    try std.testing.expectEqualStrings("zpm-linux-x86_64", name);
}

test "assetBasename maps linux aarch64 to zpm-linux-arm64" {
    const name = try assetBasename(.linux, .aarch64);
    try std.testing.expectEqualStrings("zpm-linux-arm64", name);
}

test "assetBasename maps macos any arch to zpm-darwin-universal" {
    try std.testing.expectEqualStrings("zpm-darwin-universal", try assetBasename(.macos, .x86_64));
    try std.testing.expectEqualStrings("zpm-darwin-universal", try assetBasename(.macos, .aarch64));
}

test "assetBasename returns UnsupportedPlatform for unknown os" {
    try std.testing.expectError(UpgradeError.UnsupportedPlatform, assetBasename(.freebsd, .x86_64));
}

test "parseChecksumLine parses well-formed line into hash and filename" {
    const line = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  zpm-linux-x86_64";
    const entry = parseChecksumLine(line) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", entry.hash);
    try std.testing.expectEqualStrings("zpm-linux-x86_64", entry.filename);
}

test "parseChecksumLine strips leading ./ prefix from filename" {
    const line = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  ./zpm-linux-x86_64";
    const entry = parseChecksumLine(line) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("zpm-linux-x86_64", entry.filename);
}

test "parseChecksumLine strips leading directory path from filename" {
    const line = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  dist/zpm-linux-x86_64";
    const entry = parseChecksumLine(line) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("zpm-linux-x86_64", entry.filename);
}

test "findChecksumFor returns hash for matching filename full-name match" {
    const sums =
        \\aaaa  zpm-linux-arm64
        \\bbbb  zpm-linux-x86_64
        \\cccc  zpm-darwin-universal
    ;
    try std.testing.expectEqualStrings("bbbb", findChecksumFor(sums, "zpm-linux-x86_64").?);
    try std.testing.expectEqualStrings("aaaa", findChecksumFor(sums, "zpm-linux-arm64").?);
}

test "findChecksumFor returns null when no entry matches" {
    const sums = "aaaa  zpm-linux-arm64\n";
    try std.testing.expect(findChecksumFor(sums, "zpm-linux-x86_64") == null);
}

test "findChecksumFor rejects substring match (F015 regression guard)" {
    // A line for 'zpm' alone must not satisfy a search for 'zpm-linux-x86_64'.
    const sums = "aaaa  zpm\n";
    try std.testing.expect(findChecksumFor(sums, "zpm-linux-x86_64") == null);
}

test "verifySha256 succeeds when file hash matches expected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(std.testing.io, "bin", .{});
    try f.writeStreamingAll(std.testing.io, "hello");
    f.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "bin", &path_buf);
    const path = path_buf[0..path_len];

    try verifySha256(std.testing.allocator, path, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", std.testing.io);
}

test "verifySha256 returns ChecksumMismatch when hash does not match file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(std.testing.io, "bin", .{});
    try f.writeStreamingAll(std.testing.io, "hello");
    f.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "bin", &path_buf);
    const path = path_buf[0..path_len];

    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(UpgradeError.ChecksumMismatch, verifySha256(std.testing.allocator, path, wrong, std.testing.io));
}

const TestReleaseClient = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    last_channel: ?Channel = null,
    last_url: ?[]const u8 = null,
    last_dest: ?[]const u8 = null,
    fetch_error: ?anyerror = null,
    download_error: ?anyerror = null,

    fn fetchLatestFn(ptr: *anyopaque, channel: Channel) anyerror!Release {
        const self: *TestReleaseClient = @ptrCast(@alignCast(ptr));
        self.last_channel = channel;
        if (self.fetch_error) |err| return err;
        const proto = Release{
            .tag_name = "v1.2.3",
            .assets = &[_]ReleaseAsset{.{
                .name = "zpm-linux-x86_64",
                .browser_download_url = "https://example.com/zpm-linux-x86_64",
                .size = 4096,
            }},
            .published_at = "2026-01-01T00:00:00Z",
            .prerelease = channel == .dev,
        };
        return dupeRelease(self.allocator, proto);
    }

    fn downloadToFileFn(ptr: *anyopaque, url: []const u8, dest: []const u8) anyerror!void {
        const self: *TestReleaseClient = @ptrCast(@alignCast(ptr));
        self.last_url = url;
        self.last_dest = dest;
        if (self.download_error) |err| return err;
    }

    fn client(self: *TestReleaseClient) ReleaseClient {
        return .{
            .ptr = self,
            .fetchLatestFn = fetchLatestFn,
            .downloadToFileFn = downloadToFileFn,
        };
    }
};

test "ReleaseClient.fetchLatest dispatches channel and returns stable Release" {
    var mock = TestReleaseClient{};
    const c = mock.client();

    const release = try c.fetchLatest(.stable);
    defer freeRelease(std.testing.allocator, release);

    try std.testing.expect(mock.last_channel == .stable);
    try std.testing.expectEqualStrings("v1.2.3", release.tag_name);
    try std.testing.expect(!release.prerelease);
    try std.testing.expectEqual(@as(usize, 1), release.assets.len);
    try std.testing.expectEqualStrings("zpm-linux-x86_64", release.assets[0].name);
    try std.testing.expectEqual(@as(u64, 4096), release.assets[0].size);
}

test "ReleaseClient.fetchLatest dispatches channel and returns dev Release" {
    var mock = TestReleaseClient{};
    const c = mock.client();

    const release = try c.fetchLatest(.dev);
    defer freeRelease(std.testing.allocator, release);

    try std.testing.expect(mock.last_channel == .dev);
    try std.testing.expect(release.prerelease);
}

test "ReleaseClient.downloadToFile dispatches url and dest" {
    var mock = TestReleaseClient{};
    const c = mock.client();

    try c.downloadToFile("https://example.com/zpm-linux-x86_64", "/tmp/zpm-new");

    try std.testing.expectEqualStrings("https://example.com/zpm-linux-x86_64", mock.last_url.?);
    try std.testing.expectEqualStrings("/tmp/zpm-new", mock.last_dest.?);
}

test "ReleaseClient.fetchLatest propagates error from implementation" {
    var mock = TestReleaseClient{ .fetch_error = UpgradeError.NetworkError };
    const c = mock.client();

    try std.testing.expectError(UpgradeError.NetworkError, c.fetchLatest(.stable));
}

test "ReleaseClient.downloadToFile propagates error from implementation" {
    var mock = TestReleaseClient{ .download_error = UpgradeError.NetworkError };
    const c = mock.client();

    try std.testing.expectError(UpgradeError.NetworkError, c.downloadToFile("https://example.com/x", "/tmp/x"));
}

const stable_release = Release{
    .tag_name = "v1.0.0",
    .assets = &[_]ReleaseAsset{},
    .published_at = "2026-01-01T00:00:00Z",
    .prerelease = false,
};

const prerelease_release = Release{
    .tag_name = "v1.1.0-beta",
    .assets = &[_]ReleaseAsset{},
    .published_at = "2026-01-02T00:00:00Z",
    .prerelease = true,
};

test "selectRelease returns stable release for stable channel" {
    const releases = [_]Release{ prerelease_release, stable_release };
    const r = try selectRelease(&releases, .stable);
    try std.testing.expect(!r.prerelease);
    try std.testing.expectEqualStrings("v1.0.0", r.tag_name);
}

test "selectRelease returns latest release for dev channel" {
    const releases = [_]Release{ stable_release, prerelease_release };
    const r = try selectRelease(&releases, .dev);
    try std.testing.expect(r.prerelease);
    try std.testing.expectEqualStrings("v1.1.0-beta", r.tag_name);
}

test "selectRelease returns NoStableRelease when only prereleases exist for stable channel" {
    const releases = [_]Release{prerelease_release};
    try std.testing.expectError(UpgradeError.NoStableRelease, selectRelease(&releases, .stable));
}

test "selectRelease returns NoStableRelease for empty release list on stable channel" {
    try std.testing.expectError(UpgradeError.NoStableRelease, selectRelease(&[_]Release{}, .stable));
}

test "selectRelease dev channel returns NoRelease for empty list" {
    try std.testing.expectError(UpgradeError.NoRelease, selectRelease(&[_]Release{}, .dev));
}

test "installTo replaces dest file content with src content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src = try tmp.dir.createFile(std.testing.io, "src_bin", .{});
    try src.writeStreamingAll(std.testing.io, "updated binary content");
    src.close(std.testing.io);

    const dest = try tmp.dir.createFile(std.testing.io, "dest_bin", .{});
    try dest.writeStreamingAll(std.testing.io, "old binary content");
    dest.close(std.testing.io);

    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path_len = try tmp.dir.realPathFile(std.testing.io, "src_bin", &src_buf);
    const src_path = src_buf[0..src_path_len];
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path_len = try tmp.dir.realPathFile(std.testing.io, "dest_bin", &dest_buf);
    const dest_path = dest_buf[0..dest_path_len];

    try installTo(std.testing.allocator, src_path, dest_path, std.testing.io);

    const content = try tmp.dir.readFileAlloc(std.testing.io, "dest_bin", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("updated binary content", content);

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "dest_bin.new", .{}));
}

test "installTo preserves dest file executable mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src = try tmp.dir.createFile(std.testing.io, "src_bin", .{});
    try src.writeStreamingAll(std.testing.io, "new content");
    src.close(std.testing.io);

    const dest = try tmp.dir.createFile(std.testing.io, "dest_bin", .{});
    try dest.writeStreamingAll(std.testing.io, "old content");
    _ = std.c.fchmod(dest.handle, 0o755);
    dest.close(std.testing.io);

    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path_len = try tmp.dir.realPathFile(std.testing.io, "src_bin", &src_buf);
    const src_path = src_buf[0..src_path_len];
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path_len = try tmp.dir.realPathFile(std.testing.io, "dest_bin", &dest_buf);
    const dest_path = dest_buf[0..dest_path_len];

    try installTo(std.testing.allocator, src_path, dest_path, std.testing.io);

    const installed = try tmp.dir.openFile(std.testing.io, "dest_bin", .{});
    defer installed.close(std.testing.io);
    const stat = try installed.stat(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);
}

test "installTo fails with PathAlreadyExists when temp file exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src = try tmp.dir.createFile(std.testing.io, "src_bin", .{});
    try src.writeStreamingAll(std.testing.io, "new content");
    src.close(std.testing.io);

    const dest = try tmp.dir.createFile(std.testing.io, "dest_bin", .{});
    try dest.writeStreamingAll(std.testing.io, "old content");
    dest.close(std.testing.io);

    const lock = try tmp.dir.createFile(std.testing.io, "dest_bin.new", .{});
    lock.close(std.testing.io);

    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path_len = try tmp.dir.realPathFile(std.testing.io, "src_bin", &src_buf);
    const src_path = src_buf[0..src_path_len];
    var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dest_path_len = try tmp.dir.realPathFile(std.testing.io, "dest_bin", &dest_buf);
    const dest_path = dest_buf[0..dest_path_len];

    try std.testing.expectError(error.PathAlreadyExists, installTo(std.testing.allocator, src_path, dest_path, std.testing.io));

    const content = try tmp.dir.readFileAlloc(std.testing.io, "dest_bin", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("old content", content);
}

const CurrentVersionClient = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    download_called: bool = false,

    fn fetchLatestFn(ptr: *anyopaque, channel: Channel) anyerror!Release {
        _ = channel;
        const self: *CurrentVersionClient = @ptrCast(@alignCast(ptr));
        const proto = Release{
            .tag_name = version_info.version,
            .assets = &[_]ReleaseAsset{},
            .published_at = "2026-01-01T00:00:00Z",
            .prerelease = false,
        };
        return dupeRelease(self.allocator, proto);
    }

    fn downloadToFileFn(ptr: *anyopaque, url: []const u8, dest: []const u8) anyerror!void {
        const self: *CurrentVersionClient = @ptrCast(@alignCast(ptr));
        _ = url;
        _ = dest;
        self.download_called = true;
        return error.TestUnexpectedDownload;
    }

    fn client(self: *CurrentVersionClient) ReleaseClient {
        return .{
            .ptr = self,
            .fetchLatestFn = fetchLatestFn,
            .downloadToFileFn = downloadToFileFn,
        };
    }
};

test "upgradeActionWithClient short-circuits without download when version matches current" {
    var mock = CurrentVersionClient{};
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try upgradeActionWithClient(std.testing.allocator, .{ .channel = .stable, .dry_run = false }, mock.client(), &aw.writer, std.testing.io);
    try std.testing.expect(!mock.download_called);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "already up to date") != null);
}

test "selectRelease dev channel picks stable release when stable has newest published_at" {
    const older_prerelease = Release{
        .tag_name = "v1.1.0-beta",
        .assets = &[_]ReleaseAsset{},
        .published_at = "2026-01-01T00:00:00Z",
        .prerelease = true,
    };
    const newer_stable = Release{
        .tag_name = "v1.1.0",
        .assets = &[_]ReleaseAsset{},
        .published_at = "2026-01-02T00:00:00Z",
        .prerelease = false,
    };
    const releases = [_]Release{ newer_stable, older_prerelease };
    const r = try selectRelease(&releases, .dev);
    try std.testing.expect(!r.prerelease);
    try std.testing.expectEqualStrings("v1.1.0", r.tag_name);
}

test "selectRelease stable channel returns NoStableRelease when multiple prereleases exist" {
    const pr1 = Release{
        .tag_name = "v1.1.0-beta",
        .assets = &[_]ReleaseAsset{},
        .published_at = "2026-01-02T00:00:00Z",
        .prerelease = true,
    };
    const pr2 = Release{
        .tag_name = "v1.0.0-rc1",
        .assets = &[_]ReleaseAsset{},
        .published_at = "2026-01-01T00:00:00Z",
        .prerelease = true,
    };
    try std.testing.expectError(UpgradeError.NoStableRelease, selectRelease(&[_]Release{ pr1, pr2 }, .stable));
}

test "printDryRunInfo writes version asset_url checksum install_path to writer" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printDryRunInfo(
        &aw.writer,
        "v1.2.3",
        "https://example.com/zpm-linux-x86_64",
        "abc123def456",
        "/usr/local/bin/zpm",
    );
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "v1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "https://example.com/zpm-linux-x86_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "abc123def456") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "/usr/local/bin/zpm") != null);
}

test "printUpgradeSuccess writes prev/new version, channel, install path" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printUpgradeSuccess(&aw.writer, "0.1.0", "v0.2.0", .stable, "/usr/local/bin/zpm");
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "v0.2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "stable") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "/usr/local/bin/zpm") != null);
}

test "printAlreadyUpToDate writes tag" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printAlreadyUpToDate(&aw.writer, "v0.1.0");
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "v0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "already up to date") != null);
}

test "errorMessage covers every UpgradeError variant" {
    inline for (@typeInfo(UpgradeError).error_set orelse @compileError("UpgradeError must be non-empty")) |variant| {
        const err = @field(UpgradeError, variant.name);
        const msg = errorMessage(err);
        try std.testing.expect(msg.len > 0);
    }
}

test "selectRelease stable channel returns first prerelease:false in list when multiple stables exist" {
    const older_stable = Release{
        .tag_name = "v1.0.0",
        .assets = &[_]ReleaseAsset{},
        .published_at = "2026-01-01T00:00:00Z",
        .prerelease = false,
    };
    const newer_stable = Release{
        .tag_name = "v1.1.0",
        .assets = &[_]ReleaseAsset{},
        .published_at = "2026-01-02T00:00:00Z",
        .prerelease = false,
    };
    // GitHub API returns newest first; stable should pick the first prerelease:false entry
    const r = try selectRelease(&[_]Release{ newer_stable, older_stable }, .stable);
    try std.testing.expectEqualStrings("v1.1.0", r.tag_name);
}

pub fn buildCommand(runner: *cli.AppRunner) !cli.Command {
    const opts = try runner.allocOptions(&.{
        .{
            .long_name = "channel",
            .help = "Release channel: 'stable' or 'dev' (default: stable)",
            .required = false,
            .value_ref = runner.mkRef(&channel_slot),
        },
        .{
            .long_name = "dry-run",
            .help = "Print upgrade plan without writing the new binary",
            .required = false,
            .value_ref = runner.mkRef(&dry_run_slot),
        },
    });
    return cli.Command{
        .name = "upgrade",
        .description = .{ .one_line = "Upgrade zpm to the latest release" },
        .options = opts,
        .target = .{ .action = .{ .exec = upgradeExecAction } },
    };
}

fn makeTestInit(arena: *std.heap.ArenaAllocator, environ_map: *std.process.Environ.Map) std.process.Init {
    return .{
        .minimal = .{
            .environ = .empty,
            .args = .{ .vector = &.{} },
        },
        .arena = arena,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = environ_map,
        .preopens = .empty,
    };
}

test "buildCommand exposes channel and dry-run options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const fake_init = makeTestInit(&arena, &environ_map);
    var runner = cli.AppRunner.init(&fake_init);
    defer runner.deinit();
    const cmd = try buildCommand(&runner);

    try std.testing.expectEqualStrings("upgrade", cmd.name);
    const opts = cmd.options orelse return error.MissingOptions;
    try std.testing.expectEqual(@as(usize, 2), opts.len);
    try std.testing.expectEqualStrings("channel", opts[0].long_name);
    try std.testing.expectEqualStrings("dry-run", opts[1].long_name);
    try std.testing.expect(!opts[0].required);
    try std.testing.expect(!opts[1].required);
}
