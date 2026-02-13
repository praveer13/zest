/// Swarm orchestrator: coordinates BT-compliant P2P download + CDN fallback.
///
/// For each needed xorb:
///   1. Check xorb cache (already have it?)
///   2. Compute info_hash = SHA-1("zest-xet-v1:" || xorb_hash)
///   3. DHT get_peers(info_hash) + BT tracker announce
///   4. Connect to peers via BtPeer, BT handshake + BEP 10 handshake
///   5. For each chunk in xorb: CHUNK_REQUEST → CHUNK_RESPONSE, verify BLAKE3
///   6. Reassemble xorb from chunks, cache it
///   7. CDN fallback for any missing chunks
///   8. announce_peer to DHT (we now have it)
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const config = @import("config.zig");
const storage = @import("storage.zig");
const peer_id_mod = @import("peer_id.zig");
const bt_peer_mod = @import("bt_peer.zig");
const bt_tracker_mod = @import("bt_tracker.zig");
const dht_mod = @import("dht.zig");
const peer_pool_mod = @import("peer_pool.zig");
const Blake3 = std.crypto.hash.Blake3;

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

        var buf: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buf);
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
            storage.ensureDirRecursive(self.io, cache_path[0..sep]) catch {};
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
    // BT-specific stats
    peer_chunks: usize,
    cdn_chunks: usize,
    peers_connected: usize,
    dht_lookups: usize,
};

pub const SwarmDownloader = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *const config.Config,
    http_client: std.http.Client,
    cache: XorbCache,
    stats: DownloadStats,
    // BT protocol layer
    our_peer_id: [20]u8,
    dht_client: ?dht_mod.Dht,
    bt_tracker: ?bt_tracker_mod.BtTrackerClient,
    enable_p2p: bool,
    // Connection pool for reuse across xorbs
    peer_pool: peer_pool_mod.PeerPool,
    // Optional xorb registry for seed-while-downloading
    xorb_registry: ?*storage.XorbRegistry,
    // Direct peers specified via --peer flag (tried before DHT/tracker)
    direct_peers: std.ArrayList(net.IpAddress),

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        cfg_ptr: *const config.Config,
        tracker_url: ?[]const u8,
        enable_p2p: bool,
    ) !SwarmDownloader {
        var dht_client: ?dht_mod.Dht = null;
        var bt_tracker: ?bt_tracker_mod.BtTrackerClient = null;

        if (enable_p2p) {
            // Initialize DHT
            dht_client = dht_mod.Dht.init(allocator, io, cfg_ptr.dht_port) catch null;

            // Initialize BT tracker if URL provided
            if (tracker_url) |url| {
                bt_tracker = bt_tracker_mod.BtTrackerClient.init(
                    allocator,
                    io,
                    url,
                    cfg_ptr.peer_id,
                ) catch null;
            }
        }

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg_ptr,
            .http_client = .{ .allocator = allocator, .io = io },
            .cache = XorbCache.init(allocator, io, cfg_ptr),
            .stats = std.mem.zeroes(DownloadStats),
            .our_peer_id = cfg_ptr.peer_id,
            .dht_client = dht_client,
            .bt_tracker = bt_tracker,
            .enable_p2p = enable_p2p,
            .peer_pool = peer_pool_mod.PeerPool.init(allocator, io, cfg_ptr.peer_id, cfg_ptr.listen_port, cfg_ptr.max_peers),
            .xorb_registry = null,
            .direct_peers = .empty,
        };
    }

    /// Add a direct peer address (from --peer flag).
    pub fn addDirectPeer(self: *SwarmDownloader, address: net.IpAddress) !void {
        try self.direct_peers.append(self.allocator, address);
    }

    pub fn deinit(self: *SwarmDownloader) void {
        self.http_client.deinit();
        if (self.dht_client) |*d| d.deinit();
        if (self.bt_tracker) |*t| t.deinit();
        self.peer_pool.deinit();
        self.direct_peers.deinit(self.allocator);
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

        // Step 2: Try P2P via BT protocol
        if (self.enable_p2p) {
            if (self.tryBtPeerDownload(term)) {
                return;
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
        self.stats.cdn_chunks += 1;

        // Seed-while-downloading: register in xorb registry immediately
        if (self.xorb_registry) |registry| {
            registry.add(hex) catch {};
        }
    }

    /// Try to download a xorb via BT peers (DHT + tracker discovery).
    /// Uses connection pool to reuse existing connections.
    /// Returns true if the xorb was downloaded and cached successfully.
    /// Thread-safe: PeerPool.mutex protects the connection map,
    /// BtPeer.mutex serializes per-peer TCP stream access.
    pub fn tryBtPeerDownload(self: *SwarmDownloader, term: *const Term) bool {
        const info_hash = peer_id_mod.computeInfoHash(term.xorb_hash);

        // Collect peer addresses from all discovery sources
        var peer_addrs: std.ArrayList(net.IpAddress) = .empty;
        defer peer_addrs.deinit(self.allocator);

        // Direct peers first (from --peer flag)
        for (self.direct_peers.items) |addr| {
            peer_addrs.append(self.allocator, addr) catch {};
        }

        // Discover peers via DHT
        if (self.dht_client) |*d| {
            self.stats.dht_lookups += 1;
            const peers = d.getPeers(info_hash) catch &[_]dht_mod.CompactPeer{};
            defer if (peers.len > 0) self.allocator.free(peers);

            for (peers) |peer| {
                peer_addrs.append(self.allocator, peer.address) catch {};
            }
        }

        // Discover peers via BT tracker
        if (self.bt_tracker) |*t| {
            const resp = t.announce(info_hash, self.cfg.listen_port, .started) catch {
                return self.tryPeersSequential(peer_addrs.items, info_hash, term);
            };
            defer @constCast(&resp).deinit();

            for (resp.peers) |peer| {
                peer_addrs.append(self.allocator, peer.address) catch {};
            }
        }

        return self.tryPeersSequential(peer_addrs.items, info_hash, term);
    }

    /// Try downloading from multiple peers, using the connection pool.
    fn tryPeersSequential(self: *SwarmDownloader, addrs: []const net.IpAddress, info_hash: [20]u8, term: *const Term) bool {
        for (addrs) |address| {
            if (self.tryPooledChunkDownload(address, info_hash, term)) {
                return true;
            }
        }
        return false;
    }

    /// Try to download xorb data from a single BT peer, using the connection pool.
    fn tryPooledChunkDownload(self: *SwarmDownloader, address: net.IpAddress, info_hash: [20]u8, term: *const Term) bool {
        const peer = self.peer_pool.getOrConnect(address, info_hash) catch return false;

        if (!peer.supports_xet) return false;

        self.stats.peers_connected += 1;

        // Request the xorb chunk
        const data = peer.requestChunk(term.xorb_hash) catch |err| {
            // Connection error — remove from pool so next attempt reconnects
            switch (err) {
                error.ChunkNotFound, error.ChunkError => {},
                else => self.peer_pool.remove(address),
            }
            return false;
        };
        defer self.allocator.free(data);

        // Cache and record stats
        self.cache.put(&term.xorb_hash_hex, data) catch {};
        self.stats.peer_xorbs += 1;
        self.stats.peer_bytes += data.len;
        self.stats.total_bytes += data.len;
        self.stats.peer_chunks += 1;

        // Seed-while-downloading: register in xorb registry immediately
        if (self.xorb_registry) |registry| {
            registry.add(&term.xorb_hash_hex) catch {};
        }

        // Announce to DHT that we now have this xorb
        if (self.dht_client) |*d| {
            d.announcePeer(info_hash, self.cfg.listen_port) catch {};
        }

        return true;
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

    /// Announce all provided xorb hashes to the swarm.
    pub fn announceToSwarm(self: *SwarmDownloader, xorb_hashes: []const [32]u8) !void {
        for (xorb_hashes) |xorb_hash| {
            const info_hash = peer_id_mod.computeInfoHash(xorb_hash);

            if (self.dht_client) |*d| {
                d.announcePeer(info_hash, self.cfg.listen_port) catch {};
            }

            if (self.bt_tracker) |*t| {
                _ = t.announce(info_hash, self.cfg.listen_port, .started) catch {};
            }
        }
    }

    pub fn printStats(self: *const SwarmDownloader, w: *Io.Writer) void {
        w.print("\nDownload stats:\n", .{}) catch {};
        w.print("  Total xorbs:     {d}\n", .{self.stats.total_xorbs}) catch {};
        w.print("  From cache:      {d}\n", .{self.stats.cached_xorbs}) catch {};
        w.print("  From peers:      {d}\n", .{self.stats.peer_xorbs}) catch {};
        w.print("  From CDN:        {d}\n", .{self.stats.cdn_xorbs}) catch {};
        w.print("  Total bytes:     {d}\n", .{self.stats.total_bytes}) catch {};
        w.print("  Peers connected: {d}\n", .{self.stats.peers_connected}) catch {};
        w.print("  DHT lookups:     {d}\n", .{self.stats.dht_lookups}) catch {};
        if (self.stats.total_bytes > 0) {
            const peer_pct = @as(f64, @floatFromInt(self.stats.peer_bytes)) / @as(f64, @floatFromInt(self.stats.total_bytes)) * 100.0;
            w.print("  P2P ratio:       {d:.1}%\n", .{peer_pct}) catch {};
        }
    }
};
