/// HTTP API server — localhost REST API for Python integration.
///
/// Listens on config.http_port (default 9847), provides:
///   GET  /v1/health  — simple health check
///   GET  /v1/status  — server stats as JSON
///   POST /v1/pull    — trigger model download (JSON body)
///   POST /v1/stop    — graceful shutdown
///
/// Uses std.http.Server for per-connection HTTP handling.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const config = @import("config.zig");
const storage = @import("storage.zig");
const server_mod = @import("server.zig");
const swarm = @import("swarm.zig");

pub const HttpApi = struct {
    allocator: std.mem.Allocator,
    io: Io,
    cfg: *const config.Config,
    bt_server: ?*server_mod.BtServer,
    listener: ?net.Server,
    shutdown_flag: *std.atomic.Value(bool),
    requests_served: std.atomic.Value(u64),
    xorbs_cached: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        cfg: *const config.Config,
        bt_server: ?*server_mod.BtServer,
        shutdown_flag: *std.atomic.Value(bool),
    ) HttpApi {
        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .bt_server = bt_server,
            .listener = null,
            .shutdown_flag = shutdown_flag,
            .requests_served = std.atomic.Value(u64).init(0),
            .xorbs_cached = 0,
        };
    }

    /// Start listening and handling HTTP requests. Blocks until shutdown.
    pub fn run(self: *HttpApi) !void {
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(self.cfg.http_port) };
        var listener = try addr.listen(self.io, .{
            .reuse_address = true,
        });
        self.listener = listener;
        defer {
            listener.deinit(self.io);
            self.listener = null;
        }

        // Count cached xorbs on startup
        const cached = storage.listCachedXorbs(self.allocator, self.cfg) catch &[_][]const u8{};
        self.xorbs_cached = cached.len;
        for (cached) |h| self.allocator.free(h);
        self.allocator.free(cached);

        while (!self.shutdown_flag.load(.acquire)) {
            const stream = listener.accept(self.io) catch {
                if (self.shutdown_flag.load(.acquire)) break;
                continue;
            };

            self.handleConnection(stream);
        }
    }

    fn handleConnection(self: *HttpApi, stream: net.Stream) void {
        defer stream.close(self.io);

        self.handleConnectionInner(stream) catch {};
    }

    fn handleConnectionInner(self: *HttpApi, stream: net.Stream) !void {
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var sr = stream.reader(self.io, &read_buf);
        var sw = stream.writer(self.io, &write_buf);

        var http_server = std.http.Server.init(&sr.interface, &sw.interface);

        const request = http_server.receiveHead() catch return;

        _ = self.requests_served.fetchAdd(1, .monotonic);

        self.routeRequest(&http_server, request) catch {};
    }

    fn routeRequest(self: *HttpApi, http_server: *std.http.Server, request: std.http.Server.Request) !void {
        const target = request.head.target;

        if (std.mem.eql(u8, target, "/v1/health")) {
            try self.handleHealth(http_server, request);
        } else if (std.mem.eql(u8, target, "/v1/status")) {
            try self.handleStatus(http_server, request);
        } else if (std.mem.eql(u8, target, "/v1/stop")) {
            try self.handleStop(http_server, request);
        } else if (std.mem.startsWith(u8, target, "/v1/pull")) {
            try self.handlePull(http_server, request);
        } else {
            try self.sendJson(http_server, request, .not_found, "{\"error\":\"not found\"}");
        }
    }

    fn handleHealth(self: *HttpApi, http_server: *std.http.Server, request: std.http.Server.Request) !void {
        try self.sendJson(http_server, request, .ok, "{\"status\":\"ok\"}");
    }

    fn handleStatus(self: *HttpApi, http_server: *std.http.Server, request: std.http.Server.Request) !void {
        const bt_stats = if (self.bt_server) |bs| bs.getStats() else server_mod.ServerStats{ .active_peers = 0, .chunks_served = 0 };

        var json_buf: [1024]u8 = undefined;
        const json = std.fmt.bufPrint(&json_buf,
            \\{{"version":"0.3.0","bt_peers":{d},"chunks_served":{d},"xorbs_cached":{d},"http_requests":{d},"http_port":{d},"bt_port":{d}}}
        , .{
            bt_stats.active_peers,
            bt_stats.chunks_served,
            self.xorbs_cached,
            self.requests_served.load(.monotonic),
            self.cfg.http_port,
            self.cfg.listen_port,
        }) catch return;

        try self.sendJson(http_server, request, .ok, json);
    }

    fn handlePull(self: *HttpApi, http_server: *std.http.Server, request: std.http.Server.Request) !void {
        // TODO: Parse JSON body, trigger download, stream SSE progress
        // For now, return a placeholder response
        try self.sendJson(http_server, request, .ok, "{\"status\":\"pull not yet implemented via HTTP API\"}");
    }

    fn handleStop(self: *HttpApi, http_server: *std.http.Server, request: std.http.Server.Request) !void {
        try self.sendJson(http_server, request, .ok, "{\"status\":\"shutting down\"}");
        self.shutdown_flag.store(true, .release);
        // Shut down the BT server too
        if (self.bt_server) |bs| bs.shutdown();
    }

    fn sendJson(_: *HttpApi, _: *std.http.Server, request: std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
        var req = request;
        try req.respond(body, .{
            .status = status,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
    }
};

// ── Tests ──

test "HttpApi init" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    var api = HttpApi.init(std.testing.allocator, std.testing.io, &cfg, null, &shutdown);
    try std.testing.expectEqual(@as(u64, 0), api.requests_served.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), api.xorbs_cached);
}

test "HttpApi shutdown via flag" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    var shutdown = std.atomic.Value(bool).init(false);
    const api = HttpApi.init(std.testing.allocator, std.testing.io, &cfg, null, &shutdown);
    _ = api;
    try std.testing.expect(!shutdown.load(.monotonic));
    shutdown.store(true, .release);
    try std.testing.expect(shutdown.load(.monotonic));
}
