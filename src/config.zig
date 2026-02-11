const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;

pub const hf_hub_url = "https://huggingface.co";
pub const default_revision = "main";
pub const default_tracker_port: u16 = 6881;

pub const Config = struct {
    allocator: std.mem.Allocator,
    io: Io,
    hf_token: ?[]const u8,
    cache_dir: []const u8,
    hf_cache_dir: []const u8,
    xorb_cache_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, environ: Environ) !Config {
        const home = environ.getPosix("HOME") orelse "/root";
        const hf_cache_env = environ.getPosix("HF_HOME");

        const hf_cache_dir = if (hf_cache_env) |env|
            try allocator.dupe(u8, env)
        else
            try std.fmt.allocPrint(allocator, "{s}/.cache/huggingface/hub", .{home});

        const cache_dir = if (environ.getPosix("ZEST_CACHE_DIR")) |env|
            try allocator.dupe(u8, env)
        else
            try std.fmt.allocPrint(allocator, "{s}/.cache/zest", .{home});

        const xorb_cache_dir = try std.fmt.allocPrint(allocator, "{s}/xorbs", .{cache_dir});

        const hf_token = try readHfToken(allocator, io, environ, home);

        return .{
            .allocator = allocator,
            .io = io,
            .hf_token = hf_token,
            .cache_dir = cache_dir,
            .hf_cache_dir = hf_cache_dir,
            .xorb_cache_dir = xorb_cache_dir,
        };
    }

    pub fn deinit(self: *Config) void {
        if (self.hf_token) |token| self.allocator.free(token);
        self.allocator.free(self.xorb_cache_dir);
        self.allocator.free(self.cache_dir);
        self.allocator.free(self.hf_cache_dir);
    }

    /// Build the HF cache path for a model snapshot:
    /// ~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{commit}/
    pub fn modelSnapshotDir(self: *const Config, repo_id: []const u8, commit: []const u8) ![]u8 {
        // Replace '/' with '--' in repo_id
        var sanitized: std.ArrayList(u8) = .empty;
        defer sanitized.deinit(self.allocator);
        for (repo_id) |c| {
            if (c == '/') {
                try sanitized.appendSlice(self.allocator, "--");
            } else {
                try sanitized.append(self.allocator, c);
            }
        }
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/models--{s}/snapshots/{s}",
            .{ self.hf_cache_dir, sanitized.items, commit },
        );
    }

    /// Build the xorb cache path: ~/.cache/zest/xorbs/{prefix}/{hash}
    pub fn xorbCachePath(self: *const Config, hash_hex: []const u8) ![]u8 {
        if (hash_hex.len < 4) return error.InvalidHash;
        return std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}",
            .{ self.xorb_cache_dir, hash_hex[0..2], hash_hex },
        );
    }
};

fn readHfToken(allocator: std.mem.Allocator, io: Io, environ: Environ, home: []const u8) !?[]const u8 {
    // Try HF_TOKEN env var first
    if (environ.getPosix("HF_TOKEN")) |env| {
        return try allocator.dupe(u8, env);
    }

    // Try reading from ~/.cache/huggingface/token
    const token_path = try std.fmt.allocPrint(allocator, "{s}/.cache/huggingface/token", .{home});
    defer allocator.free(token_path);

    const file = Io.Dir.openFileAbsolute(io, token_path, .{}) catch return null;
    defer file.close(io);

    // Read token file (max 4096 bytes)
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(&buf) catch return null;
    const content = buf[0..n];

    // Trim whitespace
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    return try allocator.dupe(u8, trimmed);
}

test "Config init and deinit" {
    var cfg = try Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();
    try std.testing.expect(cfg.cache_dir.len > 0);
    try std.testing.expect(cfg.hf_cache_dir.len > 0);
    try std.testing.expect(cfg.xorb_cache_dir.len > 0);
}

test "modelSnapshotDir" {
    var cfg = try Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();
    const path = try cfg.modelSnapshotDir("meta-llama/Llama-3.1-8B", "abc123");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "models--meta-llama--Llama-3.1-8B") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "snapshots/abc123") != null);
}

test "xorbCachePath" {
    var cfg = try Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();
    const path = try cfg.xorbCachePath("abcdef1234567890");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/ab/abcdef1234567890") != null);
}
