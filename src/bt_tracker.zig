/// Standard BT HTTP tracker client (BEP 3 format).
///
/// Replaces the custom JSON tracker with the standard BT tracker protocol:
///   GET /announce?info_hash={urlencoded}&peer_id={urlencoded}&port={port}&compact=1&event=started
///
/// Response is bencoded dict with "peers" in compact format (6 bytes per peer).
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const bencode = @import("bencode.zig");

pub const Event = enum {
    none,
    started,
    stopped,
    completed,

    pub fn toStr(self: Event) ?[]const u8 {
        return switch (self) {
            .none => null,
            .started => "started",
            .stopped => "stopped",
            .completed => "completed",
        };
    }
};

pub const PeerAddr = struct {
    address: net.IpAddress,
};

pub const AnnounceResponse = struct {
    interval: u32,
    peers: []PeerAddr,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AnnounceResponse) void {
        self.allocator.free(self.peers);
    }
};

pub const BtTrackerClient = struct {
    allocator: std.mem.Allocator,
    io: Io,
    tracker_url: []const u8,
    peer_id: [20]u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: Io, tracker_url: []const u8, peer_id: [20]u8) !BtTrackerClient {
        return .{
            .allocator = allocator,
            .io = io,
            .tracker_url = try allocator.dupe(u8, tracker_url),
            .peer_id = peer_id,
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *BtTrackerClient) void {
        self.http_client.deinit();
        self.allocator.free(self.tracker_url);
    }

    /// Announce to the tracker. Returns peer list and re-announce interval.
    pub fn announce(self: *BtTrackerClient, info_hash: [20]u8, port: u16, event: Event) !AnnounceResponse {
        // Build URL with percent-encoded binary hashes
        var url_buf: std.ArrayList(u8) = .empty;
        defer url_buf.deinit(self.allocator);

        try url_buf.appendSlice(self.allocator, self.tracker_url);
        try url_buf.appendSlice(self.allocator, "/announce?info_hash=");
        try percentEncode(self.allocator, &url_buf, &info_hash);
        try url_buf.appendSlice(self.allocator, "&peer_id=");
        try percentEncode(self.allocator, &url_buf, &self.peer_id);

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
        try url_buf.appendSlice(self.allocator, "&port=");
        try url_buf.appendSlice(self.allocator, port_str);

        try url_buf.appendSlice(self.allocator, "&compact=1&uploaded=0&downloaded=0&left=0");

        if (event.toStr()) |ev| {
            try url_buf.appendSlice(self.allocator, "&event=");
            try url_buf.appendSlice(self.allocator, ev);
        }

        // Perform HTTP GET
        var aw: Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        const result = self.http_client.fetch(.{
            .location = .{ .url = url_buf.items },
            .response_writer = &aw.writer,
        }) catch return error.HttpError;

        if (result.status != .ok) {
            aw.deinit();
            return error.HttpError;
        }

        const body = try aw.toOwnedSlice();
        defer self.allocator.free(body);

        return try parseAnnounceResponse(self.allocator, body);
    }
};

/// Percent-encode binary data for URL query parameters (BT tracker convention).
pub fn percentEncode(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), data: []const u8) !void {
    for (data) |byte| {
        if (isUnreserved(byte)) {
            try buf.append(allocator, byte);
        } else {
            try buf.append(allocator, '%');
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, hex[byte >> 4]);
            try buf.append(allocator, hex[byte & 0x0F]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

/// Parse a BT tracker announce response (bencoded).
pub fn parseAnnounceResponse(allocator: std.mem.Allocator, body: []const u8) !AnnounceResponse {
    const val = try bencode.decode(allocator, body);
    defer bencode.deinit(allocator, val);

    const entries = switch (val) {
        .dict => |d| d,
        else => return error.InvalidFormat,
    };

    // Check for error
    if (bencode.dictGetStr(entries, "failure reason")) |_| {
        return error.TrackerError;
    }

    // Extract interval
    const interval: u32 = if (bencode.dictGetInt(entries, "interval")) |i|
        @intCast(i)
    else
        1800; // default 30 min

    // Parse compact peers (6 bytes per peer: 4 IP + 2 port)
    var peers: []PeerAddr = &.{};
    if (bencode.dictGetStr(entries, "peers")) |peers_data| {
        if (peers_data.len % 6 == 0) {
            const count = peers_data.len / 6;
            const peer_list = try allocator.alloc(PeerAddr, count);
            errdefer allocator.free(peer_list);

            for (0..count) |i| {
                const offset = i * 6;
                const ip_bytes = peers_data[offset .. offset + 4];
                const port = std.mem.readInt(u16, peers_data[offset + 4 .. offset + 6][0..2], .big);

                peer_list[i] = .{
                    .address = .{ .ip4 = .{
                        .bytes = ip_bytes[0..4].*,
                        .port = port,
                    } },
                };
            }
            peers = peer_list;
        }
    }

    return .{
        .interval = interval,
        .peers = peers,
        .allocator = allocator,
    };
}

// ── Tests ──

test "percent encode binary data" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // Simple ASCII
    try percentEncode(alloc, &buf, "hello");
    try std.testing.expectEqualSlices(u8, "hello", buf.items);

    // Binary data
    buf.items.len = 0;
    try percentEncode(alloc, &buf, &[_]u8{ 0x12, 0x34, 0xAB, 0xCD });
    try std.testing.expectEqualSlices(u8, "%124%AB%CD", buf.items);
}

test "percent encode preserves unreserved chars" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try percentEncode(alloc, &buf, "ABCxyz012-_.~");
    try std.testing.expectEqualSlices(u8, "ABCxyz012-_.~", buf.items);
}

test "parse announce response compact peers" {
    const alloc = std.testing.allocator;

    // Build a minimal bencoded tracker response:
    // d8:completei10e10:incompletei5e8:intervali1800e5:peers6:XXXXXX e
    // where XXXXXX = IP(192.168.1.1) + port(6881)
    var peer_data: [6]u8 = undefined;
    peer_data[0] = 192;
    peer_data[1] = 168;
    peer_data[2] = 1;
    peer_data[3] = 1;
    std.mem.writeInt(u16, peer_data[4..6], 6881, .big);

    // Build bencoded response
    const entries = try alloc.alloc(bencode.DictEntry, 2);
    defer alloc.free(entries);
    entries[0] = .{ .key = "interval", .value = .{ .integer = 900 } };
    entries[1] = .{ .key = "peers", .value = .{ .string = &peer_data } };

    const body = try bencode.encode(alloc, .{ .dict = entries });
    defer alloc.free(body);

    var resp = try parseAnnounceResponse(alloc, body);
    defer resp.deinit();

    try std.testing.expectEqual(@as(u32, 900), resp.interval);
    try std.testing.expectEqual(@as(usize, 1), resp.peers.len);
    switch (resp.peers[0].address) {
        .ip4 => |addr| {
            try std.testing.expectEqual(@as(u16, 6881), addr.port);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &addr.bytes);
        },
        else => return error.InvalidFormat,
    }
}

test "parse announce response with failure" {
    const alloc = std.testing.allocator;

    const entries = try alloc.alloc(bencode.DictEntry, 1);
    defer alloc.free(entries);
    entries[0] = .{ .key = "failure reason", .value = .{ .string = "denied" } };

    const body = try bencode.encode(alloc, .{ .dict = entries });
    defer alloc.free(body);

    try std.testing.expectError(error.TrackerError, parseAnnounceResponse(alloc, body));
}

test "BtTrackerClient struct init" {
    // Verify the struct compiles with expected fields
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(@TypeOf(@as(BtTrackerClient, undefined).peer_id)));
}
