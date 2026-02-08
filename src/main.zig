/// zest — P2P acceleration for ML model distribution.
///
/// Usage:
///   zest pull <repo_id> [--revision <ref>] [--tracker <url>]
///   zest seed [--tracker <url>]
///
/// Pull downloads a model from HuggingFace using the Xet protocol,
/// with P2P acceleration when peers are available.
/// Seed announces locally cached xorbs to the tracker for other peers.
const std = @import("std");
const config = @import("config.zig");
const hub = @import("hub.zig");
const cas = @import("cas.zig");
const cdn = @import("cdn.zig");
const reconstruct = @import("reconstruct.zig");
const swarm = @import("swarm.zig");
const storage = @import("storage.zig");
const tracker = @import("tracker.zig");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "pull")) {
        try cmdPull(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "seed")) {
        try cmdSeed(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "version")) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("zest {s}\n", .{version});
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
    } else {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Unknown command: {s}\n\n", .{command});
        printUsage();
    }
}

fn cmdPull(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (args.len < 1) {
        try stderr.print("Error: missing repository ID\n", .{});
        try stderr.print("Usage: zest pull <repo_id> [--revision <ref>] [--tracker <url>]\n", .{});
        return;
    }

    const repo_id = args[0];
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
    var cfg = try config.Config.init(allocator);
    defer cfg.deinit();

    if (cfg.hf_token == null) {
        try stderr.print("Warning: no HuggingFace token found. Set HF_TOKEN or run `huggingface-cli login`.\n", .{});
    }

    // Step 1: Get repo info from HF Hub
    try stdout.print("Fetching model info from HuggingFace Hub...\n", .{});
    var hub_client = hub.HubClient.init(allocator, &cfg);
    defer hub_client.deinit();

    var repo_info = hub_client.getRepoInfo(repo_id, revision) catch |err| {
        try stderr.print("Error fetching repo info: {}\n", .{err});
        return err;
    };
    defer repo_info.deinit();

    const commit = repo_info.commit_sha orelse revision;
    try stdout.print("Found {d} files (commit: {s})\n", .{ repo_info.files.len, commit });

    // Step 2: Probe files for Xet support
    try stdout.print("Detecting Xet-backed files...\n", .{});
    hub_client.probeAllFiles(&repo_info) catch |err| {
        try stderr.print("Warning: failed to probe Xet files: {}\n", .{err});
    };

    var xet_count: usize = 0;
    var total_size: u64 = 0;
    for (repo_info.files) |file| {
        if (file.xet_hash != null) xet_count += 1;
        total_size += file.size;
    }
    try stdout.print("  {d} Xet-backed files, {d} total files, {d} bytes total\n", .{ xet_count, repo_info.files.len, total_size });

    // Step 3: Initialize CAS client
    var cas_client = cas.CasClient.init(allocator, &cfg);
    defer cas_client.deinit();

    // Step 4: Initialize swarm downloader
    var downloader = try swarm.SwarmDownloader.init(allocator, &cfg, tracker_url);
    defer downloader.deinit();

    // Step 5: Download and reconstruct each file
    var files_done: usize = 0;
    for (repo_info.files) |file| {
        files_done += 1;
        try stdout.print("[{d}/{d}] {s}", .{ files_done, repo_info.files.len, file.path });

        const output_path = try reconstruct.buildOutputPath(allocator, &cfg, repo_id, commit, file.path);
        defer allocator.free(output_path);

        // Check if already downloaded
        if (std.fs.accessAbsolute(output_path, .{})) |_| {
            try stdout.print(" (cached)\n", .{});
            continue;
        } else |_| {}

        if (file.xet_hash) |xet_hash| {
            try stdout.print(" [xet]\n", .{});

            // Query CAS for reconstruction terms
            var recon = cas_client.getReconstructionInfo(xet_hash) catch |err| {
                try stderr.print("  Error querying CAS: {}\n", .{err});
                continue;
            };
            defer recon.deinit();

            try stdout.print("  {d} terms, {d} bytes\n", .{ recon.terms.len, recon.file_size });

            // Download xorbs via swarm (peers + CDN fallback)
            downloader.downloadXorbs(&recon) catch |err| {
                try stderr.print("  Error downloading xorbs: {}\n", .{err});
                continue;
            };

            // Reconstruct the file
            var cdn_dl = cdn.CdnDownloader.init(allocator);
            defer cdn_dl.deinit();
            reconstruct.reconstructFile(allocator, &cfg, &recon, output_path, &cdn_dl) catch |err| {
                try stderr.print("  Error reconstructing file: {}\n", .{err});
                continue;
            };
        } else {
            try stdout.print(" [regular]\n", .{});
            // For non-Xet files, download directly via HTTP
            // (small config/tokenizer files are typically not Xet-backed)
            downloadRegularFile(allocator, &cfg, repo_id, revision, file.path, output_path) catch |err| {
                try stderr.print("  Error downloading: {}\n", .{err});
                continue;
            };
        }
    }

    // Write refs file so from_pretrained() resolves
    storage.writeRef(allocator, &cfg, repo_id, revision, commit) catch |err| {
        try stderr.print("Warning: failed to write ref: {}\n", .{err});
    };

    downloader.printStats();
    try stdout.print("\nDone! Model available at:\n", .{});

    const snapshot_dir = try cfg.modelSnapshotDir(repo_id, commit);
    defer allocator.free(snapshot_dir);
    try stdout.print("  {s}\n", .{snapshot_dir});
    try stdout.print("\nRun: transformers.AutoModel.from_pretrained(\"{s}\")\n", .{repo_id});
}

fn cmdSeed(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

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

    var cfg = try config.Config.init(allocator);
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
    var tracker_client = try tracker.TrackerClient.init(allocator, tracker_url.?);
    defer tracker_client.deinit();

    // Convert to fixed-size hash array
    var hash_hexes = std.ArrayList([64]u8).init(allocator);
    defer hash_hexes.deinit();
    for (cached) |h| {
        if (h.len == 64) {
            var hex: [64]u8 = undefined;
            @memcpy(&hex, h);
            try hash_hexes.append(hex);
        }
    }

    tracker_client.announce(listen_addr, hash_hexes.items) catch |err| {
        try stderr.print("Error announcing to tracker: {}\n", .{err});
        return;
    };

    try stdout.print("Announced {d} xorbs to tracker at {s}\n", .{ hash_hexes.items.len, tracker_url.? });
    try stdout.print("Seeding from {s}\n", .{listen_addr});
}

fn downloadRegularFile(
    allocator: std.mem.Allocator,
    _: *const config.Config,
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

    var downloader = cdn.CdnDownloader.init(allocator);
    defer downloader.deinit();

    var result = try downloader.downloadXorb(url);
    defer result.deinit();

    try reconstruct.ensureParentDirs(output_path);
    try storage.writeFileAtomic(output_path, result.data);
}

fn printUsage() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(
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
