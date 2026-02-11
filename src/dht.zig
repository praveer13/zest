/// Kademlia DHT (BEP 5) for decentralized peer discovery.
///
/// Uses UDP with bencoded KRPC messages. Provides:
///   - get_peers(info_hash) → list of peers for a torrent/xorb
///   - announce_peer(info_hash, port) → announce we have a torrent/xorb
///   - find_node(target) → find closer nodes
///   - ping → liveness check
///
/// Bootstrap nodes: router.bittorrent.com:6881, dht.transmissionbt.com:6881
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const bencode = @import("bencode.zig");
const Sha1 = std.crypto.hash.Sha1;

pub const K = 8; // k-bucket size
pub const ALPHA = 3; // lookup concurrency
pub const NODE_ID_LEN = 20;
pub const MAX_UDP_SIZE = 1500; // typical MTU

pub const NodeId = [NODE_ID_LEN]u8;

pub const NodeInfo = struct {
    id: NodeId,
    address: net.IpAddress,
};

pub const CompactPeer = struct {
    address: net.IpAddress,
};

/// Bootstrap nodes for the public BT DHT.
pub const bootstrap_nodes = [_]struct { host: []const u8, port: u16 }{
    .{ .host = "router.bittorrent.com", .port = 6881 },
    .{ .host = "dht.transmissionbt.com", .port = 6881 },
};

// ── XOR distance ──

/// Compute XOR distance between two node IDs.
pub fn xorDistance(a: NodeId, b: NodeId) NodeId {
    var result: NodeId = undefined;
    for (0..NODE_ID_LEN) |i| {
        result[i] = a[i] ^ b[i];
    }
    return result;
}

/// Compare XOR distances: is `a` closer to `target` than `b`?
pub fn isCloser(target: NodeId, a: NodeId, b: NodeId) bool {
    const dist_a = xorDistance(target, a);
    const dist_b = xorDistance(target, b);
    return std.mem.order(u8, &dist_a, &dist_b) == .lt;
}

/// Find the bucket index for a node ID relative to our own ID.
/// Returns the index of the highest differing bit (0-159), or null if IDs match.
pub fn bucketIndex(own_id: NodeId, node_id: NodeId) ?u8 {
    for (0..NODE_ID_LEN) |i| {
        const diff = own_id[i] ^ node_id[i];
        if (diff != 0) {
            // Find the highest set bit in diff
            const leading = @clz(diff);
            return @intCast(i * 8 + leading);
        }
    }
    return null; // Same ID
}

// ── K-Bucket ──

pub const KBucket = struct {
    nodes: [K]?NodeInfo,
    count: u8,

    pub const empty: KBucket = .{
        .nodes = [_]?NodeInfo{null} ** K,
        .count = 0,
    };

    /// Insert a node. If bucket is full, the new node is ignored (simplified eviction).
    pub fn insert(self: *KBucket, node: NodeInfo) void {
        // Check if already present (update position)
        for (0..self.count) |i| {
            if (self.nodes[i]) |existing| {
                if (std.mem.eql(u8, &existing.id, &node.id)) {
                    self.nodes[i] = node;
                    return;
                }
            }
        }
        // Add if space available
        if (self.count < K) {
            self.nodes[self.count] = node;
            self.count += 1;
        }
    }

    /// Remove a node by ID.
    pub fn remove(self: *KBucket, id: NodeId) void {
        for (0..self.count) |i| {
            if (self.nodes[i]) |existing| {
                if (std.mem.eql(u8, &existing.id, &id)) {
                    // Shift remaining nodes
                    var j = i;
                    while (j + 1 < self.count) : (j += 1) {
                        self.nodes[j] = self.nodes[j + 1];
                    }
                    self.nodes[self.count - 1] = null;
                    self.count -= 1;
                    return;
                }
            }
        }
    }
};

// ── Routing Table ──

pub const RoutingTable = struct {
    own_id: NodeId,
    buckets: [160]KBucket,

    pub fn init(own_id: NodeId) RoutingTable {
        return .{
            .own_id = own_id,
            .buckets = [_]KBucket{KBucket.empty} ** 160,
        };
    }

    /// Insert a node into the appropriate bucket.
    pub fn insert(self: *RoutingTable, node: NodeInfo) void {
        const idx = bucketIndex(self.own_id, node.id) orelse return;
        self.buckets[idx].insert(node);
    }

    /// Find the K closest nodes to a target.
    pub fn findClosest(self: *const RoutingTable, target: NodeId, result: []NodeInfo) u8 {
        var count: u8 = 0;

        // Collect all nodes
        for (&self.buckets) |*bucket| {
            for (0..bucket.count) |i| {
                if (bucket.nodes[i]) |node| {
                    if (count < result.len) {
                        result[count] = node;
                        count += 1;
                    } else {
                        // Replace the farthest node if this one is closer
                        var farthest_idx: u8 = 0;
                        for (1..count) |j| {
                            if (!isCloser(target, result[j].id, result[farthest_idx].id)) {
                                farthest_idx = @intCast(j);
                            }
                        }
                        if (isCloser(target, node.id, result[farthest_idx].id)) {
                            result[farthest_idx] = node;
                        }
                    }
                }
            }
        }

        return count;
    }
};

// ── KRPC Message Building ──

/// Build a KRPC ping query.
pub fn buildPing(allocator: std.mem.Allocator, tid: [2]u8, own_id: NodeId) ![]u8 {
    // {"t":"xx", "y":"q", "q":"ping", "a":{"id":"..."}}
    const a_entries = try allocator.alloc(bencode.DictEntry, 1);
    defer allocator.free(a_entries);
    a_entries[0] = .{ .key = "id", .value = .{ .string = &own_id } };

    const entries = try allocator.alloc(bencode.DictEntry, 4);
    defer allocator.free(entries);
    entries[0] = .{ .key = "a", .value = .{ .dict = a_entries } };
    entries[1] = .{ .key = "q", .value = .{ .string = "ping" } };
    entries[2] = .{ .key = "t", .value = .{ .string = &tid } };
    entries[3] = .{ .key = "y", .value = .{ .string = "q" } };

    return try bencode.encode(allocator, .{ .dict = entries });
}

/// Build a KRPC find_node query.
pub fn buildFindNode(allocator: std.mem.Allocator, tid: [2]u8, own_id: NodeId, target: NodeId) ![]u8 {
    const a_entries = try allocator.alloc(bencode.DictEntry, 2);
    defer allocator.free(a_entries);
    a_entries[0] = .{ .key = "id", .value = .{ .string = &own_id } };
    a_entries[1] = .{ .key = "target", .value = .{ .string = &target } };

    const entries = try allocator.alloc(bencode.DictEntry, 4);
    defer allocator.free(entries);
    entries[0] = .{ .key = "a", .value = .{ .dict = a_entries } };
    entries[1] = .{ .key = "q", .value = .{ .string = "find_node" } };
    entries[2] = .{ .key = "t", .value = .{ .string = &tid } };
    entries[3] = .{ .key = "y", .value = .{ .string = "q" } };

    return try bencode.encode(allocator, .{ .dict = entries });
}

/// Build a KRPC get_peers query.
pub fn buildGetPeers(allocator: std.mem.Allocator, tid: [2]u8, own_id: NodeId, info_hash: [20]u8) ![]u8 {
    const a_entries = try allocator.alloc(bencode.DictEntry, 2);
    defer allocator.free(a_entries);
    a_entries[0] = .{ .key = "id", .value = .{ .string = &own_id } };
    a_entries[1] = .{ .key = "info_hash", .value = .{ .string = &info_hash } };

    const entries = try allocator.alloc(bencode.DictEntry, 4);
    defer allocator.free(entries);
    entries[0] = .{ .key = "a", .value = .{ .dict = a_entries } };
    entries[1] = .{ .key = "q", .value = .{ .string = "get_peers" } };
    entries[2] = .{ .key = "t", .value = .{ .string = &tid } };
    entries[3] = .{ .key = "y", .value = .{ .string = "q" } };

    return try bencode.encode(allocator, .{ .dict = entries });
}

/// Build a KRPC announce_peer query.
pub fn buildAnnouncePeer(allocator: std.mem.Allocator, tid: [2]u8, own_id: NodeId, info_hash: [20]u8, port: u16, token: []const u8) ![]u8 {
    const a_entries = try allocator.alloc(bencode.DictEntry, 5);
    defer allocator.free(a_entries);
    a_entries[0] = .{ .key = "id", .value = .{ .string = &own_id } };
    a_entries[1] = .{ .key = "implied_port", .value = .{ .integer = 0 } };
    a_entries[2] = .{ .key = "info_hash", .value = .{ .string = &info_hash } };
    a_entries[3] = .{ .key = "port", .value = .{ .integer = @intCast(port) } };
    a_entries[4] = .{ .key = "token", .value = .{ .string = token } };

    const entries = try allocator.alloc(bencode.DictEntry, 4);
    defer allocator.free(entries);
    entries[0] = .{ .key = "a", .value = .{ .dict = a_entries } };
    entries[1] = .{ .key = "q", .value = .{ .string = "announce_peer" } };
    entries[2] = .{ .key = "t", .value = .{ .string = &tid } };
    entries[3] = .{ .key = "y", .value = .{ .string = "q" } };

    return try bencode.encode(allocator, .{ .dict = entries });
}

// ── KRPC Response Parsing ──

pub const KrpcResponse = union(enum) {
    pong: NodeId,
    find_node: struct { id: NodeId, nodes: []NodeInfo },
    get_peers: struct { id: NodeId, token: ?[]const u8, peers: []CompactPeer, nodes: []NodeInfo },
    error_response: struct { code: i64, message: []const u8 },
};

/// Parse compact node info: 26 bytes per node (20 ID + 4 IP + 2 port).
pub fn parseCompactNodes(allocator: std.mem.Allocator, data: []const u8) ![]NodeInfo {
    if (data.len % 26 != 0) return &[_]NodeInfo{};
    const count = data.len / 26;

    var nodes = try allocator.alloc(NodeInfo, count);
    errdefer allocator.free(nodes);

    for (0..count) |i| {
        const offset = i * 26;
        var id: NodeId = undefined;
        @memcpy(&id, data[offset .. offset + 20]);
        const ip_bytes = data[offset + 20 .. offset + 24];
        const port = std.mem.readInt(u16, data[offset + 24 .. offset + 26][0..2], .big);

        nodes[i] = .{
            .id = id,
            .address = .{ .ip4 = .{
                .bytes = ip_bytes[0..4].*,
                .port = port,
            } },
        };
    }

    return nodes;
}

/// Parse compact peer info: 6 bytes per peer (4 IP + 2 port).
pub fn parseCompactPeers(allocator: std.mem.Allocator, data: []const u8) ![]CompactPeer {
    if (data.len % 6 != 0) return &[_]CompactPeer{};
    const count = data.len / 6;

    var peers = try allocator.alloc(CompactPeer, count);
    errdefer allocator.free(peers);

    for (0..count) |i| {
        const offset = i * 6;
        const ip_bytes = data[offset .. offset + 4];
        const port = std.mem.readInt(u16, data[offset + 4 .. offset + 6][0..2], .big);

        peers[i] = .{
            .address = .{ .ip4 = .{
                .bytes = ip_bytes[0..4].*,
                .port = port,
            } },
        };
    }

    return peers;
}

/// Encode a node as 26 bytes compact format (20 ID + 4 IP + 2 port).
pub fn encodeCompactNode(node: *const NodeInfo) [26]u8 {
    var buf: [26]u8 = undefined;
    @memcpy(buf[0..20], &node.id);
    switch (node.address) {
        .ip4 => |addr| {
            @memcpy(buf[20..24], &addr.bytes);
            std.mem.writeInt(u16, buf[24..26], addr.port, .big);
        },
        .ip6 => {
            // For now, only encode IPv4; zero out for IPv6
            @memset(buf[20..26], 0);
        },
    }
    return buf;
}

/// Encode a peer as 6 bytes compact format (4 IP + 2 port).
pub fn encodeCompactPeer(address: *const net.IpAddress) [6]u8 {
    var buf: [6]u8 = undefined;
    switch (address.*) {
        .ip4 => |addr| {
            @memcpy(buf[0..4], &addr.bytes);
            std.mem.writeInt(u16, buf[4..6], addr.port, .big);
        },
        .ip6 => {
            @memset(buf[0..6], 0);
        },
    }
    return buf;
}

// ── DHT Client ──

pub const Dht = struct {
    allocator: std.mem.Allocator,
    io: Io,
    own_id: NodeId,
    routing_table: RoutingTable,
    socket: ?net.Socket,
    next_tid: u16,

    pub fn init(allocator: std.mem.Allocator, io: Io, bind_port: u16) !Dht {
        // Generate node ID from random bytes
        var own_id: NodeId = undefined;
        io.random(&own_id);

        // Bind UDP socket
        const addr: net.IpAddress = .{ .ip4 = .unspecified(bind_port) };
        const socket = addr.bind(io, .{ .mode = .dgram }) catch |err| {
            std.debug.print("DHT: failed to bind UDP port {d}: {}\n", .{ bind_port, err });
            return .{
                .allocator = allocator,
                .io = io,
                .own_id = own_id,
                .routing_table = RoutingTable.init(own_id),
                .socket = null,
                .next_tid = 0,
            };
        };

        return .{
            .allocator = allocator,
            .io = io,
            .own_id = own_id,
            .routing_table = RoutingTable.init(own_id),
            .socket = socket,
            .next_tid = 0,
        };
    }

    pub fn deinit(self: *Dht) void {
        if (self.socket) |s| s.close(self.io);
    }

    fn nextTid(self: *Dht) [2]u8 {
        const tid = self.next_tid;
        self.next_tid +%= 1;
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, tid, .big);
        return buf;
    }

    /// Send a KRPC message to a node.
    pub fn sendKrpc(self: *Dht, dest: *const net.IpAddress, data: []const u8) !void {
        const sock = self.socket orelse return error.NoSocket;
        try sock.send(self.io, dest, data);
    }

    /// Send a ping to a node.
    pub fn ping(self: *Dht, dest: *const net.IpAddress) !void {
        const tid = self.nextTid();
        const msg = try buildPing(self.allocator, tid, self.own_id);
        defer self.allocator.free(msg);
        try self.sendKrpc(dest, msg);
    }

    /// Query for peers that have a specific info_hash.
    /// Sends get_peers to the closest known nodes.
    pub fn getPeers(self: *Dht, info_hash: [20]u8) ![]CompactPeer {
        var closest: [K]NodeInfo = undefined;
        const count = self.routing_table.findClosest(info_hash, &closest);

        var all_peers: std.ArrayList(CompactPeer) = .empty;
        errdefer all_peers.deinit(self.allocator);

        // Send get_peers to closest nodes
        for (0..count) |i| {
            const tid = self.nextTid();
            const msg = try buildGetPeers(self.allocator, tid, self.own_id, info_hash);
            defer self.allocator.free(msg);
            self.sendKrpc(&closest[i].address, msg) catch continue;
        }

        // Receive responses (simplified: try to collect from socket)
        const sock = self.socket orelse return try all_peers.toOwnedSlice(self.allocator);
        var buf: [MAX_UDP_SIZE]u8 = undefined;

        for (0..count) |_| {
            const incoming = sock.receive(self.io, &buf) catch break;
            const val = bencode.decode(self.allocator, incoming.data) catch continue;
            defer bencode.deinit(self.allocator, val);

            const entries = switch (val) {
                .dict => |d| d,
                else => continue,
            };

            // Check for peers in response
            if (bencode.dictGetDict(entries, "r")) |r| {
                if (bencode.dictGetStr(r, "values")) |values_str| {
                    const peers = try parseCompactPeers(self.allocator, values_str);
                    defer self.allocator.free(peers);
                    for (peers) |p| try all_peers.append(self.allocator, p);
                }
                // Also add nodes to routing table
                if (bencode.dictGetStr(r, "nodes")) |nodes_str| {
                    const nodes = try parseCompactNodes(self.allocator, nodes_str);
                    defer self.allocator.free(nodes);
                    for (nodes) |n| self.routing_table.insert(n);
                }
            }
        }

        return try all_peers.toOwnedSlice(self.allocator);
    }

    /// Announce that we have a specific info_hash on a given port.
    pub fn announcePeer(self: *Dht, info_hash: [20]u8, port: u16) !void {
        var closest: [K]NodeInfo = undefined;
        const count = self.routing_table.findClosest(info_hash, &closest);

        // Simple token — in a full implementation, we'd use the token from get_peers
        const token = "zest";

        for (0..count) |i| {
            const tid = self.nextTid();
            const msg = try buildAnnouncePeer(self.allocator, tid, self.own_id, info_hash, port, token);
            defer self.allocator.free(msg);
            self.sendKrpc(&closest[i].address, msg) catch continue;
        }
    }

    /// Bootstrap the DHT by pinging well-known nodes.
    pub fn bootstrap(self: *Dht, nodes: []const NodeInfo) !void {
        for (nodes) |node| {
            self.routing_table.insert(node);
            self.ping(&node.address) catch continue;
        }
    }
};

// ── Tests ──

test "XOR distance" {
    const a = [_]u8{0xFF} ** 20;
    const b = [_]u8{0x00} ** 20;
    const dist = xorDistance(a, b);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xFF} ** 20), &dist);

    // Distance to self is zero
    const zero = xorDistance(a, a);
    try std.testing.expectEqualSlices(u8, &([_]u8{0x00} ** 20), &zero);
}

test "isCloser" {
    const target = [_]u8{0x00} ** 20;
    var a = [_]u8{0x00} ** 20;
    a[19] = 0x01; // distance 1
    var b = [_]u8{0x00} ** 20;
    b[19] = 0x02; // distance 2

    try std.testing.expect(isCloser(target, a, b));
    try std.testing.expect(!isCloser(target, b, a));
}

test "bucketIndex" {
    var own = [_]u8{0x00} ** 20;
    var node = [_]u8{0x00} ** 20;
    node[0] = 0x80; // highest bit differs → bucket 0

    try std.testing.expectEqual(@as(u8, 0), bucketIndex(own, node).?);

    own = [_]u8{0x00} ** 20;
    node = [_]u8{0x00} ** 20;
    node[19] = 0x01; // lowest bit differs → bucket 159

    try std.testing.expectEqual(@as(u8, 159), bucketIndex(own, node).?);
}

test "k-bucket insert and remove" {
    var bucket = KBucket.empty;
    try std.testing.expectEqual(@as(u8, 0), bucket.count);

    const node1 = NodeInfo{
        .id = [_]u8{0x01} ** 20,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 6881 } },
    };
    bucket.insert(node1);
    try std.testing.expectEqual(@as(u8, 1), bucket.count);

    // Insert duplicate — count stays same
    bucket.insert(node1);
    try std.testing.expectEqual(@as(u8, 1), bucket.count);

    // Insert different node
    const node2 = NodeInfo{
        .id = [_]u8{0x02} ** 20,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 2 }, .port = 6882 } },
    };
    bucket.insert(node2);
    try std.testing.expectEqual(@as(u8, 2), bucket.count);

    // Remove node1
    bucket.remove(node1.id);
    try std.testing.expectEqual(@as(u8, 1), bucket.count);
}

test "k-bucket full" {
    var bucket = KBucket.empty;
    // Fill bucket to K
    for (0..K) |i| {
        var id: NodeId = undefined;
        @memset(&id, @intCast(i + 1));
        bucket.insert(.{
            .id = id,
            .address = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, @intCast(i + 1) }, .port = 6881 } },
        });
    }
    try std.testing.expectEqual(@as(u8, K), bucket.count);

    // One more should be ignored (bucket full)
    bucket.insert(.{
        .id = [_]u8{0xFF} ** 20,
        .address = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 99 }, .port = 6881 } },
    });
    try std.testing.expectEqual(@as(u8, K), bucket.count);
}

test "routing table findClosest" {
    var rt = RoutingTable.init([_]u8{0x00} ** 20);

    // Insert some nodes
    for (0..5) |i| {
        var id: NodeId = [_]u8{0x00} ** 20;
        id[19] = @intCast(i + 1);
        rt.insert(.{
            .id = id,
            .address = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, @intCast(i + 1) }, .port = 6881 } },
        });
    }

    var result: [K]NodeInfo = undefined;
    const count = rt.findClosest([_]u8{0x00} ** 20, &result);
    try std.testing.expectEqual(@as(u8, 5), count);
}

test "KRPC ping encoding" {
    const alloc = std.testing.allocator;
    const tid = [2]u8{ 0x00, 0x01 };
    const own_id = [_]u8{0xAB} ** 20;

    const msg = try buildPing(alloc, tid, own_id);
    defer alloc.free(msg);

    // Should be valid bencode
    const val = try bencode.decode(alloc, msg);
    defer bencode.deinit(alloc, val);

    try std.testing.expectEqualSlices(u8, "q", bencode.dictGetStr(val.dict, "y").?);
    try std.testing.expectEqualSlices(u8, "ping", bencode.dictGetStr(val.dict, "q").?);
}

test "KRPC get_peers encoding" {
    const alloc = std.testing.allocator;
    const tid = [2]u8{ 0x00, 0x02 };
    const own_id = [_]u8{0xAB} ** 20;
    const info_hash = [_]u8{0xCD} ** 20;

    const msg = try buildGetPeers(alloc, tid, own_id, info_hash);
    defer alloc.free(msg);

    const val = try bencode.decode(alloc, msg);
    defer bencode.deinit(alloc, val);

    try std.testing.expectEqualSlices(u8, "get_peers", bencode.dictGetStr(val.dict, "q").?);
    const a = bencode.dictGetDict(val.dict, "a") orelse return error.InvalidFormat;
    try std.testing.expectEqualSlices(u8, &info_hash, bencode.dictGetStr(a, "info_hash").?);
}

test "compact node parsing" {
    const alloc = std.testing.allocator;
    // Build one compact node: 20-byte ID + 4-byte IP + 2-byte port
    var data: [26]u8 = undefined;
    @memset(data[0..20], 0xAB); // ID
    data[20] = 192;
    data[21] = 168;
    data[22] = 1;
    data[23] = 1;
    std.mem.writeInt(u16, data[24..26], 6881, .big);

    const nodes = try parseCompactNodes(alloc, &data);
    defer alloc.free(nodes);

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xAB} ** 20), &nodes[0].id);
    switch (nodes[0].address) {
        .ip4 => |addr| {
            try std.testing.expectEqual(@as(u16, 6881), addr.port);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &addr.bytes);
        },
        else => return error.InvalidFormat,
    }
}

test "compact peer parsing" {
    const alloc = std.testing.allocator;
    // Build one compact peer: 4-byte IP + 2-byte port
    var data: [6]u8 = undefined;
    data[0] = 10;
    data[1] = 0;
    data[2] = 0;
    data[3] = 1;
    std.mem.writeInt(u16, data[4..6], 8080, .big);

    const peers = try parseCompactPeers(alloc, &data);
    defer alloc.free(peers);

    try std.testing.expectEqual(@as(usize, 1), peers.len);
    switch (peers[0].address) {
        .ip4 => |addr| {
            try std.testing.expectEqual(@as(u16, 8080), addr.port);
        },
        else => return error.InvalidFormat,
    }
}

test "compact node roundtrip" {
    const alloc = std.testing.allocator;
    const node = NodeInfo{
        .id = [_]u8{0x42} ** 20,
        .address = .{ .ip4 = .{ .bytes = .{ 172, 16, 0, 1 }, .port = 9999 } },
    };

    const encoded = encodeCompactNode(&node);
    const decoded = try parseCompactNodes(alloc, &encoded);
    defer alloc.free(decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualSlices(u8, &node.id, &decoded[0].id);
}
