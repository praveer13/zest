/// HF Hub API client: authentication, file listing, Xet file ID detection.
///
/// Download flow:
/// 1. GET /api/models/{repo_id}?revision={rev} → model info + file list
/// 2. For each file, HEAD /resolve/{rev}/{path} → check X-Xet-Hash header
/// 3. Files with X-Xet-Hash use Xet protocol; others are regular downloads
const std = @import("std");
const cfg = @import("config.zig");

pub const RepoFile = struct {
    path: []const u8,
    size: u64,
    /// Xet file hash from X-Xet-Hash header, or null if not Xet-backed.
    xet_hash: ?[]const u8,
    /// LFS SHA256 hash if available.
    lfs_sha256: ?[]const u8,
};

pub const RepoInfo = struct {
    repo_id: []const u8,
    revision: []const u8,
    commit_sha: ?[]const u8,
    files: []RepoFile,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RepoInfo) void {
        for (self.files) |file| {
            self.allocator.free(file.path);
            if (file.xet_hash) |h| self.allocator.free(h);
            if (file.lfs_sha256) |h| self.allocator.free(h);
        }
        self.allocator.free(self.files);
        self.allocator.free(self.repo_id);
        self.allocator.free(self.revision);
        if (self.commit_sha) |sha| self.allocator.free(sha);
    }
};

pub const HubClient = struct {
    allocator: std.mem.Allocator,
    config: *const cfg.Config,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: *const cfg.Config) HubClient {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *HubClient) void {
        self.http_client.deinit();
    }

    /// Fetch model info from HF Hub API and detect Xet-backed files.
    pub fn getRepoInfo(self: *HubClient, repo_id: []const u8, revision: []const u8) !RepoInfo {
        // Step 1: GET /api/models/{repo_id}?revision={rev}
        const api_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/models/{s}?revision={s}",
            .{ cfg.hf_api_url, repo_id, revision },
        );
        defer self.allocator.free(api_url);

        const body = try self.httpGet(api_url);
        defer self.allocator.free(body);

        // Parse the JSON response to extract file list
        var files = std.ArrayList(RepoFile).init(self.allocator);
        errdefer {
            for (files.items) |f| {
                self.allocator.free(f.path);
                if (f.xet_hash) |h| self.allocator.free(h);
                if (f.lfs_sha256) |h| self.allocator.free(h);
            }
            files.deinit();
        }

        // Parse "siblings" array from model info JSON
        var commit_sha: ?[]const u8 = null;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const root = parsed.value;

        // Extract commit SHA
        if (root.object.get("sha")) |sha_val| {
            if (sha_val == .string) {
                commit_sha = try self.allocator.dupe(u8, sha_val.string);
            }
        }

        // Extract siblings (file list)
        if (root.object.get("siblings")) |siblings_val| {
            if (siblings_val == .array) {
                for (siblings_val.array.items) |item| {
                    if (item != .object) continue;
                    const rfilename = item.object.get("rfilename") orelse continue;
                    if (rfilename != .string) continue;

                    var size: u64 = 0;
                    var lfs_sha: ?[]const u8 = null;

                    if (item.object.get("size")) |size_val| {
                        if (size_val == .integer) {
                            size = @intCast(size_val.integer);
                        }
                    }

                    // Check for LFS info
                    if (item.object.get("lfs")) |lfs_val| {
                        if (lfs_val == .object) {
                            if (lfs_val.object.get("sha256")) |sha_val| {
                                if (sha_val == .string) {
                                    lfs_sha = try self.allocator.dupe(u8, sha_val.string);
                                }
                            }
                            if (lfs_val.object.get("size")) |lfs_size| {
                                if (lfs_size == .integer) {
                                    size = @intCast(lfs_size.integer);
                                }
                            }
                        }
                    }

                    try files.append(.{
                        .path = try self.allocator.dupe(u8, rfilename.string),
                        .size = size,
                        .xet_hash = null, // Will be populated in step 2
                        .lfs_sha256 = lfs_sha,
                    });
                }
            }
        }

        return .{
            .repo_id = try self.allocator.dupe(u8, repo_id),
            .revision = try self.allocator.dupe(u8, revision),
            .commit_sha = commit_sha,
            .files = try files.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    /// Probe a single file to detect if it's Xet-backed via the resolve endpoint.
    /// Returns the X-Xet-Hash header value if present.
    pub fn probeXetFile(self: *HubClient, repo_id: []const u8, revision: []const u8, file_path: []const u8) !?[]const u8 {
        const resolve_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/resolve/{s}/{s}",
            .{ cfg.hf_hub_url, repo_id, revision, file_path },
        );
        defer self.allocator.free(resolve_url);

        const uri = try std.Uri.parse(resolve_url);

        var header_buf: [16 * 1024]u8 = undefined;
        var req = try self.http_client.open(.HEAD, uri, .{
            .server_header_buffer = &header_buf,
            .redirect_behavior = .unhandled,
            .extra_headers = if (self.config.hf_token) |token|
                &[_]std.http.Header{.{ .name = "Authorization", .value = token }}
            else
                &[_]std.http.Header{},
        });
        defer req.deinit();
        try req.send();
        try req.wait();

        // Look for X-Xet-Hash in response headers
        var it = req.response.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-xet-hash")) {
                return try self.allocator.dupe(u8, header.value);
            }
        }

        return null;
    }

    /// Probe all files in a RepoInfo to detect Xet-backed files.
    pub fn probeAllFiles(self: *HubClient, info: *RepoInfo) !void {
        for (info.files) |*file| {
            file.xet_hash = self.probeXetFile(info.repo_id, info.revision, file.path) catch null;
        }
    }

    fn httpGet(self: *HubClient, url: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);

        var header_buf: [16 * 1024]u8 = undefined;
        var req = try self.http_client.open(.GET, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = if (self.config.hf_token) |token|
                &[_]std.http.Header{.{ .name = "Authorization", .value = token }}
            else
                &[_]std.http.Header{},
        });
        defer req.deinit();
        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            return error.HttpError;
        }

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();
        try req.reader().readAllArrayList(&body, 16 * 1024 * 1024);
        return try body.toOwnedSlice();
    }
};
