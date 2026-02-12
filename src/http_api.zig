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
        } else if (std.mem.eql(u8, target, "/v1/models")) {
            try self.handleModels(http_server, request);
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

    /// Scan HF cache for downloaded models and return as JSON array.
    fn handleModels(self: *HttpApi, http_server: *std.http.Server, request: std.http.Server.Request) !void {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);
        try json.append(self.allocator, '[');

        scan: {
            var hub_dir = Io.Dir.openDirAbsolute(self.io, self.cfg.hf_cache_dir, .{ .iterate = true }) catch break :scan;
            defer hub_dir.close(self.io);

            var it = hub_dir.iterate();
            var first: bool = true;
            while (it.next(self.io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                const prefix = "models--";
                if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
                const raw = entry.name[prefix.len..];
                if (raw.len == 0) continue;

                // Count files in latest snapshot
                var file_count: usize = 0;
                count: {
                    var model_dir = hub_dir.openDir(self.io, entry.name, .{ .iterate = true }) catch break :count;
                    defer model_dir.close(self.io);
                    var snap_dir = model_dir.openDir(self.io, "snapshots", .{ .iterate = true }) catch break :count;
                    defer snap_dir.close(self.io);
                    var snap_it = snap_dir.iterate();
                    const snap_entry = snap_it.next(self.io) catch null orelse break :count;
                    if (snap_entry.kind != .directory) break :count;
                    var file_dir = snap_dir.openDir(self.io, snap_entry.name, .{ .iterate = true }) catch break :count;
                    defer file_dir.close(self.io);
                    var file_it = file_dir.iterate();
                    while (file_it.next(self.io) catch null) |_| {
                        file_count += 1;
                    }
                }

                if (!first) try json.append(self.allocator, ',');
                first = false;

                try json.appendSlice(self.allocator, "{\"name\":\"");
                // Convert first -- back to / (models--org--name → org/name)
                if (std.mem.indexOf(u8, raw, "--")) |sep| {
                    try json.appendSlice(self.allocator, raw[0..sep]);
                    try json.append(self.allocator, '/');
                    try json.appendSlice(self.allocator, raw[sep + 2..]);
                } else {
                    try json.appendSlice(self.allocator, raw);
                }
                try json.appendSlice(self.allocator, "\",\"files\":");
                var buf: [20]u8 = undefined;
                const count_str = std.fmt.bufPrint(&buf, "{d}", .{file_count}) catch "0";
                try json.appendSlice(self.allocator, count_str);
                try json.append(self.allocator, '}');
            }
        }

        try json.append(self.allocator, ']');
        try self.sendJson(http_server, request, .ok, json.items);
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
    \\<html lang="en"><head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>zest</title>
    \\<style>
    \\*{margin:0;padding:0;box-sizing:border-box}
    \\body{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;background:#09090b;color:#fafafa;min-height:100vh}
    \\.container{max-width:680px;margin:0 auto;padding:48px 20px}
    \\.header{display:flex;align-items:center;justify-content:space-between;margin-bottom:36px}
    \\.logo{display:flex;align-items:center;gap:10px}
    \\.logo-mark{width:32px;height:32px;background:linear-gradient(135deg,#22c55e 0%,#3b82f6 100%);
    \\  border-radius:8px;display:flex;align-items:center;justify-content:center;
    \\  font-weight:800;font-size:16px;color:#000}
    \\.logo h1{font-size:20px;font-weight:700;letter-spacing:-0.03em}
    \\.badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:500;
    \\  padding:5px 12px;border-radius:99px}
    \\.badge.on{background:#052e16;border:1px solid #166534;color:#4ade80}
    \\.badge.off{background:#1c1917;border:1px solid #44403c;color:#a8a29e}
    \\.pulse{width:7px;height:7px;border-radius:50%;background:currentColor}
    \\.badge.on .pulse{animation:pulse 2s infinite}
    \\@keyframes pulse{0%,100%{box-shadow:0 0 0 0 rgba(74,222,128,.4)}50%{box-shadow:0 0 0 6px rgba(74,222,128,0)}}
    \\.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:28px}
    \\.stat{background:#18181b;border:1px solid #27272a;border-radius:10px;padding:14px 16px}
    \\.stat .v{font-size:26px;font-weight:700;line-height:1.2;font-variant-numeric:tabular-nums}
    \\.stat .v.green{color:#4ade80}
    \\.stat .l{font-size:10px;color:#71717a;text-transform:uppercase;letter-spacing:.06em;margin-top:3px}
    \\.sec{font-size:11px;color:#52525b;text-transform:uppercase;letter-spacing:.08em;
    \\  font-weight:600;margin-bottom:10px}
    \\.models{background:#18181b;border:1px solid #27272a;border-radius:10px;overflow:hidden;margin-bottom:28px}
    \\.model{padding:14px 16px;border-bottom:1px solid #27272a;display:flex;
    \\  align-items:center;justify-content:space-between;transition:background .1s}
    \\.model:last-child{border-bottom:none}
    \\.model:hover{background:#1f1f23}
    \\.m-left{display:flex;align-items:center;gap:12px;min-width:0}
    \\.m-icon{width:34px;height:34px;background:#27272a;border-radius:8px;display:flex;
    \\  align-items:center;justify-content:center;font-size:18px;flex-shrink:0}
    \\.m-name{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    \\.m-org{color:#a1a1aa;font-weight:400}
    \\.m-meta{font-size:11px;color:#52525b;margin-top:2px}
    \\.m-status{font-size:11px;color:#4ade80;display:flex;align-items:center;gap:5px;flex-shrink:0}
    \\.m-dot{width:5px;height:5px;border-radius:50%;background:#4ade80}
    \\.empty{padding:40px 16px;text-align:center;color:#52525b;font-size:13px}
    \\.empty code{background:#27272a;padding:2px 6px;border-radius:4px;font-size:12px}
    \\.footer{display:flex;justify-content:space-between;align-items:center;
    \\  padding-top:20px;border-top:1px solid #27272a;font-size:11px;color:#52525b}
    \\.footer a{color:#71717a;text-decoration:none}.footer a:hover{color:#a1a1aa}
    \\.stop{background:none;color:#52525b;border:1px solid #27272a;padding:5px 12px;
    \\  border-radius:6px;cursor:pointer;font-size:11px;transition:all .15s}
    \\.stop:hover{background:#450a0a;color:#fca5a5;border-color:#7f1d1d}
    \\@media(max-width:520px){.stats{grid-template-columns:repeat(2,1fr)}}
    \\</style></head>
    \\<body>
    \\<div class="container">
    \\  <div class="header">
    \\    <div class="logo">
    \\      <div class="logo-mark">Z</div>
    \\      <h1>zest</h1>
    \\    </div>
    \\    <div class="badge on" id="badge">
    \\      <div class="pulse"></div>
    \\      <span id="status">Seeding</span>
    \\    </div>
    \\  </div>
    \\  <div class="stats">
    \\    <div class="stat"><div class="v green" id="peers">0</div><div class="l">Peers</div></div>
    \\    <div class="stat"><div class="v" id="chunks">0</div><div class="l">Served</div></div>
    \\    <div class="stat"><div class="v" id="xorbs">0</div><div class="l">Xorbs</div></div>
    \\    <div class="stat"><div class="v" id="uptime">0s</div><div class="l">Uptime</div></div>
    \\  </div>
    \\  <div class="sec">Models being seeded</div>
    \\  <div class="models" id="models">
    \\    <div class="empty">Loading...</div>
    \\  </div>
    \\  <div class="footer">
    \\    <div>BT <span id="bt-port">:6881</span> &middot; HTTP <span id="http-port">:9847</span>
    \\      &middot; <a href="https://github.com/praveer13/zest">GitHub</a></div>
    \\    <button class="stop" onclick="stopZest()">Stop server</button>
    \\  </div>
    \\</div>
    \\<script>
    \\var t0=Date.now();
    \\function fmtTime(ms){var s=ms/1000|0;if(s<60)return s+'s';var m=s/60|0;
    \\  if(m<60)return m+'m '+s%60+'s';var h=m/60|0;return h+'h '+m%60+'m'}
    \\function renderModels(ms){var el=document.getElementById('models');
    \\  if(!ms||!ms.length){el.innerHTML='<div class="empty">No models yet.<br>Run <code>zest pull &lt;repo&gt;</code> to get started.</div>';return}
    \\  el.innerHTML=ms.map(function(m){var p=m.name.split('/'),
    \\    org=p.length>1?'<span class="m-org">'+p[0]+'/</span>':'',
    \\    name=p.length>1?p[1]:p[0];
    \\    return '<div class="model"><div class="m-left">'
    \\    +'<div class="m-icon">&#x1F917;</div>'
    \\    +'<div><div class="m-name">'+org+name+'</div>'
    \\    +'<div class="m-meta">'+m.files+' files</div></div></div>'
    \\    +'<div class="m-status"><div class="m-dot"></div>Seeding</div></div>'}).join('')}
    \\async function update(){try{
    \\  var r=await Promise.all([fetch('/v1/status'),fetch('/v1/models')]);
    \\  var d=await r[0].json(),ms=await r[1].json();
    \\  document.getElementById('peers').textContent=d.bt_peers;
    \\  document.getElementById('chunks').textContent=d.chunks_served.toLocaleString();
    \\  document.getElementById('xorbs').textContent=d.xorbs_cached;
    \\  document.getElementById('uptime').textContent=fmtTime(Date.now()-t0);
    \\  document.getElementById('bt-port').textContent=':'+d.bt_port;
    \\  document.getElementById('http-port').textContent=':'+d.http_port;
    \\  document.getElementById('badge').className='badge on';
    \\  document.getElementById('status').textContent='Seeding';
    \\  renderModels(ms);
    \\}catch(e){document.getElementById('badge').className='badge off';
    \\  document.getElementById('status').textContent='Offline'}}
    \\async function stopZest(){if(!confirm('Stop seeding?'))return;
    \\  try{await fetch('/v1/stop',{method:'POST'})}catch(e){}
    \\  document.getElementById('badge').className='badge off';
    \\  document.getElementById('status').textContent='Stopped'}
    \\update();setInterval(update,2000);
    \\</script>
    \\</body></html>
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
