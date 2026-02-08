const std = @import("std");

pub const hf_hub_url = "https://huggingface.co";
pub const hf_api_url = "https://huggingface.co/api";
pub const default_revision = "main";
pub const max_xorb_size: usize = 64 * 1024 * 1024; // 64 MiB
pub const default_tracker_port: u16 = 6881;

pub const Config = struct {
    allocator: std.mem.Allocator,
    hf_token: ?[]const u8,
    cache_dir: []const u8,
    hf_cache_dir: []const u8,
    xorb_cache_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator) !Config {
        const home = std.posix.getenv("HOME") orelse "/root";
        const hf_cache_env = std.posix.getenv("HF_HOME");

        const hf_cache_dir = if (hf_cache_env) |env|
            try allocator.dupe(u8, env)
        else
            try std.fmt.allocPrint(allocator, "{s}/.cache/huggingface/hub", .{home});

        const cache_dir = if (std.posix.getenv("ZEST_CACHE_DIR")) |env|
            try allocator.dupe(u8, env)
        else
            try std.fmt.allocPrint(allocator, "{s}/.cache/zest", .{home});

        const xorb_cache_dir = try std.fmt.allocPrint(allocator, "{s}/xorbs", .{cache_dir});

        const hf_token = try readHfToken(allocator, home);

        return .{
            .allocator = allocator,
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
        var sanitized = std.ArrayList(u8).init(self.allocator);
        defer sanitized.deinit();
        for (repo_id) |c| {
            if (c == '/') {
                try sanitized.appendSlice("--");
            } else {
                try sanitized.append(c);
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

fn readHfToken(allocator: std.mem.Allocator, home: []const u8) !?[]const u8 {
    // Try HF_TOKEN env var first
    if (std.posix.getenv("HF_TOKEN")) |env| {
        return try allocator.dupe(u8, env);
    }

    // Try reading from ~/.cache/huggingface/token
    const token_path = try std.fmt.allocPrint(allocator, "{s}/.cache/huggingface/token", .{home});
    defer allocator.free(token_path);

    const file = std.fs.openFileAbsolute(token_path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 4096) catch return null;
    // Trim whitespace
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    if (trimmed.len == content.len) return content;
    defer allocator.free(content);
    return try allocator.dupe(u8, trimmed);
}

test "Config init and deinit" {
    var config = try Config.init(std.testing.allocator);
    defer config.deinit();
    try std.testing.expect(config.cache_dir.len > 0);
    try std.testing.expect(config.hf_cache_dir.len > 0);
    try std.testing.expect(config.xorb_cache_dir.len > 0);
}

test "modelSnapshotDir" {
    var config = try Config.init(std.testing.allocator);
    defer config.deinit();
    const path = try config.modelSnapshotDir("meta-llama/Llama-3.1-8B", "abc123");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "models--meta-llama--Llama-3.1-8B") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "snapshots/abc123") != null);
}

test "xorbCachePath" {
    var config = try Config.init(std.testing.allocator);
    defer config.deinit();
    const path = try config.xorbCachePath("abcdef1234567890");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/ab/abcdef1234567890") != null);
}
