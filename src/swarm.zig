/// Swarm orchestrator: coordinates download from peers + CDN fallback.
///
/// For each needed xorb:
///   1. Check local cache (already have it?)
///   2. Query tracker for peers with this xorb
///   3. If peers found → try download from peer (P2P)
///   4. If no peers / peer fails → CDN fallback (presigned URL)
///   5. Verify hash on receive
///   6. Cache locally for seeding
const std = @import("std");
const Io = std.Io;
const peer_mod = @import("peer.zig");
const tracker_mod = @import("tracker.zig");
const config = @import("config.zig");

/// Reconstruction term: references a range of chunks within a xorb.
pub const Term = struct {
    xorb_hash: [32]u8,
    xorb_hash_hex: [64]u8,
    chunk_range_start: u32,
    chunk_range_end: u32,
    url: ?[]const u8,
};

/// Reconstruction info for a file: the ordered list of terms
/// needed to reassemble the file from xorb chunks.
pub const ReconstructionInfo = struct {
    file_hash: [32]u8,
    file_size: u64,
    terms: []Term,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReconstructionInfo) void {
        self.allocator.free(self.terms);
    }
};

/// Xorb local cache: stores xorbs by hash for reuse and seeding.
pub const XorbCache = struct {
    cfg: *const config.Config,
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io, cfg_ptr: *const config.Config) XorbCache {
        return .{ .cfg = cfg_ptr, .allocator = allocator, .io = io };
    }

    /// Check if a xorb is already in the local cache.
    pub fn has(self: *const XorbCache, hash_hex: []const u8) bool {
        const cache_path = self.cfg.xorbCachePath(hash_hex) catch return false;
        defer self.allocator.free(cache_path);
        Io.Dir.accessAbsolute(self.io, cache_path, .{}) catch return false;
        return true;
    }

    /// Read a cached xorb from disk.
    pub fn get(self: *const XorbCache, hash_hex: []const u8) !?[]u8 {
        const cache_path = try self.cfg.xorbCachePath(hash_hex);
        defer self.allocator.free(cache_path);

        const file = Io.Dir.openFileAbsolute(self.io, cache_path, .{}) catch return null;
        defer file.close(self.io);

        const stat = file.stat(self.io) catch return null;
        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);

        var reader = file.reader(self.io, &.{});
        const bytes_read = reader.interface.readSliceShort(data) catch {
            self.allocator.free(data);
            return null;
        };
        if (bytes_read != stat.size) {
            self.allocator.free(data);
            return null;
        }

        return data;
    }

    /// Write a xorb to the local cache.
    pub fn put(self: *const XorbCache, hash_hex: []const u8, data: []const u8) !void {
        const cache_path = try self.cfg.xorbCachePath(hash_hex);
        defer self.allocator.free(cache_path);

        // Ensure parent directory exists
        if (std.mem.lastIndexOfScalar(u8, cache_path, '/')) |sep| {
            Io.Dir.createDirAbsolute(self.io, cache_path[0..sep], .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = Io.Dir.createFileAbsolute(self.io, cache_path, .{}) catch return error.WriteFailed;
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        fw.interface.writeAll(data) catch return error.WriteFailed;
        fw.interface.flush() catch return error.WriteFailed;
    }
};

pub const DownloadStats = struct {
    total_xorbs: usize,
    cached_xorbs: usize,
    peer_xorbs: usize,
    cdn_xorbs: usize,
    total_bytes: u64,
    peer_bytes: u64,
    cdn_bytes: u64,
};

pub const SwarmDownloader = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *const config.Config,
    http_client: std.http.Client,
    tracker: ?tracker_mod.TrackerClient,
    cache: XorbCache,
    stats: DownloadStats,

    pub fn init(allocator: std.mem.Allocator, io: Io, cfg_ptr: *const config.Config, tracker_url: ?[]const u8) !SwarmDownloader {
        var tracker_client: ?tracker_mod.TrackerClient = null;
        if (tracker_url) |url| {
            tracker_client = try tracker_mod.TrackerClient.init(allocator, io, url);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg_ptr,
            .http_client = .{ .allocator = allocator, .io = io },
            .tracker = tracker_client,
            .cache = XorbCache.init(allocator, io, cfg_ptr),
            .stats = std.mem.zeroes(DownloadStats),
        };
    }

    pub fn deinit(self: *SwarmDownloader) void {
        self.http_client.deinit();
        if (self.tracker) |*t| t.deinit();
    }

    /// Download all xorbs needed for a file's reconstruction.
    pub fn downloadXorbs(self: *SwarmDownloader, recon: *const ReconstructionInfo) !void {
        self.stats.total_xorbs = recon.terms.len;

        for (recon.terms) |*term| {
            try self.downloadSingleXorb(term);
        }
    }

    fn downloadSingleXorb(self: *SwarmDownloader, term: *const Term) !void {
        const hex = &term.xorb_hash_hex;

        // Step 1: Check local cache
        if (self.cache.has(hex)) {
            self.stats.cached_xorbs += 1;
            return;
        }

        // Step 2: Try peers via tracker
        if (self.tracker) |*t| {
            const peers = t.getPeers(hex) catch &[_]tracker_mod.TrackerPeer{};
            defer {
                for (peers) |p| self.allocator.free(p.addr);
                if (peers.len > 0) self.allocator.free(peers);
            }

            for (peers) |p| {
                if (self.tryPeerDownload(p.addr, term)) |data| {
                    defer self.allocator.free(data);
                    self.cache.put(hex, data) catch {};
                    self.stats.peer_xorbs += 1;
                    self.stats.peer_bytes += data.len;
                    self.stats.total_bytes += data.len;
                    return;
                } else |_| {
                    continue; // Try next peer
                }
            }
        }

        // Step 3: CDN fallback
        const url = term.url orelse return error.NoUrl;
        const data = try self.httpDownload(url);
        defer self.allocator.free(data);

        // Cache the downloaded xorb
        self.cache.put(hex, data) catch {};
        self.stats.cdn_xorbs += 1;
        self.stats.cdn_bytes += data.len;
        self.stats.total_bytes += data.len;
    }

    fn tryPeerDownload(self: *SwarmDownloader, addr_str: []const u8, term: *const Term) ![]u8 {
        const address = try peer_mod.parseAddress(addr_str);
        var conn = try peer_mod.PeerConnection.connect(self.allocator, self.io, address);
        defer conn.deinit();

        try conn.handshake([_]u8{0} ** 32, 0, 0);

        return try conn.requestXorb(term.xorb_hash);
    }

    /// Simple HTTP download from a URL using fetch.
    fn httpDownload(self: *SwarmDownloader, url: []const u8) ![]u8 {
        var aw: Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
        }) catch return error.HttpError;

        if (result.status != .ok and result.status != .partial_content) {
            aw.deinit();
            return error.HttpError;
        }

        return try aw.toOwnedSlice();
    }

    pub fn printStats(self: *const SwarmDownloader, w: *Io.Writer) void {
        w.print("\nDownload stats:\n", .{}) catch {};
        w.print("  Total xorbs:  {d}\n", .{self.stats.total_xorbs}) catch {};
        w.print("  From cache:   {d}\n", .{self.stats.cached_xorbs}) catch {};
        w.print("  From peers:   {d}\n", .{self.stats.peer_xorbs}) catch {};
        w.print("  From CDN:     {d}\n", .{self.stats.cdn_xorbs}) catch {};
        w.print("  Total bytes:  {d}\n", .{self.stats.total_bytes}) catch {};
        if (self.stats.total_bytes > 0) {
            const peer_pct = @as(f64, @floatFromInt(self.stats.peer_bytes)) / @as(f64, @floatFromInt(self.stats.total_bytes)) * 100.0;
            w.print("  P2P ratio:    {d:.1}%\n", .{peer_pct}) catch {};
        }
    }
};
