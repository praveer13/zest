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
        } else if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/ui")) {
            try self.handleDashboard(http_server, request);
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

    fn handleDashboard(_: *HttpApi, _: *std.http.Server, request: std.http.Server.Request) !void {
        var req = request;
        try req.respond(dashboard_html, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
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

const dashboard_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>zest - P2P Seeding Status</title>
    \\<style>
    \\  * { margin: 0; padding: 0; box-sizing: border-box; }
    \\  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    \\    background: #0a0a0a; color: #e0e0e0; padding: 40px 20px; }
    \\  .container { max-width: 640px; margin: 0 auto; }
    \\  h1 { font-size: 24px; margin-bottom: 8px; color: #fff; }
    \\  h1 span { color: #4ade80; }
    \\  .subtitle { color: #888; margin-bottom: 32px; font-size: 14px; }
    \\  .card { background: #161616; border: 1px solid #2a2a2a; border-radius: 12px;
    \\    padding: 24px; margin-bottom: 16px; }
    \\  .card h2 { font-size: 14px; color: #888; text-transform: uppercase;
    \\    letter-spacing: 0.5px; margin-bottom: 16px; }
    \\  .stat-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    \\  .stat { }
    \\  .stat .value { font-size: 32px; font-weight: 700; color: #fff; }
    \\  .stat .label { font-size: 13px; color: #888; margin-top: 2px; }
    \\  .stat .value.green { color: #4ade80; }
    \\  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
    \\    margin-right: 8px; vertical-align: middle; }
    \\  .dot.on { background: #4ade80; box-shadow: 0 0 8px #4ade8066; }
    \\  .dot.off { background: #666; }
    \\  .status-line { font-size: 14px; color: #aaa; margin-bottom: 24px; }
    \\  .footer { text-align: center; color: #555; font-size: 12px; margin-top: 32px; }
    \\  .footer a { color: #888; }
    \\  .stop-btn { background: #2a2a2a; color: #e0e0e0; border: 1px solid #444;
    \\    padding: 8px 20px; border-radius: 8px; cursor: pointer; font-size: 13px;
    \\    float: right; margin-top: -4px; }
    \\  .stop-btn:hover { background: #dc2626; color: #fff; border-color: #dc2626; }
    \\</style>
    \\</head>
    \\<body>
    \\<div class="container">
    \\  <h1><span>zest</span> seeding status</h1>
    \\  <div class="status-line"><span class="dot on" id="dot"></span><span id="status-text">Seeding</span>
    \\    <button class="stop-btn" onclick="stopServer()">Stop Server</button></div>
    \\  <div class="card">
    \\    <h2>Network</h2>
    \\    <div class="stat-grid">
    \\      <div class="stat"><div class="value green" id="peers">0</div><div class="label">Connected peers</div></div>
    \\      <div class="stat"><div class="value" id="chunks">0</div><div class="label">Chunks served</div></div>
    \\    </div>
    \\  </div>
    \\  <div class="card">
    \\    <h2>Cache</h2>
    \\    <div class="stat-grid">
    \\      <div class="stat"><div class="value" id="xorbs">0</div><div class="label">Xorbs cached</div></div>
    \\      <div class="stat"><div class="value" id="requests">0</div><div class="label">HTTP requests</div></div>
    \\    </div>
    \\  </div>
    \\  <div class="card">
    \\    <h2>Server</h2>
    \\    <div class="stat-grid">
    \\      <div class="stat"><div class="value" id="bt-port" style="font-size:20px">-</div><div class="label">BT port</div></div>
    \\      <div class="stat"><div class="value" id="http-port" style="font-size:20px">-</div><div class="label">HTTP port</div></div>
    \\    </div>
    \\  </div>
    \\  <div class="footer">zest &mdash; P2P acceleration for ML model distribution &mdash;
    \\    <a href="https://github.com/praveer13/zest">GitHub</a></div>
    \\</div>
    \\<script>
    \\async function update() {
    \\  try {
    \\    const r = await fetch('/v1/status');
    \\    const d = await r.json();
    \\    document.getElementById('peers').textContent = d.bt_peers;
    \\    document.getElementById('chunks').textContent = d.chunks_served;
    \\    document.getElementById('xorbs').textContent = d.xorbs_cached;
    \\    document.getElementById('requests').textContent = d.http_requests;
    \\    document.getElementById('bt-port').textContent = ':' + d.bt_port;
    \\    document.getElementById('http-port').textContent = ':' + d.http_port;
    \\    document.getElementById('dot').className = 'dot on';
    \\    document.getElementById('status-text').textContent = 'Seeding';
    \\  } catch(e) {
    \\    document.getElementById('dot').className = 'dot off';
    \\    document.getElementById('status-text').textContent = 'Offline';
    \\  }
    \\}
    \\async function stopServer() {
    \\  if (!confirm('Stop the zest seeding server?')) return;
    \\  try { await fetch('/v1/stop', {method:'POST'}); } catch(e) {}
    \\  document.getElementById('dot').className = 'dot off';
    \\  document.getElementById('status-text').textContent = 'Stopped';
    \\}
    \\update(); setInterval(update, 2000);
    \\</script>
    \\</body>
    \\</html>
;

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
