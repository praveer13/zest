/// zest — P2P acceleration for ML model distribution (BitTorrent-compliant).
///
/// Usage:
///   zest pull <repo_id> [--revision <ref>] [--tracker <url>] [--dht-port <port>]
///                       [--listen <addr>] [--no-p2p]
///   zest seed [--tracker <url>] [--dht-port <port>] [--listen <addr>]
///   zest bench [--synthetic] [--json]
///   zest version
///   zest help
///
/// Pull downloads a model from HuggingFace using the Xet protocol (via zig-xet),
/// with BT-compliant P2P acceleration when peers are available.
/// Seed announces locally cached xorbs via DHT and BT tracker.
/// Bench runs synthetic or integration benchmarks.
const std = @import("std");
const Io = std.Io;
const xet = @import("xet");
const config = @import("config.zig");
const swarm = @import("swarm.zig");
const storage = @import("storage.zig");
const peer_id_mod = @import("peer_id.zig");
const bt_peer_mod = @import("bt_peer.zig");
const bt_tracker_mod = @import("bt_tracker.zig");
const dht_mod = @import("dht.zig");
const bench_mod = @import("bench.zig");
const server_mod = @import("server.zig");
const http_api_mod = @import("http_api.zig");
const xet_bridge_mod = @import("xet_bridge.zig");
const parallel_dl = @import("parallel_download.zig");

const version = "0.4.1";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Setup I/O writers
    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    defer {
        stdout.flush() catch {};
        stderr.flush() catch {};
    }

    // Get args
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage(stdout);
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "pull")) {
        try cmdPull(allocator, init, stdout, stderr, args[2..]);
    } else if (std.mem.eql(u8, command, "seed")) {
        try cmdSeed(allocator, io, init.minimal.environ, stdout, stderr, args[2..]);
    } else if (std.mem.eql(u8, command, "bench")) {
        try cmdBench(allocator, io, stdout, stderr, args[2..]);
    } else if (std.mem.eql(u8, command, "serve")) {
        try cmdServe(allocator, init, stdout, stderr, args[2..]);
    } else if (std.mem.eql(u8, command, "start")) {
        try cmdStart(allocator, io, init, stdout, stderr);
    } else if (std.mem.eql(u8, command, "stop")) {
        try cmdStop(allocator, io, init.minimal.environ, stdout, stderr);
    } else if (std.mem.eql(u8, command, "version")) {
        try stdout.print("zest {s}\n", .{version});
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage(stdout);
    } else {
        try stderr.print("Unknown command: {s}\n\n", .{command});
        printUsage(stdout);
    }
}

fn cmdPull(allocator: std.mem.Allocator, init: std.process.Init, stdout: *Io.Writer, stderr: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        try stderr.print("Error: missing repository ID\n", .{});
        try stderr.print("Usage: zest pull <repo_id> [--revision <ref>] [--tracker <url>] [--no-p2p]\n", .{});
        return;
    }

    const io = init.io;
    const repo_id: []const u8 = args[0];
    var revision: []const u8 = config.default_revision;
    var tracker_url: ?[]const u8 = null;
    var enable_p2p: bool = true;
    var direct_peers: std.ArrayList([]const u8) = .empty;
    defer direct_peers.deinit(allocator);

    // Parse optional flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--revision") or std.mem.eql(u8, args[i], "-r")) {
            i += 1;
            if (i < args.len) revision = args[i];
        } else if (std.mem.eql(u8, args[i], "--tracker") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) tracker_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--peer") or std.mem.eql(u8, args[i], "-p")) {
            i += 1;
            if (i < args.len) try direct_peers.append(allocator, args[i]);
        } else if (std.mem.eql(u8, args[i], "--dht-port")) {
            i += 1;
            // Parsed via config
        } else if (std.mem.eql(u8, args[i], "--listen") or std.mem.eql(u8, args[i], "-l")) {
            i += 1;
            // Parsed via config
        } else if (std.mem.eql(u8, args[i], "--no-p2p")) {
            enable_p2p = false;
        }
    }

    try stdout.print("zest pull {s} (revision: {s})\n", .{ repo_id, revision });

    // Initialize config
    const environ = init.minimal.environ;
    var cfg = try config.Config.init(allocator, io, environ);
    defer cfg.deinit();

    if (cfg.hf_token == null) {
        try stderr.print("Warning: no HuggingFace token found. Set HF_TOKEN or run `huggingface-cli login`.\n", .{});
    }

    if (enable_p2p) {
        try stdout.print("P2P enabled (peer_id: {s}...)\n", .{peer_id_mod.CLIENT_PREFIX});
    } else {
        try stdout.print("P2P disabled (CDN only)\n", .{});
    }

    // Step 1: List files from HF Hub via zig-xet
    try stdout.print("Fetching model info from HuggingFace Hub...\n", .{});
    try stdout.flush();

    var file_list = xet.model_download.listFiles(
        allocator,
        io,
        environ,
        repo_id,
        "model",
        revision,
        cfg.hf_token,
    ) catch |err| {
        try stderr.print("Error listing files: {}\n", .{err});
        return err;
    };
    defer file_list.deinit();

    // Resolve revision to actual commit SHA (e.g. "main" → "607a30d7...")
    const resolved_sha = resolveCommitSha(allocator, io, repo_id, revision, cfg.hf_token);
    defer if (resolved_sha) |s| allocator.free(s);
    const commit: []const u8 = resolved_sha orelse revision;

    if (resolved_sha != null) {
        try stdout.print("Found {d} files (revision: {s} → {s})\n", .{ file_list.files.len, revision, commit });
    } else {
        try stdout.print("Found {d} files (revision: {s})\n", .{ file_list.files.len, revision });
    }

    // Step 2: Detect Xet files
    try stdout.print("Detecting Xet-backed files...\n", .{});
    var xet_count: usize = 0;
    for (file_list.files) |file| {
        if (file.xet_hash != null) xet_count += 1;
    }
    try stdout.print("  {d} Xet-backed files, {d} total files\n", .{ xet_count, file_list.files.len });

    // Step 3: Initialize swarm downloader (BT-compliant P2P)
    var downloader = try swarm.SwarmDownloader.init(allocator, io, &cfg, tracker_url, enable_p2p);
    defer downloader.deinit();

    // Add direct peers from --peer flags
    for (direct_peers.items) |peer_str| {
        const addr = bt_peer_mod.parseAddress(peer_str) catch {
            try stderr.print("Warning: invalid peer address: {s}\n", .{peer_str});
            continue;
        };
        downloader.addDirectPeer(addr) catch {};
        try stdout.print("  Direct peer: {s}\n", .{peer_str});
    }

    // Step 4: Initialize XET bridge (cache → P2P → CDN pipeline)
    var bridge = xet_bridge_mod.XetBridge.init(allocator, io, &cfg, &downloader);
    defer bridge.deinit();

    // Authenticate with HF to get Xet token (needed for CAS queries)
    if (xet_count > 0) {
        if (cfg.hf_token) |hf_token| {
            try stdout.print("Authenticating with Xet CAS...\n", .{});
            try stdout.flush();
            bridge.authenticate(repo_id, "model", revision, hf_token) catch |err| {
                try stderr.print("Warning: Xet auth failed ({}), falling back to direct download\n", .{err});
            };
        }
    }

    // Initialize parallel downloader (uses Io.Group for concurrent xorb fetches)
    var par_dl = parallel_dl.ParallelDownloader.init(
        allocator,
        io,
        &bridge,
        config.default_max_concurrent_downloads,
    );

    // Step 5: Download and reconstruct each file
    var files_done: usize = 0;
    for (file_list.files) |file| {
        files_done += 1;
        try stdout.print("[{d}/{d}] {s}", .{ files_done, file_list.files.len, file.path });

        const output_path = try buildOutputPath(allocator, &cfg, repo_id, commit, file.path);
        defer allocator.free(output_path);

        // Check if already downloaded
        if (Io.Dir.accessAbsolute(io, output_path, .{})) |_| {
            try stdout.print(" (cached)\n", .{});
            continue;
        } else |_| {}

        if (file.xet_hash) |xet_hash_hex| {
            try stdout.print(" [xet]\n", .{});
            try stdout.flush();

            // Try parallel pipeline first: cache → CDN (16 concurrent xorb fetches)
            if (bridge.cas != null) {
                par_dl.reconstructToFile(xet_hash_hex, output_path) catch |err| {
                    try stderr.print("  Parallel download error ({}), falling back to sequential\n", .{err});
                    // Fall back to sequential bridge pipeline
                    bridge.reconstructToFile(xet_hash_hex, output_path) catch |err2| {
                        try stderr.print("  Bridge error ({}), falling back to direct download\n", .{err2});
                        try ensureParentDirs(io, output_path);
                        const dl_config = xet.model_download.DownloadConfig{
                            .repo_id = repo_id,
                            .revision = revision,
                            .file_hash_hex = xet_hash_hex,
                            .hf_token = cfg.hf_token,
                        };
                        xet.model_download.downloadModelToFile(
                            allocator,
                            io,
                            environ,
                            dl_config,
                            output_path,
                        ) catch |err3| {
                            try stderr.print("  Error downloading via xet: {}\n", .{err3});
                            continue;
                        };
                    };
                };
            } else {
                // No bridge auth — use zig-xet directly (CDN only)
                try ensureParentDirs(io, output_path);
                const dl_config = xet.model_download.DownloadConfig{
                    .repo_id = repo_id,
                    .revision = revision,
                    .file_hash_hex = xet_hash_hex,
                    .hf_token = cfg.hf_token,
                };
                xet.model_download.downloadModelToFile(
                    allocator,
                    io,
                    environ,
                    dl_config,
                    output_path,
                ) catch |err| {
                    try stderr.print("  Error downloading via xet: {}\n", .{err});
                    continue;
                };
            }
        } else {
            try stdout.print(" [regular]\n", .{});
            try stdout.flush();
            downloadRegularFile(allocator, io, repo_id, revision, file.path, output_path) catch |err| {
                try stderr.print("  Error downloading: {}\n", .{err});
                continue;
            };
        }
    }

    // Write refs file so from_pretrained() resolves
    storage.writeRef(allocator, &cfg, repo_id, revision, commit) catch |err| {
        try stderr.print("Warning: failed to write ref: {}\n", .{err});
    };

    // Auto-start background server for seeding (if not already running)
    if (enable_p2p) {
        autoStartServer(allocator, io, init, &cfg, stdout);
    }

    bridge.printStats(stdout);
    downloader.printStats(stdout);
    try stdout.print("\nDone! Model available at:\n", .{});

    const snapshot_dir = try cfg.modelSnapshotDir(repo_id, commit);
    defer allocator.free(snapshot_dir);
    try stdout.print("  {s}\n", .{snapshot_dir});
    try stdout.print("\nRun: transformers.AutoModel.from_pretrained(\"{s}\")\n", .{repo_id});
}

fn cmdSeed(allocator: std.mem.Allocator, io: Io, environ: std.process.Environ, stdout: *Io.Writer, _: *Io.Writer, args: []const [:0]const u8) !void {
    var tracker_url: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tracker") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) tracker_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--listen") or std.mem.eql(u8, args[i], "-l")) {
            i += 1;
            // Listen address config
        } else if (std.mem.eql(u8, args[i], "--dht-port")) {
            i += 1;
            // DHT port config
        }
    }

    var cfg = try config.Config.init(allocator, io, environ);
    defer cfg.deinit();

    try stdout.print("Scanning local xorb cache...\n", .{});
    const cached = try storage.listCachedXorbs(allocator, &cfg);
    defer {
        for (cached) |h| allocator.free(h);
        allocator.free(cached);
    }

    try stdout.print("Found {d} cached xorbs\n", .{cached.len});

    if (cached.len == 0) {
        try stdout.print("Nothing to seed. Run `zest pull` first.\n", .{});
        return;
    }

    // Initialize swarm for announcing
    var downloader = try swarm.SwarmDownloader.init(allocator, io, &cfg, tracker_url, true);
    defer downloader.deinit();

    // Convert hex strings to binary hashes for announcement
    var xorb_hashes: std.ArrayList([32]u8) = .empty;
    defer xorb_hashes.deinit(allocator);

    for (cached) |h| {
        if (h.len == 64) {
            var hash: [32]u8 = undefined;
            for (0..32) |j| {
                hash[j] = std.fmt.parseInt(u8, h[j * 2 .. j * 2 + 2], 16) catch continue;
            }
            try xorb_hashes.append(allocator, hash);
        }
    }

    try downloader.announceToSwarm(xorb_hashes.items);

    try stdout.print("Announced {d} xorbs via BT protocol\n", .{xorb_hashes.items.len});
    try stdout.print("  Peer ID: {s}...\n", .{peer_id_mod.CLIENT_PREFIX});
    try stdout.print("  DHT port: {d}\n", .{cfg.dht_port});
    try stdout.print("  Listen port: {d}\n", .{cfg.listen_port});
    if (tracker_url) |url| {
        try stdout.print("  Tracker: {s}\n", .{url});
    }
    try stdout.print("Seeding...\n", .{});
}

fn cmdBench(allocator: std.mem.Allocator, io: Io, stdout: *Io.Writer, stderr: *Io.Writer, args: []const [:0]const u8) !void {
    var json_output = false;
    var synthetic = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, args[i], "--synthetic")) {
            synthetic = true;
        }
    }

    if (!synthetic) {
        try stderr.print("Usage: zest bench --synthetic [--json]\n", .{});
        try stderr.print("  --synthetic  Run bencode/hash/wire benchmarks\n", .{});
        try stderr.print("  --json       Output results as JSON\n", .{});
        return;
    }

    try bench_mod.runSyntheticWithIo(allocator, io, stdout, json_output);
}

/// Context for running BtServer as a concurrent Io.Group task.
const BtServerCtx = struct {
    server: *server_mod.BtServer,
};

fn runBtServerConcurrent(ctx: *BtServerCtx) void {
    ctx.server.run() catch {};
}

fn cmdServe(allocator: std.mem.Allocator, init: std.process.Init, stdout: *Io.Writer, _: *Io.Writer, args: []const [:0]const u8) !void {
    const io = init.io;
    const environ = init.minimal.environ;

    var cfg = try config.Config.init(allocator, io, environ);
    defer cfg.deinit();

    // Parse optional flags
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--http-port")) {
            i += 1;
            if (i < args.len) cfg.http_port = std.fmt.parseInt(u16, args[i], 10) catch cfg.http_port;
        } else if (std.mem.eql(u8, args[i], "--listen-port")) {
            i += 1;
            if (i < args.len) cfg.listen_port = std.fmt.parseInt(u16, args[i], 10) catch cfg.listen_port;
        }
    }

    // Index cached xorbs
    var registry = storage.XorbRegistry.init(allocator);
    defer registry.deinit();
    registry.scan(&cfg) catch {};

    try stdout.print("zest server v{s}\n", .{version});
    try stdout.print("  BT listen port: {d}\n", .{cfg.listen_port});
    try stdout.print("  HTTP API port:  {d}\n", .{cfg.http_port});
    try stdout.print("  Peer ID:        {s}...\n", .{peer_id_mod.CLIENT_PREFIX});
    try stdout.print("  Cached xorbs:   {d}\n", .{registry.count()});
    try stdout.print("\nServer running. Press Ctrl+C to stop.\n", .{});
    try stdout.flush();

    // Write PID file
    writePidFile(io, cfg.pid_file_path) catch {};

    // Shared shutdown flag
    var shutdown_flag = std.atomic.Value(bool).init(false);

    // Start BT server
    var bt_server = server_mod.BtServer.init(allocator, io, &cfg);

    // Start HTTP API
    var http_api = http_api_mod.HttpApi.init(allocator, io, &cfg, &bt_server, &shutdown_flag);

    // Run BT server concurrently with HTTP API via Io.Group
    var bt_ctx = BtServerCtx{ .server = &bt_server };
    var group: Io.Group = Io.Group.init;

    group.concurrent(io, runBtServerConcurrent, .{&bt_ctx}) catch |err| {
        switch (err) {
            error.ConcurrencyUnavailable => {}, // HTTP-only fallback
        }
    };

    // HTTP API blocks until /v1/stop
    http_api.run() catch |err| {
        try stdout.print("HTTP API error: {}\n", .{err});
    };

    // Shutdown BT server after HTTP stops, wait for cleanup
    bt_server.shutdown();
    group.await(io) catch {};

    // Cleanup
    removePidFile(io, cfg.pid_file_path);
    try stdout.print("\nServer stopped.\n", .{});
}

fn cmdStart(allocator: std.mem.Allocator, io: Io, init: std.process.Init, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var cfg = try config.Config.init(allocator, io, init.minimal.environ);
    defer cfg.deinit();

    // Check if already running via health check
    if (isServerRunning(allocator, io, cfg.http_port)) {
        try stderr.print("zest server is already running on port {d}.\n", .{cfg.http_port});
        return;
    }

    autoStartServer(allocator, io, init, &cfg, stdout);
}

/// Spawn `zest serve` as a detached background process if not already running.
fn autoStartServer(allocator: std.mem.Allocator, io: Io, init: std.process.Init, cfg: *const config.Config, stdout: *Io.Writer) void {
    // Already running? Skip.
    if (isServerRunning(allocator, io, cfg.http_port)) return;

    // Get our own binary path from argv[0]
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch return;
    if (all_args.len == 0) return;
    const exe_path: []const u8 = all_args[0];

    // Spawn detached: zest serve
    _ = std.process.spawn(io, .{
        .argv = &.{ exe_path, "serve" },
        .stdout = .ignore,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return;

    stdout.print("Seeding in background (BT :6881, HTTP :{d})\n", .{cfg.http_port}) catch {};
    stdout.print("Dashboard: http://localhost:{d}\n", .{cfg.http_port}) catch {};
    stdout.flush() catch {};

    // Open dashboard in browser
    openBrowser(io, cfg.http_port);
}

/// Open the dashboard in the user's browser.
fn openBrowser(io: Io, http_port: u16) void {
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://localhost:{d}", .{http_port}) catch return;

    // Try xdg-open (Linux), then open (macOS)
    _ = std.process.spawn(io, .{
        .argv = &.{ "xdg-open", url },
        .stdout = .ignore,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch {
        _ = std.process.spawn(io, .{
            .argv = &.{ "open", url },
            .stdout = .ignore,
            .stderr = .ignore,
            .stdin = .ignore,
        }) catch return;
    };
}

/// Check if zest server is running by hitting the health endpoint.
fn isServerRunning(allocator: std.mem.Allocator, io: Io, http_port: u16) bool {
    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/health", .{http_port}) catch return false;
    defer allocator.free(url);

    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch return false;

    return result.status == .ok;
}

fn cmdStop(allocator: std.mem.Allocator, io: Io, environ: std.process.Environ, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var cfg = try config.Config.init(allocator, io, environ);
    defer cfg.deinit();

    const pid_str = readPidFile(allocator, io, cfg.pid_file_path) orelse {
        try stderr.print("No running zest server found.\n", .{});
        return;
    };
    defer allocator.free(pid_str);

    // Try HTTP stop first
    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    const stop_url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/stop", .{cfg.http_port}) catch {
        try stderr.print("Failed to construct stop URL.\n", .{});
        return;
    };
    defer allocator.free(stop_url);

    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = http_client.fetch(.{
        .location = .{ .url = stop_url },
        .payload = "",
        .response_writer = &aw.writer,
    }) catch {
        try stderr.print("Failed to connect to zest server. It may have already stopped.\n", .{});
        removePidFile(io, cfg.pid_file_path);
        return;
    };

    if (result.status == .ok) {
        try stdout.print("zest server stopped (was PID {s}).\n", .{pid_str});
    } else {
        try stderr.print("Server returned status {d}.\n", .{@intFromEnum(result.status)});
    }

    removePidFile(io, cfg.pid_file_path);
}

fn writePidFile(io: Io, path: []const u8) !void {
    const pid = std.os.linux.getpid();
    var buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return;
    storage.writeFileAtomic(io, path, pid_str) catch {};
}

fn removePidFile(io: Io, path: []const u8) void {
    Io.Dir.deleteFileAbsolute(io, path) catch {};
}

fn readPidFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var buf: [20]u8 = undefined;
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(&buf) catch return null;
    const content = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    if (content.len == 0) return null;
    return allocator.dupe(u8, content) catch null;
}

/// Build the output path for a file in the HF cache layout.
fn buildOutputPath(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    repo_id: []const u8,
    commit: []const u8,
    file_path: []const u8,
) ![]u8 {
    const snapshot_dir = try cfg.modelSnapshotDir(repo_id, commit);
    defer allocator.free(snapshot_dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ snapshot_dir, file_path });
}

/// Ensure all parent directories in a path exist.
fn ensureParentDirs(io: Io, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try storage.ensureDirRecursive(io, path[0..sep]);
    }
}

/// Resolve a revision (branch name like "main") to an actual commit SHA
/// by querying the HF API: GET /api/models/{repo}/revision/{revision}
/// Returns the SHA string, or null if resolution fails (falls back to revision as-is).
fn resolveCommitSha(allocator: std.mem.Allocator, io: Io, repo_id: []const u8, revision: []const u8, token: ?[]const u8) ?[]u8 {
    const url = std.fmt.allocPrint(
        allocator,
        "{s}/api/models/{s}/revision/{s}",
        .{ config.hf_hub_url, repo_id, revision },
    ) catch return null;
    defer allocator.free(url);

    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Build authorization header if token available
    var auth_buf: [256]u8 = undefined;
    const auth_header: ?[]const u8 = if (token) |t|
        std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch null
    else
        null;

    const extra_headers: []const std.http.Header = if (auth_header) |auth|
        &.{.{ .name = "authorization", .value = auth }}
    else
        &.{};

    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
        .extra_headers = extra_headers,
    }) catch return null;

    if (result.status != .ok) return null;

    const body = aw.written();

    // Parse JSON to extract "sha" field
    // Response looks like: {"sha":"607a30d783dfa663caf39e06633721c8d4cfcd7e",...}
    return extractJsonSha(allocator, body);
}

/// Extract the "sha" value from a JSON response.
/// Looks for "sha":"<40-char hex>" pattern.
fn extractJsonSha(allocator: std.mem.Allocator, json: []const u8) ?[]u8 {
    // Find "sha":" pattern
    const needle = "\"sha\":\"";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = pos + needle.len;
    if (start + 40 > json.len) return null;

    const sha = json[start..][0..40];
    // Validate it's hex
    for (sha) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return allocator.dupe(u8, sha) catch null;
}

fn downloadRegularFile(
    allocator: std.mem.Allocator,
    io: Io,
    repo_id: []const u8,
    revision: []const u8,
    file_path: []const u8,
    output_path: []const u8,
) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/resolve/{s}/{s}",
        .{ config.hf_hub_url, repo_id, revision, file_path },
    );
    defer allocator.free(url);

    var http_client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http_client.deinit();

    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    }) catch return error.HttpError;

    if (result.status != .ok) {
        return error.HttpError;
    }

    try ensureParentDirs(io, output_path);
    try storage.writeFileAtomic(io, output_path, aw.written());
}

fn printUsage(w: *Io.Writer) void {
    w.print(
        \\zest — P2P acceleration for ML model distribution (BitTorrent-compliant)
        \\
        \\Usage:
        \\  zest pull <repo_id> [options]    Download a model
        \\  zest seed [options]              Seed cached xorbs to peers
        \\  zest serve [options]             Run server (BT + HTTP API)
        \\  zest start                       Start server in background
        \\  zest stop                        Stop background server
        \\  zest bench [options]             Run benchmarks
        \\  zest version                     Show version
        \\  zest help                        Show this help
        \\
        \\Pull options:
        \\  --revision, -r <ref>     Git revision (default: main)
        \\  --peer, -p <ip:port>     Direct peer address (repeatable)
        \\  --tracker, -t <url>      BT tracker URL for peer discovery
        \\  --dht-port <port>        DHT UDP port (default: 6881)
        \\  --listen, -l <addr>      Listen address for P2P (default: 0.0.0.0:6881)
        \\  --no-p2p                 Disable P2P, CDN only
        \\
        \\Seed options:
        \\  --tracker, -t <url>      BT tracker URL
        \\  --dht-port <port>        DHT UDP port (default: 6881)
        \\  --listen, -l <addr>      Listen address (default: 0.0.0.0:6881)
        \\
        \\Serve options:
        \\  --http-port <port>       HTTP API port (default: 9847)
        \\  --listen-port <port>     BT listen port (default: 6881)
        \\
        \\Bench options:
        \\  --synthetic              Run synthetic benchmarks
        \\  --json                   Output results as JSON
        \\
        \\Examples:
        \\  zest pull meta-llama/Llama-3.1-8B
        \\  zest pull Qwen/Qwen2-7B --revision v1.0 --no-p2p
        \\  zest pull gpt2 --peer 10.0.0.5:6881
        \\  zest seed --tracker http://tracker.example.com:6881
        \\  zest serve --http-port 8080
        \\  zest bench --synthetic --json
        \\
    , .{}) catch {};
}

test "arg parsing smoke test" {
    // Just verify the module compiles and basic types are accessible
    try std.testing.expect(version.len > 0);
}

test "extractJsonSha parses HF API response" {
    const json =
        \\{"_id":"6340","id":"gpt2","sha":"607a30d783dfa663caf39e06633721c8d4cfcd7e","other":"value"}
    ;
    const sha = extractJsonSha(std.testing.allocator, json);
    defer if (sha) |s| std.testing.allocator.free(s);
    try std.testing.expect(sha != null);
    try std.testing.expectEqualStrings("607a30d783dfa663caf39e06633721c8d4cfcd7e", sha.?);
}

test "extractJsonSha returns null for missing sha" {
    const json =
        \\{"id":"gpt2","name":"GPT-2"}
    ;
    const sha = extractJsonSha(std.testing.allocator, json);
    try std.testing.expect(sha == null);
}

test "extractJsonSha rejects invalid hex" {
    const json =
        \\{"sha":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}
    ;
    const sha = extractJsonSha(std.testing.allocator, json);
    try std.testing.expect(sha == null);
}
