/// Connection pool for BT peers — maintains persistent connections
/// across multiple xorb downloads to avoid repeated handshakes.
///
/// Each connection is keyed by IP address. When the info_hash changes
/// (different xorb), the existing connection is reused since BEP XET
/// chunk requests carry the chunk hash directly.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const bt_peer_mod = @import("bt_peer.zig");

pub const PeerPool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    our_peer_id: [20]u8,
    listen_port: u16,
    max_peers: u16,
    /// Active connections keyed by serialized address bytes
    connections: std.AutoHashMap(AddressKey, *bt_peer_mod.BtPeer),
    /// Protects hashmap lookup/insert only (held briefly).
    mutex: Io.Mutex,

    const AddressKey = u64;

    fn addressToKey(address: net.IpAddress) AddressKey {
        // Pack IPv4 bytes (4 bytes) + port (2 bytes) into u64
        const ip4 = address.ip4;
        return @as(u64, ip4.bytes[0]) << 40 |
            @as(u64, ip4.bytes[1]) << 32 |
            @as(u64, ip4.bytes[2]) << 24 |
            @as(u64, ip4.bytes[3]) << 16 |
            @as(u64, ip4.port);
    }

    pub fn init(allocator: std.mem.Allocator, io: Io, our_peer_id: [20]u8, listen_port: u16, max_peers: u16) PeerPool {
        return .{
            .allocator = allocator,
            .io = io,
            .our_peer_id = our_peer_id,
            .listen_port = listen_port,
            .max_peers = max_peers,
            .connections = std.AutoHashMap(AddressKey, *bt_peer_mod.BtPeer).init(allocator),
            .mutex = Io.Mutex.init,
        };
    }

    /// Get an existing connection or create a new one.
    /// The returned peer is ready for chunk requests.
    /// Thread-safe: mutex protects hashmap only (held briefly).
    /// Connect + handshake runs outside the lock.
    pub fn getOrConnect(self: *PeerPool, address: net.IpAddress, info_hash: [20]u8) !*bt_peer_mod.BtPeer {
        const key = addressToKey(address);

        // Fast path: existing connection (brief lock)
        self.mutex.lockUncancelable(self.io);
        if (self.connections.get(key)) |peer| {
            self.mutex.unlock(self.io);
            return peer;
        }
        self.mutex.unlock(self.io);

        // Slow path: connect + handshake (no lock held)
        const peer = try self.allocator.create(bt_peer_mod.BtPeer);
        peer.* = try bt_peer_mod.BtPeer.connect(
            self.allocator,
            self.io,
            address,
            info_hash,
            self.our_peer_id,
            self.listen_port,
        );
        errdefer {
            peer.deinit();
            self.allocator.destroy(peer);
        }
        try peer.performHandshake();

        // Re-check and insert (brief lock)
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.connections.get(key)) |existing| {
            // Another task connected to the same peer; use theirs
            peer.deinit();
            self.allocator.destroy(peer);
            return existing;
        }

        if (self.connections.count() >= self.max_peers) {
            self.evictOne();
        }

        try self.connections.put(key, peer);
        return peer;
    }

    /// Remove a specific peer from the pool (e.g., on error).
    /// Thread-safe: acquires mutex for hashmap removal.
    pub fn remove(self: *PeerPool, address: net.IpAddress) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const key = addressToKey(address);
        if (self.connections.fetchRemove(key)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Evict one peer to make room.
    fn evictOne(self: *PeerPool) void {
        var it = self.connections.iterator();
        if (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            self.connections.removeByPtr(entry.key_ptr);
        }
    }

    /// Number of active connections.
    pub fn count(self: *const PeerPool) u32 {
        return self.connections.count();
    }

    pub fn deinit(self: *PeerPool) void {
        var it = self.connections.valueIterator();
        while (it.next()) |peer_ptr| {
            peer_ptr.*.deinit();
            self.allocator.destroy(peer_ptr.*);
        }
        self.connections.deinit();
    }
};

// ── Tests ──

test "PeerPool init and deinit" {
    var pool = PeerPool.init(
        std.testing.allocator,
        std.testing.io,
        [_]u8{0} ** 20,
        6881,
        50,
    );
    defer pool.deinit();
    try std.testing.expectEqual(@as(u32, 0), pool.count());
}

test "PeerPool addressToKey" {
    // Verify different addresses produce different keys
    const key1 = PeerPool.addressToKey(.{ .ip4 = net.Ip4Address.loopback(6881) });
    const key2 = PeerPool.addressToKey(.{ .ip4 = net.Ip4Address.loopback(6882) });
    try std.testing.expect(key1 != key2);
}
