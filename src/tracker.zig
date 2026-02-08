/// Simple HTTP tracker client for MVP peer discovery.
///
/// The tracker is a lightweight HTTP service that maps xorb hashes to peer addresses.
///   GET  /peers?xorb={hash_hex}        → list of peers who have this xorb
///   POST /announce                      → announce that this peer has certain xorbs
///
/// This is a temporary solution for the MVP; full Kademlia DHT comes later.
const std = @import("std");
const hash_mod = @import("hash.zig");
const protocol = @import("protocol.zig");

pub const TrackerPeer = struct {
    addr: []const u8, // "ip:port"
    last_seen: i64,
};

pub const TrackerClient = struct {
    allocator: std.mem.Allocator,
    tracker_url: []const u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, tracker_url: []const u8) !TrackerClient {
        return .{
            .allocator = allocator,
            .tracker_url = try allocator.dupe(u8, tracker_url),
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *TrackerClient) void {
        self.http_client.deinit();
        self.allocator.free(self.tracker_url);
    }

    /// Query the tracker for peers who have a specific xorb.
    pub fn getPeers(self: *TrackerClient, xorb_hash_hex: []const u8) ![]TrackerPeer {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/peers?xorb={s}",
            .{ self.tracker_url, xorb_hash_hex },
        );
        defer self.allocator.free(url);

        const body = self.httpGet(url) catch return &[_]TrackerPeer{};
        defer self.allocator.free(body);

        return self.parsePeerList(body) catch return &[_]TrackerPeer{};
    }

    /// Announce to the tracker that this peer has certain xorbs.
    pub fn announce(self: *TrackerClient, listen_addr: []const u8, xorb_hashes: []const [64]u8) !void {
        // Build JSON body: {"addr": "ip:port", "xorbs": ["hash1", "hash2", ...]}
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        try body.appendSlice("{\"addr\":\"");
        try body.appendSlice(listen_addr);
        try body.appendSlice("\",\"xorbs\":[");

        for (xorb_hashes, 0..) |hash_hex, i| {
            if (i > 0) try body.append(',');
            try body.append('"');
            try body.appendSlice(&hash_hex);
            try body.append('"');
        }
        try body.appendSlice("]}");

        const url = try std.fmt.allocPrint(self.allocator, "{s}/announce", .{self.tracker_url});
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        var header_buf: [8 * 1024]u8 = undefined;
        var req = try self.http_client.open(.POST, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.items.len };
        try req.send();
        try req.writer().writeAll(body.items);
        try req.finish();
        try req.wait();
    }

    fn parsePeerList(self: *TrackerClient, body: []const u8) ![]TrackerPeer {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            return &[_]TrackerPeer{};
        };
        defer parsed.deinit();

        if (parsed.value != .array) return &[_]TrackerPeer{};

        var peers = std.ArrayList(TrackerPeer).init(self.allocator);
        errdefer {
            for (peers.items) |p| self.allocator.free(p.addr);
            peers.deinit();
        }

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const addr_val = item.object.get("addr") orelse continue;
            if (addr_val != .string) continue;

            var last_seen: i64 = 0;
            if (item.object.get("last_seen")) |ls| {
                if (ls == .integer) last_seen = ls.integer;
            }

            try peers.append(.{
                .addr = try self.allocator.dupe(u8, addr_val.string),
                .last_seen = last_seen,
            });
        }

        return try peers.toOwnedSlice();
    }

    fn httpGet(self: *TrackerClient, url: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        var header_buf: [8 * 1024]u8 = undefined;
        var req = try self.http_client.open(.GET, uri, .{
            .server_header_buffer = &header_buf,
        });
        defer req.deinit();
        try req.send();
        try req.wait();

        if (req.response.status != .ok) return error.HttpError;

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();
        try req.reader().readAllArrayList(&body, 1024 * 1024);
        return try body.toOwnedSlice();
    }
};
