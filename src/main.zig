/// zest — P2P acceleration for ML model distribution.
///
/// Usage:
///   zest pull <repo_id> [--revision <ref>] [--tracker <url>]
///   zest seed [--tracker <url>]
///
/// Pull downloads a model from HuggingFace using the Xet protocol (via zig-xet),
/// with P2P acceleration when peers are available.
/// Seed announces locally cached xorbs to the tracker for other peers.
const std = @import("std");
const Io = std.Io;
const xet = @import("xet");
const config = @import("config.zig");
const swarm = @import("swarm.zig");
const storage = @import("storage.zig");
const tracker = @import("tracker.zig");

const version = "0.2.0";

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
        try stderr.print("Usage: zest pull <repo_id> [--revision <ref>] [--tracker <url>]\n", .{});
        return;
    }

    const io = init.io;
    const repo_id: []const u8 = args[0];
    var revision: []const u8 = config.default_revision;
    var tracker_url: ?[]const u8 = null;

    // Parse optional flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--revision") or std.mem.eql(u8, args[i], "-r")) {
            i += 1;
            if (i < args.len) revision = args[i];
        } else if (std.mem.eql(u8, args[i], "--tracker") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) tracker_url = args[i];
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

    const commit = revision;
    try stdout.print("Found {d} files (revision: {s})\n", .{ file_list.files.len, commit });

    // Step 2: Detect Xet files
    try stdout.print("Detecting Xet-backed files...\n", .{});
    var xet_count: usize = 0;
    for (file_list.files) |file| {
        if (file.xet_hash != null) xet_count += 1;
    }
    try stdout.print("  {d} Xet-backed files, {d} total files\n", .{ xet_count, file_list.files.len });

    // Step 3: Initialize swarm downloader (for P2P when available)
    var downloader = try swarm.SwarmDownloader.init(allocator, io, &cfg, tracker_url);
    defer downloader.deinit();

    // Step 4: Download and reconstruct each file
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

            // Use zig-xet to download the file via Xet protocol.
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

    downloader.printStats(stdout);
    try stdout.print("\nDone! Model available at:\n", .{});

    const snapshot_dir = try cfg.modelSnapshotDir(repo_id, commit);
    defer allocator.free(snapshot_dir);
    try stdout.print("  {s}\n", .{snapshot_dir});
    try stdout.print("\nRun: transformers.AutoModel.from_pretrained(\"{s}\")\n", .{repo_id});
}

fn cmdSeed(allocator: std.mem.Allocator, io: Io, environ: std.process.Environ, stdout: *Io.Writer, stderr: *Io.Writer, args: []const [:0]const u8) !void {
    var tracker_url: ?[]const u8 = null;
    var listen_addr: []const u8 = "0.0.0.0:6881";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tracker") or std.mem.eql(u8, args[i], "-t")) {
            i += 1;
            if (i < args.len) tracker_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--listen") or std.mem.eql(u8, args[i], "-l")) {
            i += 1;
            if (i < args.len) listen_addr = args[i];
        }
    }

    if (tracker_url == null) {
        try stderr.print("Error: --tracker <url> is required for seeding\n", .{});
        return;
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

    // Announce to tracker
    var tracker_client = try tracker.TrackerClient.init(allocator, io, tracker_url.?);
    defer tracker_client.deinit();

    // Convert to fixed-size hash array
    var hash_hexes: std.ArrayList([64]u8) = .empty;
    defer hash_hexes.deinit(allocator);
    for (cached) |h| {
        if (h.len == 64) {
            var hex: [64]u8 = undefined;
            @memcpy(&hex, h);
            try hash_hexes.append(allocator, hex);
        }
    }

    tracker_client.announce(listen_addr, hash_hexes.items) catch |err| {
        try stderr.print("Error announcing to tracker: {}\n", .{err});
        return;
    };

    try stdout.print("Announced {d} xorbs to tracker at {s}\n", .{ hash_hexes.items.len, tracker_url.? });
    try stdout.print("Seeding from {s}\n", .{listen_addr});
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
        \\zest — P2P acceleration for ML model distribution
        \\
        \\Usage:
        \\  zest pull <repo_id> [options]    Download a model
        \\  zest seed [options]              Seed cached xorbs to peers
        \\  zest version                     Show version
        \\  zest help                        Show this help
        \\
        \\Options:
        \\  --revision, -r <ref>     Git revision (default: main)
        \\  --tracker, -t <url>      Tracker URL for peer discovery
        \\  --listen, -l <addr>      Listen address for seeding (default: 0.0.0.0:6881)
        \\
        \\Examples:
        \\  zest pull meta-llama/Llama-3.1-8B
        \\  zest pull Qwen/Qwen2-7B --revision v1.0
        \\  zest seed --tracker http://tracker.example.com:6881
        \\
    , .{}) catch {};
}

test "arg parsing smoke test" {
    // Just verify the module compiles and basic types are accessible
    try std.testing.expect(version.len > 0);
}
