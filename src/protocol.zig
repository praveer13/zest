/// P2P wire protocol message types with comptime-generated serialization.
///
/// All messages are length-prefixed (4 bytes LE) and version-tagged (1 byte).
/// Message types:
///   0x01 Handshake      — announce peer identity and capabilities
///   0x02 XorbRequest    — request a xorb by hash, optionally with byte range
///   0x03 XorbData       — xorb data response
///   0x04 HaveXorbs      — announce which xorbs this peer has
///   0x05 PeerExchange   — share known peers
const std = @import("std");
const hash_mod = @import("hash.zig");
const MerkleHash = hash_mod.MerkleHash;

pub const PROTOCOL_VERSION: u8 = 1;
pub const MAX_MESSAGE_SIZE: u32 = 64 * 1024 * 1024 + 1024; // 64 MiB + overhead

pub const MessageType = enum(u8) {
    handshake = 0x01,
    xorb_request = 0x02,
    xorb_data = 0x03,
    have_xorbs = 0x04,
    peer_exchange = 0x05,
};

pub const Handshake = struct {
    version: u8 = PROTOCOL_VERSION,
    peer_id: [32]u8, // BLAKE3(public_key)
    listen_port: u16,
    num_xorbs: u32, // how many xorbs this peer has
};

pub const XorbRequest = struct {
    xorb_hash: MerkleHash,
    byte_range_start: u64 = 0,
    byte_range_end: u64 = 0, // 0 means "entire xorb"
};

pub const XorbResponse = struct {
    xorb_hash: MerkleHash,
    total_size: u64,
    data_offset: u64,
    data_len: u64,
    // Followed by `data_len` bytes of xorb data
};

pub const HaveXorbs = struct {
    count: u32,
    // Followed by `count` MerkleHash values (32 bytes each)
};

pub const PeerInfo = struct {
    addr: [16]u8, // IPv6-mapped address (IPv4 maps to ::ffff:x.x.x.x)
    port: u16,
};

pub const PeerExchange = struct {
    count: u32,
    // Followed by `count` PeerInfo values
};

/// Serialize a fixed-size struct to bytes (little-endian).
pub fn serialize(comptime T: type, value: *const T) [@sizeOf(T)]u8 {
    var buf: [@sizeOf(T)]u8 = undefined;
    const src: *const [@sizeOf(T)]u8 = @ptrCast(value);
    @memcpy(&buf, src);
    return buf;
}

/// Deserialize bytes to a fixed-size struct.
pub fn deserialize(comptime T: type, buf: []const u8) !T {
    if (buf.len < @sizeOf(T)) return error.BufferTooSmall;
    const ptr: *const T = @ptrCast(@alignCast(buf[0..@sizeOf(T)]));
    return ptr.*;
}

/// Write a length-prefixed, type-tagged message to a writer.
pub fn writeMessage(writer: anytype, msg_type: MessageType, payload: []const u8) !void {
    const total_len: u32 = @intCast(1 + payload.len); // 1 for type tag
    try writer.writeInt(u32, total_len, .little);
    try writer.writeByte(@intFromEnum(msg_type));
    try writer.writeAll(payload);
}

/// Read a length-prefixed, type-tagged message. Returns (type, payload).
pub fn readMessage(reader: anytype, allocator: std.mem.Allocator) !struct { msg_type: MessageType, payload: []u8 } {
    const total_len = try reader.readInt(u32, .little);
    if (total_len < 1 or total_len > MAX_MESSAGE_SIZE) return error.InvalidMessageSize;

    const type_byte = try reader.readByte();
    const msg_type = std.meta.intToEnum(MessageType, type_byte) catch return error.UnknownMessageType;

    const payload_len = total_len - 1;
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);

    const bytes_read = try reader.readAll(payload);
    if (bytes_read != payload_len) {
        allocator.free(payload);
        return error.IncompleteMessage;
    }

    return .{ .msg_type = msg_type, .payload = payload };
}

test "serialize and deserialize Handshake" {
    const hs = Handshake{
        .peer_id = [_]u8{0xAB} ** 32,
        .listen_port = 6881,
        .num_xorbs = 42,
    };
    const bytes = serialize(Handshake, &hs);
    const decoded = try deserialize(Handshake, &bytes);
    try std.testing.expectEqual(hs.version, decoded.version);
    try std.testing.expectEqual(hs.listen_port, decoded.listen_port);
    try std.testing.expectEqual(hs.num_xorbs, decoded.num_xorbs);
    try std.testing.expectEqualSlices(u8, &hs.peer_id, &decoded.peer_id);
}

test "serialize and deserialize XorbRequest" {
    const req = XorbRequest{
        .xorb_hash = [_]u8{0x12} ** 32,
        .byte_range_start = 0,
        .byte_range_end = 65536,
    };
    const bytes = serialize(XorbRequest, &req);
    const decoded = try deserialize(XorbRequest, &bytes);
    try std.testing.expectEqualSlices(u8, &req.xorb_hash, &decoded.xorb_hash);
    try std.testing.expectEqual(req.byte_range_end, decoded.byte_range_end);
}

test "writeMessage and readMessage roundtrip" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const payload = "hello peer";
    try writeMessage(stream.writer(), .handshake, payload);

    stream.pos = 0;
    const msg = try readMessage(stream.reader(), std.testing.allocator);
    defer std.testing.allocator.free(msg.payload);

    try std.testing.expectEqual(MessageType.handshake, msg.msg_type);
    try std.testing.expectEqualSlices(u8, payload, msg.payload);
}
