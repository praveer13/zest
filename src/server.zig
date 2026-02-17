/// BT peer server — accepts incoming BitTorrent connections for seeding.
///
/// Listens on config.listen_port (default 6881), handles:
///   1. BT handshake (verify info_hash, exchange peer IDs)
///   2. BEP 10 extended handshake (advertise ut_xet)
///   3. CHUNK_REQUEST → look up chunk in cache → CHUNK_RESPONSE
///
/// Uses Io.Group for concurrent peer handling.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const xet = @import("xet");
const config = @import("config.zig");
const storage = @import("storage.zig");
const swarm_mod = @import("swarm.zig");
const bt_wire = @import("bt_wire.zig");
const bep_xet = @import("bep_xet.zig");
const peer_id_mod = @import("peer_id.zig");

pub const BtServer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *const config.Config,
    xorb_cache: swarm_mod.XorbCache,
    listener: ?net.Server,
    shutdown_flag: std.atomic.Value(bool),
    active_peers: std.atomic.Value(u32),
    chunks_served: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, io: Io, cfg: *const config.Config) BtServer {
        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .xorb_cache = swarm_mod.XorbCache.init(allocator, io, cfg),
            .listener = null,
            .shutdown_flag = std.atomic.Value(bool).init(false),
            .active_peers = std.atomic.Value(u32).init(0),
            .chunks_served = std.atomic.Value(u64).init(0),
        };
    }

    /// Start listening and accepting connections. Blocks until shutdown.
    /// Handles multiple peers concurrently via Io.Group.
    pub fn run(self: *BtServer) !void {
        const addr: net.IpAddress = .{ .ip4 = .unspecified(self.cfg.listen_port) };
        var listener = try addr.listen(self.io, .{
            .reuse_address = true,
        });
        self.listener = listener;
        defer {
            listener.deinit(self.io);
            self.listener = null;
        }

        var group: Io.Group = Io.Group.init;

        while (!self.shutdown_flag.load(.acquire)) {
            const stream = listener.accept(self.io) catch {
                if (self.shutdown_flag.load(.acquire)) break;
                continue;
            };

            const ctx = self.allocator.create(PeerContext) catch {
                stream.close(self.io);
                continue;
            };
            ctx.* = .{ .server = self, .stream = stream };

            // Spawn peer handler concurrently
            group.concurrent(self.io, handlePeerConcurrent, .{ctx}) catch |err| {
                switch (err) {
                    error.ConcurrencyUnavailable => handlePeerConcurrent(ctx),
                }
            };
        }

        // Wait for all active peer handlers to finish
        group.await(self.io) catch {};
    }

    /// Signal the server to stop accepting new connections.
    pub fn shutdown(self: *BtServer) void {
        self.shutdown_flag.store(true, .release);
        // Close the listener socket to unblock accept()
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
    }

    /// Context for a concurrent peer handler task.
    const PeerContext = struct {
        server: *BtServer,
        stream: net.Stream,
    };

    /// Entry point for concurrent peer handling via Io.Group.
    fn handlePeerConcurrent(ctx: *PeerContext) void {
        ctx.server.handlePeerConnection(ctx.stream);
        ctx.server.allocator.destroy(ctx);
    }

    /// Handle a single incoming BT peer connection.
    fn handlePeerConnection(self: *BtServer, stream: net.Stream) void {
        _ = self.active_peers.fetchAdd(1, .monotonic);
        defer _ = self.active_peers.fetchSub(1, .monotonic);
        defer stream.close(self.io);

        self.handlePeerInner(stream) catch {};
    }

    fn handlePeerInner(self: *BtServer, stream: net.Stream) !void {
        var read_buf: [16384]u8 = undefined;
        var write_buf: [16384]u8 = undefined;
        var sr = stream.reader(self.io, &read_buf);
        var sw = stream.writer(self.io, &write_buf);
        const reader = &sr.interface;
        const writer = &sw.interface;

        // Step 1: Read peer's BT handshake
        const peer_hs = try bt_wire.readHandshake(reader);

        // Step 2: Send our BT handshake (echo back their info_hash)
        try bt_wire.writeHandshake(writer, peer_hs.info_hash, self.cfg.peer_id);
        try writer.flush();

        // Step 3: Check BEP 10 support
        if (!peer_hs.supportsBep10()) return;

        // Step 4: Send BEP 10 extended handshake
        const ext_payload = try bep_xet.makeExtHandshakePayload(self.allocator, self.cfg.listen_port);
        defer self.allocator.free(ext_payload);
        try bt_wire.writeExtended(writer, 0, ext_payload);

        // Send unchoke + interested
        try bt_wire.writeMessage(writer, .unchoke, &.{});
        try bt_wire.writeMessage(writer, .interested, &.{});
        try writer.flush();

        // Step 5: Read peer's extended handshake
        const msg = (try bt_wire.readMessage(reader, self.allocator)) orelse return;
        defer if (msg.payload.len > 0) self.allocator.free(msg.payload);

        if (msg.msg_id == .extended and msg.payload.len > 0) {
            const ext = try bt_wire.parseExtended(msg.payload);
            if (ext.ext_id == 0) {
                // Parse peer's extended handshake (capabilities acknowledged)
                _ = try bep_xet.parseExtHandshake(self.allocator, ext.data);
            }
        }

        // Step 6: Serve loop — respond to incoming messages
        self.serveLoop(reader, writer);
    }

    /// Main serve loop: read messages, respond to CHUNK_REQUESTs.
    fn serveLoop(self: *BtServer, reader: *Io.Reader, writer: *Io.Writer) void {
        while (!self.shutdown_flag.load(.acquire)) {
            const msg = bt_wire.readMessage(reader, self.allocator) catch return;
            const m = msg orelse continue;
            defer if (m.payload.len > 0) self.allocator.free(m.payload);

            switch (m.msg_id) {
                .extended => {
                    self.handleExtendedMessage(m.payload, writer) catch return;
                },
                .interested, .unchoke, .not_interested, .choke => {},
                else => {},
            }
        }
    }

    fn handleExtendedMessage(self: *BtServer, payload: []const u8, writer: *Io.Writer) !void {
        const ext = bt_wire.parseExtended(payload) catch return;
        if (ext.ext_id == 0) return; // Extended handshake, already handled

        const xet_msg = bep_xet.decodeMessage(ext.data) catch return;
        switch (xet_msg) {
            .chunk_request => |req| {
                try self.handleChunkRequest(writer, req.request_id, req.chunk_hash, req.range_start, req.range_end);
            },
            .chunk_response, .chunk_not_found, .chunk_error => {},
        }
    }

    fn handleChunkRequest(self: *BtServer, writer: *Io.Writer, request_id: u32, chunk_hash: [32]u8, range_start: u32, range_end: u32) !void {
        _ = range_end; // Used for future filtering; lookup is by hash + range_start

        // Look up in chunk cache first
        const data = try storage.readChunk(self.allocator, self.io, self.cfg, chunk_hash);
        if (data) |chunk_data| {
            defer self.allocator.free(chunk_data);
            try bep_xet.encodeChunkResponse(writer, 1, request_id, 0, chunk_data);
            try writer.flush();
            _ = self.chunks_served.fetchAdd(1, .monotonic);
            return;
        }

        // Fall back to xorb cache (range-aware lookup)
        // Must use zig-xet's hashToHex (little-endian u64 encoding) to match
        // the cache keys written by xet_bridge.zig.
        const hex = xet.hashing.hashToHex(chunk_hash);
        if (try self.xorb_cache.getWithRange(&hex, range_start)) |result| {
            defer self.allocator.free(result.data);
            try bep_xet.encodeChunkResponse(writer, 1, request_id, result.chunk_offset, result.data);
            try writer.flush();
            _ = self.chunks_served.fetchAdd(1, .monotonic);
            return;
        }

        // Not found anywhere
        try bep_xet.encodeChunkNotFound(writer, 1, request_id, chunk_hash);
        try writer.flush();
    }

    pub fn getStats(self: *const BtServer) ServerStats {
        return .{
            .active_peers = self.active_peers.load(.monotonic),
            .chunks_served = self.chunks_served.load(.monotonic),
        };
    }
};

pub const ServerStats = struct {
    active_peers: u32,
    chunks_served: u64,
};

// ── Tests ──

test "BtServer init" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    const server = BtServer.init(std.testing.allocator, std.testing.io, &cfg);
    try std.testing.expect(!server.shutdown_flag.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), server.active_peers.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), server.chunks_served.load(.monotonic));
}

test "BtServer shutdown flag" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    var server = BtServer.init(std.testing.allocator, std.testing.io, &cfg);
    try std.testing.expect(!server.shutdown_flag.load(.monotonic));
    server.shutdown();
    try std.testing.expect(server.shutdown_flag.load(.monotonic));
}

test "ServerStats default" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    const server = BtServer.init(std.testing.allocator, std.testing.io, &cfg);
    const stats = server.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.active_peers);
    try std.testing.expectEqual(@as(u64, 0), stats.chunks_served);
}
