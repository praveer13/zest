/// Peer connection management and P2P xorb transfer.
///
/// Handles TCP connections to peers, the handshake flow, and requesting/receiving
/// xorb data. Each peer connection is a simple request-response protocol over TCP.
const std = @import("std");
const protocol = @import("protocol.zig");
const hash_mod = @import("hash.zig");

pub const PeerConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    peer_id: ?[32]u8,
    peer_addr: std.net.Address,

    pub fn connect(allocator: std.mem.Allocator, address: std.net.Address) !PeerConnection {
        const stream = try std.net.tcpConnectToAddress(address);
        return .{
            .allocator = allocator,
            .stream = stream,
            .peer_id = null,
            .peer_addr = address,
        };
    }

    pub fn deinit(self: *PeerConnection) void {
        self.stream.close();
    }

    /// Perform the handshake with the remote peer.
    pub fn handshake(self: *PeerConnection, our_peer_id: [32]u8, listen_port: u16, num_xorbs: u32) !void {
        const hs = protocol.Handshake{
            .peer_id = our_peer_id,
            .listen_port = listen_port,
            .num_xorbs = num_xorbs,
        };
        const payload = protocol.serialize(protocol.Handshake, &hs);
        try protocol.writeMessage(self.stream.writer(), .handshake, &payload);

        // Read peer's handshake
        const msg = try protocol.readMessage(self.stream.reader(), self.allocator);
        defer self.allocator.free(msg.payload);

        if (msg.msg_type != .handshake) return error.UnexpectedMessage;

        const peer_hs = try protocol.deserialize(protocol.Handshake, msg.payload);
        if (peer_hs.version != protocol.PROTOCOL_VERSION) return error.VersionMismatch;
        self.peer_id = peer_hs.peer_id;
    }

    /// Request a xorb from the peer by hash.
    pub fn requestXorb(self: *PeerConnection, xorb_hash: hash_mod.MerkleHash) ![]u8 {
        const req = protocol.XorbRequest{
            .xorb_hash = xorb_hash,
        };
        const payload = protocol.serialize(protocol.XorbRequest, &req);
        try protocol.writeMessage(self.stream.writer(), .xorb_request, &payload);

        // Read response
        const msg = try protocol.readMessage(self.stream.reader(), self.allocator);

        if (msg.msg_type != .xorb_data) {
            self.allocator.free(msg.payload);
            return error.UnexpectedMessage;
        }

        // The payload contains a XorbResponse header followed by the actual xorb data
        if (msg.payload.len < @sizeOf(protocol.XorbResponse)) {
            self.allocator.free(msg.payload);
            return error.IncompleteMessage;
        }

        const resp = try protocol.deserialize(protocol.XorbResponse, msg.payload);
        const data_start = @sizeOf(protocol.XorbResponse);
        const data_end = data_start + @as(usize, @intCast(resp.data_len));

        if (data_end > msg.payload.len) {
            self.allocator.free(msg.payload);
            return error.IncompleteMessage;
        }

        // Copy just the data portion
        const data = try self.allocator.dupe(u8, msg.payload[data_start..data_end]);
        self.allocator.free(msg.payload);
        return data;
    }

    /// Send our list of available xorbs to the peer.
    pub fn sendHaveXorbs(self: *PeerConnection, xorb_hashes: []const hash_mod.MerkleHash) !void {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        const header = protocol.HaveXorbs{ .count = @intCast(xorb_hashes.len) };
        const header_bytes = protocol.serialize(protocol.HaveXorbs, &header);
        try payload.appendSlice(&header_bytes);

        for (xorb_hashes) |h| {
            try payload.appendSlice(&h);
        }

        try protocol.writeMessage(self.stream.writer(), .have_xorbs, payload.items);
    }
};

/// Parse an address string like "192.168.1.1:6881" into a net.Address.
pub fn parseAddress(addr_str: []const u8) !std.net.Address {
    // Find the last colon to split host:port
    const colon_idx = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.InvalidAddress;
    const host = addr_str[0..colon_idx];
    const port_str = addr_str[colon_idx + 1 ..];
    const port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.InvalidPort;

    return std.net.Address.parseIp4(host, port) catch {
        return std.net.Address.parseIp6(host, port) catch return error.InvalidAddress;
    };
}
