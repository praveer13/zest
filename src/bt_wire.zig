/// BitTorrent wire protocol framing (BEP 3 + BEP 10).
///
/// Implements the standard BT handshake and message framing with big-endian
/// length prefixes. Supports BEP 10 extended messages for protocol extensions.
///
/// Wire format:
///   Handshake:  [1 pstrlen][19 pstr][8 reserved][20 info_hash][20 peer_id] = 68 bytes
///   Message:    [4 length BE][1 msg_id][payload...]
///   Keepalive:  [4 zeros] (length=0, no msg_id)
///   Extended:   [4 length BE][1 msg_id=20][1 ext_id][payload...]
const std = @import("std");
const Io = std.Io;

pub const PROTOCOL_STRING = "BitTorrent protocol";
pub const PROTOCOL_STRING_LEN: u8 = 19;
pub const HANDSHAKE_SIZE: usize = 68;

/// Reserved bytes: bit 20 (byte 5, bit 4) set for BEP 10 extension protocol support.
pub const RESERVED_BYTES = [8]u8{ 0, 0, 0, 0, 0, 0x10, 0, 0 };

/// Maximum message size: 64 MiB + overhead (matches xorb max size).
pub const MAX_MESSAGE_SIZE: u32 = 64 * 1024 * 1024 + 1024;

pub const Handshake = struct {
    info_hash: [20]u8,
    peer_id: [20]u8,
    reserved: [8]u8 = RESERVED_BYTES,

    /// Check if peer supports BEP 10 extension protocol.
    pub fn supportsBep10(self: *const Handshake) bool {
        return (self.reserved[5] & 0x10) != 0;
    }
};

pub const MessageId = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    not_interested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,
    extended = 20, // BEP 10
};

pub const ReadError = error{
    InvalidProtocolString,
    InvalidMessageSize,
    InvalidMessageId,
    UnexpectedEnd,
    OutOfMemory,
    ReadFailed,
};

// ── Handshake ──

/// Write the 68-byte BT handshake to the writer.
pub fn writeHandshake(writer: *Io.Writer, info_hash: [20]u8, peer_id: [20]u8) !void {
    var buf: [HANDSHAKE_SIZE]u8 = undefined;
    buf[0] = PROTOCOL_STRING_LEN;
    @memcpy(buf[1..20], PROTOCOL_STRING);
    @memcpy(buf[20..28], &RESERVED_BYTES);
    @memcpy(buf[28..48], &info_hash);
    @memcpy(buf[48..68], &peer_id);
    try writer.writeAll(&buf);
}

/// Read and parse a 68-byte BT handshake from the reader.
pub fn readHandshake(reader: *Io.Reader) ReadError!Handshake {
    var buf: [HANDSHAKE_SIZE]u8 = undefined;
    reader.readSliceAll(&buf) catch return error.ReadFailed;

    // Verify protocol string
    if (buf[0] != PROTOCOL_STRING_LEN) return error.InvalidProtocolString;
    if (!std.mem.eql(u8, buf[1..20], PROTOCOL_STRING)) return error.InvalidProtocolString;

    return .{
        .reserved = buf[20..28].*,
        .info_hash = buf[28..48].*,
        .peer_id = buf[48..68].*,
    };
}

// ── Messages ──

/// Write a BT message with the given ID and payload. Length prefix is big-endian.
pub fn writeMessage(writer: *Io.Writer, msg_id: MessageId, payload: []const u8) !void {
    const total_len: u32 = @intCast(1 + payload.len); // 1 for msg_id
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], total_len, .big);
    header[4] = @intFromEnum(msg_id);
    try writer.writeAll(&header);
    if (payload.len > 0) {
        try writer.writeAll(payload);
    }
}

/// Write a keepalive message (4 zero bytes, no msg_id).
pub fn writeKeepalive(writer: *Io.Writer) !void {
    try writer.writeAll(&[4]u8{ 0, 0, 0, 0 });
}

/// Read a BT message. Returns null for keepalive messages.
/// Caller owns the returned payload and must free it.
pub fn readMessage(reader: *Io.Reader, allocator: std.mem.Allocator) ReadError!?struct { msg_id: MessageId, payload: []u8 } {
    var len_buf: [4]u8 = undefined;
    reader.readSliceAll(&len_buf) catch return error.ReadFailed;
    const total_len = std.mem.readInt(u32, &len_buf, .big);

    // Keepalive: length=0
    if (total_len == 0) return null;

    if (total_len > MAX_MESSAGE_SIZE) return error.InvalidMessageSize;

    var id_buf: [1]u8 = undefined;
    reader.readSliceAll(&id_buf) catch return error.ReadFailed;
    const msg_id: MessageId = @enumFromInt(id_buf[0]);

    const payload_len: usize = total_len - 1;
    if (payload_len == 0) {
        return .{ .msg_id = msg_id, .payload = &.{} };
    }

    const payload = allocator.alloc(u8, payload_len) catch return error.OutOfMemory;
    errdefer allocator.free(payload);
    reader.readSliceAll(payload) catch return error.ReadFailed;

    return .{ .msg_id = msg_id, .payload = payload };
}

// ── Extended messages (BEP 10) ──

/// Write a BEP 10 extended message: [4 len BE][msg_id=20][ext_id][payload].
pub fn writeExtended(writer: *Io.Writer, ext_id: u8, payload: []const u8) !void {
    const total_len: u32 = @intCast(2 + payload.len); // msg_id + ext_id + payload
    var header: [6]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], total_len, .big);
    header[4] = @intFromEnum(MessageId.extended);
    header[5] = ext_id;
    try writer.writeAll(&header);
    if (payload.len > 0) {
        try writer.writeAll(payload);
    }
}

/// Parse an extended message payload into ext_id and sub-payload.
/// The input `payload` is what readMessage returns for msg_id=extended.
pub fn parseExtended(payload: []const u8) !struct { ext_id: u8, data: []const u8 } {
    if (payload.len < 1) return error.UnexpectedEnd;
    return .{
        .ext_id = payload[0],
        .data = payload[1..],
    };
}

// ── Tests ──

test "handshake roundtrip" {
    const info_hash = [_]u8{0x12} ** 20;
    const peer_id = [_]u8{0xAB} ** 20;

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writeHandshake(&writer, info_hash, peer_id);

    var reader: Io.Reader = .fixed(writer.buffered());
    const hs = try readHandshake(&reader);

    try std.testing.expectEqualSlices(u8, &info_hash, &hs.info_hash);
    try std.testing.expectEqualSlices(u8, &peer_id, &hs.peer_id);
    try std.testing.expect(hs.supportsBep10());
}

test "handshake reserved bytes indicate BEP 10" {
    var hs = Handshake{
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
        .reserved = RESERVED_BYTES,
    };
    try std.testing.expect(hs.supportsBep10());

    hs.reserved = [_]u8{0} ** 8;
    try std.testing.expect(!hs.supportsBep10());
}

test "message framing roundtrip" {
    const alloc = std.testing.allocator;
    const payload = "hello BT";

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writeMessage(&writer, .interested, payload);

    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = (try readMessage(&reader, alloc)) orelse return error.InvalidFormat;
    defer if (msg.payload.len > 0) alloc.free(msg.payload);

    try std.testing.expectEqual(MessageId.interested, msg.msg_id);
    try std.testing.expectEqualSlices(u8, payload, msg.payload);
}

test "keepalive message" {
    const alloc = std.testing.allocator;

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writeKeepalive(&writer);

    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = try readMessage(&reader, alloc);
    try std.testing.expect(msg == null); // keepalive returns null
}

test "extended message framing" {
    const alloc = std.testing.allocator;
    const ext_payload = "ext data";

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writeExtended(&writer, 1, ext_payload);

    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = (try readMessage(&reader, alloc)) orelse return error.InvalidFormat;
    defer if (msg.payload.len > 0) alloc.free(msg.payload);

    try std.testing.expectEqual(MessageId.extended, msg.msg_id);

    // Parse the extended message
    const ext = try parseExtended(msg.payload);
    try std.testing.expectEqual(@as(u8, 1), ext.ext_id);
    try std.testing.expectEqualSlices(u8, ext_payload, ext.data);
}

test "message with empty payload" {
    const alloc = std.testing.allocator;

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try writeMessage(&writer, .choke, &.{});

    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = (try readMessage(&reader, alloc)) orelse return error.InvalidFormat;

    try std.testing.expectEqual(MessageId.choke, msg.msg_id);
    try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
}

test "reject oversized message" {
    var buf: [8]u8 = undefined;
    // Write a length that exceeds MAX_MESSAGE_SIZE
    std.mem.writeInt(u32, buf[0..4], MAX_MESSAGE_SIZE + 1, .big);
    buf[4] = 0; // choke

    var reader: Io.Reader = .fixed(buf[0..5]);
    const result = readMessage(&reader, std.testing.allocator);
    try std.testing.expectError(error.InvalidMessageSize, result);
}

test "big-endian length encoding" {
    // Verify we use big-endian (BT standard), not little-endian
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    // Write a message with 4-byte payload → length = 5 (1 for msg_id + 4 for payload)
    try writeMessage(&writer, .choke, "test");

    const written = writer.buffered();
    // First 4 bytes should be big-endian 5: 0x00 0x00 0x00 0x05
    try std.testing.expectEqual(@as(u8, 0x00), written[0]);
    try std.testing.expectEqual(@as(u8, 0x00), written[1]);
    try std.testing.expectEqual(@as(u8, 0x00), written[2]);
    try std.testing.expectEqual(@as(u8, 0x05), written[3]);
}
