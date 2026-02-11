/// Peer connection management and P2P xorb transfer.
///
/// Handles TCP connections to peers, the handshake flow, and requesting/receiving
/// xorb data. Each peer connection is a simple request-response protocol over TCP.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const protocol = @import("protocol.zig");

pub const PeerConnection = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: net.Stream,
    peer_id: ?[32]u8,
    read_buf: [8192]u8,
    write_buf: [8192]u8,

    pub fn connect(allocator: std.mem.Allocator, io: Io, address: net.IpAddress) !PeerConnection {
        const stream = try address.connect(io, .{ .mode = .nonblocking });
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .peer_id = null,
            .read_buf = undefined,
            .write_buf = undefined,
        };
    }

    pub fn deinit(self: *PeerConnection) void {
        self.stream.close(self.io);
    }

    /// Perform the handshake with the remote peer.
    pub fn handshake(self: *PeerConnection, our_peer_id: [32]u8, listen_port: u16, num_xorbs: u32) !void {
        const hs = protocol.Handshake{
            .peer_id = our_peer_id,
            .listen_port = listen_port,
            .num_xorbs = num_xorbs,
        };
        const payload = protocol.serialize(protocol.Handshake, &hs);

        var sw = self.stream.writer(self.io, &self.write_buf);
        try protocol.writeMessage(&sw.interface, .handshake, &payload);
        try sw.interface.flush();

        // Read peer's handshake
        var sr = self.stream.reader(self.io, &self.read_buf);
        const msg = try protocol.readMessage(&sr.interface, self.allocator);
        defer self.allocator.free(msg.payload);

        if (msg.msg_type != .handshake) return error.UnexpectedMessage;

        const peer_hs = try protocol.deserialize(protocol.Handshake, msg.payload);
        if (peer_hs.version != protocol.PROTOCOL_VERSION) return error.VersionMismatch;
        self.peer_id = peer_hs.peer_id;
    }

    /// Request a xorb from the peer by hash.
    pub fn requestXorb(self: *PeerConnection, xorb_hash: [32]u8) ![]u8 {
        const req = protocol.XorbRequest{
            .xorb_hash = xorb_hash,
        };
        const payload = protocol.serialize(protocol.XorbRequest, &req);

        var sw = self.stream.writer(self.io, &self.write_buf);
        try protocol.writeMessage(&sw.interface, .xorb_request, &payload);
        try sw.interface.flush();

        // Read response
        var sr = self.stream.reader(self.io, &self.read_buf);
        const msg = try protocol.readMessage(&sr.interface, self.allocator);

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
    pub fn sendHaveXorbs(self: *PeerConnection, xorb_hashes: []const [32]u8) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);

        const header = protocol.HaveXorbs{ .count = @intCast(xorb_hashes.len) };
        const header_bytes = protocol.serialize(protocol.HaveXorbs, &header);
        try payload.appendSlice(self.allocator, &header_bytes);

        for (xorb_hashes) |h| {
            try payload.appendSlice(self.allocator, &h);
        }

        var sw = self.stream.writer(self.io, &self.write_buf);
        try protocol.writeMessage(&sw.interface, .have_xorbs, payload.items);
        try sw.interface.flush();
    }
};

/// Parse an address string like "192.168.1.1:6881" into an IpAddress.
pub fn parseAddress(addr_str: []const u8) !net.IpAddress {
    return net.IpAddress.parseLiteral(addr_str) catch return error.InvalidAddress;
}
