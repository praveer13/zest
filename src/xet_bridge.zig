/// XET Bridge: connects zig-xet's CAS layer with zest's P2P swarm.
///
/// Replaces the opaque `downloadModelToFile()` with a zest-controlled pipeline
/// where each xorb routes through: local cache → P2P swarm → CDN fallback.
///
/// This is the foundational piece for parallel downloads (Phase 2) and
/// peer racing (Phase 4).
const std = @import("std");
const Io = std.Io;
const xet = @import("xet");
const config = @import("config.zig");
const storage = @import("storage.zig");
const swarm_mod = @import("swarm.zig");

// zig-xet modules
const cas_client = xet.cas_client;
const hashing = xet.hashing;
const xorb_mod = xet.xorb;

pub const XetBridge = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *const config.Config,
    cache: swarm_mod.XorbCache,

    /// CAS client (initialized after authentication).
    cas: ?cas_client.CasClient,

    /// Optional P2P swarm for peer downloads.
    swarm_downloader: ?*swarm_mod.SwarmDownloader,

    /// Per-session fetch stats.
    stats: FetchStats,

    pub const FetchStats = struct {
        xorbs_from_cache: usize = 0,
        xorbs_from_peer: usize = 0,
        xorbs_from_cdn: usize = 0,
        bytes_from_cache: u64 = 0,
        bytes_from_peer: u64 = 0,
        bytes_from_cdn: u64 = 0,
    };

    /// Result of fetching xorb data for a term.
    pub const XorbFetchResult = struct {
        /// Raw xorb data (caller must free).
        data: []u8,
        /// Chunk range within the returned data. These may differ from the
        /// term's absolute range when the data comes from a CDN byte-range fetch.
        local_start: u32,
        local_end: u32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        cfg: *const config.Config,
        swarm_downloader: ?*swarm_mod.SwarmDownloader,
    ) XetBridge {
        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .cache = swarm_mod.XorbCache.init(allocator, io, cfg),
            .cas = null,
            .swarm_downloader = swarm_downloader,
            .stats = .{},
        };
    }

    pub fn deinit(self: *XetBridge) void {
        if (self.cas) |*c| c.deinit();
    }

    /// Exchange HF token for Xet access token and initialize CAS client.
    pub fn authenticate(
        self: *XetBridge,
        repo_id: []const u8,
        repo_type: []const u8,
        revision: []const u8,
        hf_token: []const u8,
    ) !void {
        const token_url = try std.fmt.allocPrint(
            self.allocator,
            "https://huggingface.co/api/{s}s/{s}/xet-read-token/{s}",
            .{ repo_type, repo_id, revision },
        );
        defer self.allocator.free(token_url);

        var http_client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer http_client.deinit();

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{hf_token});
        defer self.allocator.free(auth_header);

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const extra_headers: []const std.http.Header = &.{
            .{ .name = "Authorization", .value = auth_header },
        };

        const result = http_client.fetch(.{
            .location = .{ .url = token_url },
            .response_writer = &aw.writer,
            .extra_headers = extra_headers,
        }) catch return error.NetworkError;

        if (result.status != .ok) return error.AuthenticationFailed;

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            aw.written(),
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;
        const access_token = root.get("accessToken").?.string;
        const cas_url = root.get("casUrl").?.string;

        // CasClient.init dupes these strings, so they survive parsed.deinit()
        self.cas = try cas_client.CasClient.init(
            self.allocator,
            self.io,
            cas_url,
            access_token,
        );
    }

    /// Get reconstruction info for a file by its hex hash.
    pub fn getReconstruction(
        self: *XetBridge,
        file_hash_hex: []const u8,
    ) !cas_client.ReconstructionResponse {
        if (self.cas) |*cas| {
            const file_hash = try cas_client.apiHexToHash(file_hash_hex);
            return try cas.getReconstruction(file_hash, null);
        }
        return error.NotAuthenticated;
    }

    /// Fetch xorb data for a reconstruction term (range-aware).
    /// Waterfall: local cache → P2P swarm → CDN.
    /// All three paths use the same matching FetchInfo entry for consistent
    /// index rebasing. Every CDN-fetched entry is cached (full or partial)
    /// so P2P peers can serve it — receivers never need CDN.
    pub fn fetchXorbForTerm(
        self: *XetBridge,
        term: cas_client.ReconstructionTerm,
        fetch_info_map: std.StringHashMap([]cas_client.FetchInfo),
    ) !XorbFetchResult {
        const hash_hex = hashing.hashToHex(term.hash);

        // Find the matching FetchInfo entry for this term's chunk range.
        const all_entries = fetch_info_map.get(&hash_hex) orelse return error.NotAuthenticated;
        const fi = findMatchingEntry(all_entries, term.range.start, term.range.end) orelse
            return error.NoMatchingFetchInfo;

        // Step 1: Check local xorb cache (range-aware: full xorb or partial entry)
        if (try self.cache.getWithRange(&hash_hex, fi.range.start)) |cached| {
            self.stats.xorbs_from_cache += 1;
            self.stats.bytes_from_cache += cached.data.len;
            return .{
                .data = cached.data,
                .local_start = term.range.start - cached.chunk_offset,
                .local_end = term.range.end - cached.chunk_offset,
            };
        }

        // Step 2: Try P2P (range-aware: request with fi's chunk range)
        if (self.swarm_downloader) |dl| {
            const swarm_term = swarm_mod.Term{
                .xorb_hash = term.hash,
                .xorb_hash_hex = hash_hex,
                .chunk_range_start = fi.range.start,
                .chunk_range_end = fi.range.end,
                .url = null,
            };
            if (dl.tryBtPeerDownload(&swarm_term)) |peer_result| {
                self.stats.xorbs_from_peer += 1;
                self.stats.bytes_from_peer += peer_result.data.len;
                return .{
                    .data = peer_result.data,
                    .local_start = term.range.start - peer_result.chunk_offset,
                    .local_end = term.range.end - peer_result.chunk_offset,
                };
            } else |_| {
                // P2P unavailable or all peers failed — fall through to CDN
            }
        }

        // Step 3: CDN (seeder only — receivers get everything from P2P above)
        if (self.cas) |*cas| {
            const cdn_data = try cas.fetchXorbFromUrl(
                fi.url,
                .{ .start = fi.url_range.start, .end = fi.url_range.end },
            );
            self.stats.xorbs_from_cdn += 1;
            self.stats.bytes_from_cdn += cdn_data.len;

            // Cache every entry for P2P serving
            if (fi.range.start == 0 and all_entries.len == 1) {
                self.cache.put(&hash_hex, cdn_data) catch {};
            } else {
                self.cache.putPartial(&hash_hex, fi.range.start, cdn_data) catch {};
            }

            return .{
                .data = cdn_data,
                .local_start = term.range.start - fi.range.start,
                .local_end = term.range.end - fi.range.start,
            };
        }

        return error.NotAuthenticated;
    }

    /// Find the FetchInfo entry that covers the given chunk range.
    fn findMatchingEntry(entries: []cas_client.FetchInfo, range_start: u32, range_end: u32) ?cas_client.FetchInfo {
        for (entries) |fi| {
            if (fi.range.start <= range_start and fi.range.end >= range_end) {
                return fi;
            }
        }
        return null;
    }

    /// Reconstruct a file from its xet hash and write to output path.
    pub fn reconstructToFile(
        self: *XetBridge,
        file_hash_hex: []const u8,
        output_path: []const u8,
    ) !void {
        // Ensure parent directory exists
        if (std.mem.lastIndexOfScalar(u8, output_path, '/')) |sep| {
            try storage.ensureDirRecursive(self.io, output_path[0..sep]);
        }

        // Get reconstruction info from CAS
        var recon = try self.getReconstruction(file_hash_hex);
        defer recon.deinit();

        // Open output file
        const file = try Io.Dir.createFileAbsolute(self.io, output_path, .{});
        defer file.close(self.io);
        var file_buf: [8192]u8 = undefined;
        var fw = file.writer(self.io, &file_buf);

        // Process each term: fetch xorb → extract chunks → write
        for (recon.terms) |term| {
            const result = try self.fetchXorbForTerm(term, recon.fetch_info);
            defer self.allocator.free(result.data);

            var xorb_reader = xorb_mod.XorbReader.init(self.allocator, result.data);
            const chunk_data = try xorb_reader.extractChunkRange(result.local_start, result.local_end);
            defer self.allocator.free(chunk_data);

            fw.interface.writeAll(chunk_data) catch return error.WriteFailed;
        }

        fw.interface.flush() catch return error.WriteFailed;
    }

    /// Print fetch stats to a writer.
    pub fn printStats(self: *const XetBridge, w: *Io.Writer) void {
        const total = self.stats.xorbs_from_cache + self.stats.xorbs_from_peer + self.stats.xorbs_from_cdn;
        const total_bytes = self.stats.bytes_from_cache + self.stats.bytes_from_peer + self.stats.bytes_from_cdn;
        w.print("\nXorb fetch stats:\n", .{}) catch {};
        w.print("  Total xorbs:  {d}\n", .{total}) catch {};
        w.print("  From cache:   {d}\n", .{self.stats.xorbs_from_cache}) catch {};
        w.print("  From peers:   {d}\n", .{self.stats.xorbs_from_peer}) catch {};
        w.print("  From CDN:     {d}\n", .{self.stats.xorbs_from_cdn}) catch {};
        w.print("  Total bytes:  {d}\n", .{total_bytes}) catch {};
        if (total_bytes > 0) {
            const peer_pct = @as(f64, @floatFromInt(self.stats.bytes_from_peer)) /
                @as(f64, @floatFromInt(total_bytes)) * 100.0;
            w.print("  P2P ratio:    {d:.1}%\n", .{peer_pct}) catch {};
        }
    }
};

// ── Tests ──

test "XetBridge init and deinit" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    var bridge = XetBridge.init(std.testing.allocator, std.testing.io, &cfg, null);
    defer bridge.deinit();

    try std.testing.expect(bridge.cas == null);
    try std.testing.expectEqual(@as(usize, 0), bridge.stats.xorbs_from_cache);
    try std.testing.expectEqual(@as(usize, 0), bridge.stats.xorbs_from_cdn);
}

test "XetBridge getReconstruction requires auth" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    var bridge = XetBridge.init(std.testing.allocator, std.testing.io, &cfg, null);
    defer bridge.deinit();

    const result = bridge.getReconstruction("0" ** 64);
    try std.testing.expectError(error.NotAuthenticated, result);
}
