/// BEP XET extension messages riding on BEP 10.
///
/// Four message types for chunk-level xorb transfer:
///   0x01  CHUNK_REQUEST   — request a chunk by its BLAKE3 hash
///   0x02  CHUNK_RESPONSE  — chunk data response
///   0x03  CHUNK_NOT_FOUND — peer doesn't have the requested chunk
///   0x04  CHUNK_ERROR     — error occurred processing the request
///
/// All messages are wrapped in BEP 10 extended messages (msg_id=20).
/// The ext_id is negotiated during the BEP 10 extended handshake.
const std = @import("std");
const Io = std.Io;
const bt_wire = @import("bt_wire.zig");
const bencode = @import("bencode.zig");

pub const EXTENSION_NAME = "ut_xet";

pub const XetMessageType = enum(u8) {
    chunk_request = 0x01,
    chunk_response = 0x02,
    chunk_not_found = 0x03,
    chunk_error = 0x04,
};

pub const XetMessage = union(enum) {
    chunk_request: ChunkRequest,
    chunk_response: ChunkResponse,
    chunk_not_found: ChunkNotFound,
    chunk_error: ChunkError,
};

pub const ChunkRequest = struct {
    request_id: u32,
    chunk_hash: [32]u8,
    range_start: u32,
    range_end: u32,
};

pub const ChunkResponse = struct {
    request_id: u32,
    chunk_offset: u32,
    data: []const u8,
};

pub const ChunkNotFound = struct {
    request_id: u32,
    chunk_hash: [32]u8,
};

pub const ChunkError = struct {
    request_id: u32,
    error_code: u32,
    message: []const u8,
};

pub const ExtCapabilities = struct {
    ut_xet_id: ?u8,
    listen_port: ?u16,
    client: ?[]const u8,
};

// ── Encoding ──

/// Encode a CHUNK_REQUEST as a BEP XET extension sub-payload.
/// Format: [1 xet_type][4 request_id BE][32 chunk_hash][4 range_start BE][4 range_end BE] = 45 bytes
pub fn encodeChunkRequest(writer: *Io.Writer, ext_id: u8, request_id: u32, chunk_hash: [32]u8, range_start: u32, range_end: u32) !void {
    var payload: [45]u8 = undefined;
    payload[0] = @intFromEnum(XetMessageType.chunk_request);
    std.mem.writeInt(u32, payload[1..5], request_id, .big);
    @memcpy(payload[5..37], &chunk_hash);
    std.mem.writeInt(u32, payload[37..41], range_start, .big);
    std.mem.writeInt(u32, payload[41..45], range_end, .big);
    try bt_wire.writeExtended(writer, ext_id, &payload);
}

/// Encode a CHUNK_RESPONSE as a BEP XET extension sub-payload.
/// Format: [1 xet_type][4 request_id BE][4 chunk_offset BE][4 data_len BE][N data]
pub fn encodeChunkResponse(writer: *Io.Writer, ext_id: u8, request_id: u32, chunk_offset: u32, data: []const u8) !void {
    // Write header via extended
    const header_len = 1 + 4 + 4 + 4 + data.len;
    const total_len: u32 = @intCast(2 + header_len); // msg_id + ext_id + payload
    var header: [6]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], total_len, .big);
    header[4] = @intFromEnum(bt_wire.MessageId.extended);
    header[5] = ext_id;
    try writer.writeAll(&header);

    var sub_header: [13]u8 = undefined;
    sub_header[0] = @intFromEnum(XetMessageType.chunk_response);
    std.mem.writeInt(u32, sub_header[1..5], request_id, .big);
    std.mem.writeInt(u32, sub_header[5..9], chunk_offset, .big);
    std.mem.writeInt(u32, sub_header[9..13], @intCast(data.len), .big);
    try writer.writeAll(&sub_header);
    try writer.writeAll(data);
}

/// Encode a CHUNK_NOT_FOUND as a BEP XET extension sub-payload.
/// Format: [1 xet_type][4 request_id BE][32 chunk_hash] = 37 bytes
pub fn encodeChunkNotFound(writer: *Io.Writer, ext_id: u8, request_id: u32, chunk_hash: [32]u8) !void {
    var payload: [37]u8 = undefined;
    payload[0] = @intFromEnum(XetMessageType.chunk_not_found);
    std.mem.writeInt(u32, payload[1..5], request_id, .big);
    @memcpy(payload[5..37], &chunk_hash);
    try bt_wire.writeExtended(writer, ext_id, &payload);
}

/// Encode a CHUNK_ERROR as a BEP XET extension sub-payload.
/// Format: [1 xet_type][4 request_id BE][4 error_code BE][N message]
pub fn encodeChunkError(writer: *Io.Writer, ext_id: u8, request_id: u32, error_code: u32, message: []const u8) !void {
    const payload_len = 1 + 4 + 4 + message.len;
    const total_len: u32 = @intCast(2 + payload_len);
    var header: [6]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], total_len, .big);
    header[4] = @intFromEnum(bt_wire.MessageId.extended);
    header[5] = ext_id;
    try writer.writeAll(&header);

    var sub_header: [9]u8 = undefined;
    sub_header[0] = @intFromEnum(XetMessageType.chunk_error);
    std.mem.writeInt(u32, sub_header[1..5], request_id, .big);
    std.mem.writeInt(u32, sub_header[5..9], error_code, .big);
    try writer.writeAll(&sub_header);
    try writer.writeAll(message);
}

// ── Decoding ──

/// Decode a BEP XET message from the extended sub-payload (after ext_id).
pub fn decodeMessage(data: []const u8) !XetMessage {
    if (data.len < 1) return error.UnexpectedEnd;

    const xet_type: XetMessageType = @enumFromInt(data[0]);
    const rest = data[1..];

    return switch (xet_type) {
        .chunk_request => {
            if (rest.len < 44) return error.UnexpectedEnd;
            return .{ .chunk_request = .{
                .request_id = std.mem.readInt(u32, rest[0..4], .big),
                .chunk_hash = rest[4..36].*,
                .range_start = std.mem.readInt(u32, rest[36..40], .big),
                .range_end = std.mem.readInt(u32, rest[40..44], .big),
            } };
        },
        .chunk_response => {
            if (rest.len < 12) return error.UnexpectedEnd;
            const request_id = std.mem.readInt(u32, rest[0..4], .big);
            const chunk_offset = std.mem.readInt(u32, rest[4..8], .big);
            const data_len = std.mem.readInt(u32, rest[8..12], .big);
            if (rest.len < 12 + data_len) return error.UnexpectedEnd;
            return .{ .chunk_response = .{
                .request_id = request_id,
                .chunk_offset = chunk_offset,
                .data = rest[12 .. 12 + data_len],
            } };
        },
        .chunk_not_found => {
            if (rest.len < 36) return error.UnexpectedEnd;
            return .{ .chunk_not_found = .{
                .request_id = std.mem.readInt(u32, rest[0..4], .big),
                .chunk_hash = rest[4..36].*,
            } };
        },
        .chunk_error => {
            if (rest.len < 8) return error.UnexpectedEnd;
            const request_id = std.mem.readInt(u32, rest[0..4], .big);
            const error_code = std.mem.readInt(u32, rest[4..8], .big);
            return .{ .chunk_error = .{
                .request_id = request_id,
                .error_code = error_code,
                .message = rest[8..],
            } };
        },
    };
}

// ── BEP 10 Extended Handshake ──

/// Build the bencoded BEP 10 extended handshake dict: {"m":{"ut_xet":N},"p":port,"v":"zest/0.2"}
pub fn makeExtHandshakePayload(allocator: std.mem.Allocator, listen_port: u16) ![]u8 {
    // Build inner dict: {"ut_xet": 1}
    const inner_entries = try allocator.alloc(bencode.DictEntry, 1);
    defer allocator.free(inner_entries);
    inner_entries[0] = .{ .key = EXTENSION_NAME, .value = .{ .integer = 1 } };

    // Build outer dict: {"m": inner, "p": port, "v": "zest/0.2"}
    const outer_entries = try allocator.alloc(bencode.DictEntry, 3);
    defer allocator.free(outer_entries);
    outer_entries[0] = .{ .key = "m", .value = .{ .dict = inner_entries } };
    outer_entries[1] = .{ .key = "p", .value = .{ .integer = @intCast(listen_port) } };
    outer_entries[2] = .{ .key = "v", .value = .{ .string = "zest/0.3" } };

    return try bencode.encode(allocator, .{ .dict = outer_entries });
}

/// Parse a BEP 10 extended handshake response to extract capabilities.
pub fn parseExtHandshake(allocator: std.mem.Allocator, payload: []const u8) !ExtCapabilities {
    const val = bencode.decode(allocator, payload) catch return .{
        .ut_xet_id = null,
        .listen_port = null,
        .client = null,
    };
    defer bencode.deinit(allocator, val);

    const entries = switch (val) {
        .dict => |d| d,
        else => return .{ .ut_xet_id = null, .listen_port = null, .client = null },
    };

    var caps = ExtCapabilities{
        .ut_xet_id = null,
        .listen_port = null,
        .client = null,
    };

    // Extract ut_xet extension ID from "m" dict
    if (bencode.dictGetDict(entries, "m")) |m_entries| {
        if (bencode.dictGetInt(m_entries, EXTENSION_NAME)) |id| {
            if (id >= 1 and id <= 255) {
                caps.ut_xet_id = @intCast(id);
            }
        }
    }

    // Extract listen port
    if (bencode.dictGetInt(entries, "p")) |port| {
        if (port >= 1 and port <= 65535) {
            caps.listen_port = @intCast(port);
        }
    }

    // Extract client name
    caps.client = bencode.dictGetStr(entries, "v");

    return caps;
}

// ── Tests ──

test "chunk_request encode and decode" {
    const hash = [_]u8{0xAB} ** 32;

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try encodeChunkRequest(&writer, 1, 42, hash, 10, 20);

    // Read back via bt_wire
    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = (try bt_wire.readMessage(&reader, std.testing.allocator)) orelse return error.InvalidFormat;
    defer if (msg.payload.len > 0) std.testing.allocator.free(msg.payload);

    try std.testing.expectEqual(bt_wire.MessageId.extended, msg.msg_id);
    const ext = try bt_wire.parseExtended(msg.payload);
    try std.testing.expectEqual(@as(u8, 1), ext.ext_id);

    const xet_msg = try decodeMessage(ext.data);
    switch (xet_msg) {
        .chunk_request => |req| {
            try std.testing.expectEqual(@as(u32, 42), req.request_id);
            try std.testing.expectEqualSlices(u8, &hash, &req.chunk_hash);
            try std.testing.expectEqual(@as(u32, 10), req.range_start);
            try std.testing.expectEqual(@as(u32, 20), req.range_end);
        },
        else => return error.InvalidFormat,
    }
}

test "chunk_response encode and decode" {
    const chunk_data = "this is chunk data" ** 10;

    var buf: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try encodeChunkResponse(&writer, 2, 99, 42, chunk_data);

    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = (try bt_wire.readMessage(&reader, std.testing.allocator)) orelse return error.InvalidFormat;
    defer if (msg.payload.len > 0) std.testing.allocator.free(msg.payload);

    const ext = try bt_wire.parseExtended(msg.payload);
    const xet_msg = try decodeMessage(ext.data);
    switch (xet_msg) {
        .chunk_response => |resp| {
            try std.testing.expectEqual(@as(u32, 99), resp.request_id);
            try std.testing.expectEqual(@as(u32, 42), resp.chunk_offset);
            try std.testing.expectEqualSlices(u8, chunk_data, resp.data);
        },
        else => return error.InvalidFormat,
    }
}

test "chunk_not_found encode and decode" {
    const hash = [_]u8{0x42} ** 32;

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try encodeChunkNotFound(&writer, 1, 7, hash);

    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = (try bt_wire.readMessage(&reader, std.testing.allocator)) orelse return error.InvalidFormat;
    defer if (msg.payload.len > 0) std.testing.allocator.free(msg.payload);

    const ext = try bt_wire.parseExtended(msg.payload);
    const xet_msg = try decodeMessage(ext.data);
    switch (xet_msg) {
        .chunk_not_found => |nf| {
            try std.testing.expectEqual(@as(u32, 7), nf.request_id);
            try std.testing.expectEqualSlices(u8, &hash, &nf.chunk_hash);
        },
        else => return error.InvalidFormat,
    }
}

test "chunk_error encode and decode" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    try encodeChunkError(&writer, 1, 5, 404, "not found");

    var reader: Io.Reader = .fixed(writer.buffered());
    const msg = (try bt_wire.readMessage(&reader, std.testing.allocator)) orelse return error.InvalidFormat;
    defer if (msg.payload.len > 0) std.testing.allocator.free(msg.payload);

    const ext = try bt_wire.parseExtended(msg.payload);
    const xet_msg = try decodeMessage(ext.data);
    switch (xet_msg) {
        .chunk_error => |ce| {
            try std.testing.expectEqual(@as(u32, 5), ce.request_id);
            try std.testing.expectEqual(@as(u32, 404), ce.error_code);
            try std.testing.expectEqualSlices(u8, "not found", ce.message);
        },
        else => return error.InvalidFormat,
    }
}

test "extended handshake generation" {
    const alloc = std.testing.allocator;
    const payload = try makeExtHandshakePayload(alloc, 6881);
    defer alloc.free(payload);

    // Should be valid bencode
    const val = try bencode.decode(alloc, payload);
    defer bencode.deinit(alloc, val);

    // Should contain ut_xet in "m" dict
    const m = bencode.dictGetDict(val.dict, "m") orelse return error.InvalidFormat;
    const ut_xet = bencode.dictGetInt(m, EXTENSION_NAME) orelse return error.InvalidFormat;
    try std.testing.expectEqual(@as(i64, 1), ut_xet);

    // Should contain port
    const port = bencode.dictGetInt(val.dict, "p") orelse return error.InvalidFormat;
    try std.testing.expectEqual(@as(i64, 6881), port);
}

test "extended handshake parsing" {
    const alloc = std.testing.allocator;
    const payload = try makeExtHandshakePayload(alloc, 8080);
    defer alloc.free(payload);

    const caps = try parseExtHandshake(alloc, payload);
    try std.testing.expectEqual(@as(u8, 1), caps.ut_xet_id.?);
    try std.testing.expectEqual(@as(u16, 8080), caps.listen_port.?);
    try std.testing.expectEqualSlices(u8, "zest/0.3", caps.client.?);
}
