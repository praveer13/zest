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
const hash_mod = @import("hash.zig");
const xorb_mod = @import("xorb.zig");
const cas_mod = @import("cas.zig");
const cdn_mod = @import("cdn.zig");
const peer_mod = @import("peer.zig");
const tracker_mod = @import("tracker.zig");
const config = @import("config.zig");

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
    cfg: *const config.Config,
    cdn: cdn_mod.CdnDownloader,
    tracker: ?tracker_mod.TrackerClient,
    cache: xorb_mod.XorbCache,
    stats: DownloadStats,

    pub fn init(allocator: std.mem.Allocator, cfg_ptr: *const config.Config, tracker_url: ?[]const u8) !SwarmDownloader {
        var tracker: ?tracker_mod.TrackerClient = null;
        if (tracker_url) |url| {
            tracker = try tracker_mod.TrackerClient.init(allocator, url);
        }

        return .{
            .allocator = allocator,
            .cfg = cfg_ptr,
            .cdn = cdn_mod.CdnDownloader.init(allocator),
            .tracker = tracker,
            .cache = xorb_mod.XorbCache.init(allocator, cfg_ptr),
            .stats = std.mem.zeroes(DownloadStats),
        };
    }

    pub fn deinit(self: *SwarmDownloader) void {
        self.cdn.deinit();
        if (self.tracker) |*t| t.deinit();
    }

    /// Download all xorbs needed for a file's reconstruction.
    pub fn downloadXorbs(self: *SwarmDownloader, recon: *const cas_mod.ReconstructionInfo) !void {
        self.stats.total_xorbs = recon.terms.len;

        for (recon.terms) |*term| {
            try self.downloadSingleXorb(term);
        }
    }

    fn downloadSingleXorb(self: *SwarmDownloader, term: *const xorb_mod.Term) !void {
        const hex = &term.xorb_hash_hex;

        // Step 1: Check local cache
        if (self.cache.has(hex)) {
            self.stats.cached_xorbs += 1;
            return;
        }

        // Step 2: Try peers via tracker
        if (self.tracker) |*tracker| {
            const peers = tracker.getPeers(hex) catch &[_]tracker_mod.TrackerPeer{};
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
        var result = try self.cdn.downloadTerm(term);
        defer result.deinit();

        // Cache the downloaded xorb
        self.cache.put(hex, result.data) catch {};
        self.stats.cdn_xorbs += 1;
        self.stats.cdn_bytes += result.data.len;
        self.stats.total_bytes += result.data.len;
    }

    fn tryPeerDownload(self: *SwarmDownloader, addr_str: []const u8, term: *const xorb_mod.Term) ![]u8 {
        const address = try peer_mod.parseAddress(addr_str);
        var conn = try peer_mod.PeerConnection.connect(self.allocator, address);
        defer conn.deinit();

        // Simple handshake with zeros for peer ID (we don't have crypto keys yet in MVP)
        try conn.handshake([_]u8{0} ** 32, 0, 0);

        return try conn.requestXorb(term.xorb_hash);
    }

    pub fn printStats(self: *const SwarmDownloader) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("\nDownload stats:\n", .{}) catch {};
        stdout.print("  Total xorbs:  {d}\n", .{self.stats.total_xorbs}) catch {};
        stdout.print("  From cache:   {d}\n", .{self.stats.cached_xorbs}) catch {};
        stdout.print("  From peers:   {d}\n", .{self.stats.peer_xorbs}) catch {};
        stdout.print("  From CDN:     {d}\n", .{self.stats.cdn_xorbs}) catch {};
        stdout.print("  Total bytes:  {d}\n", .{self.stats.total_bytes}) catch {};
        if (self.stats.total_bytes > 0) {
            const peer_pct = @as(f64, @floatFromInt(self.stats.peer_bytes)) / @as(f64, @floatFromInt(self.stats.total_bytes)) * 100.0;
            stdout.print("  P2P ratio:    {d:.1}%\n", .{peer_pct}) catch {};
        }
    }
};
