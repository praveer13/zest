/// Xorb types, hash verification, and local cache management.
///
/// A xorb (eXtensible Object Repository Block) is a container of chunks, up to 64 MiB.
/// Each xorb is identified by its MerkleHash. The local cache stores downloaded xorbs
/// at ~/.cache/zest/xorbs/{hash_prefix}/{hash_hex} for seeding and reuse.
const std = @import("std");
const hash = @import("hash.zig");
const config = @import("config.zig");

pub const MerkleHash = hash.MerkleHash;

/// Represents a reference to a range of chunks within a xorb, used to reconstruct a file.
pub const Term = struct {
    xorb_hash: MerkleHash,
    xorb_hash_hex: [64]u8,
    chunk_range_start: u32,
    chunk_range_end: u32,
    byte_range_start: u64,
    byte_range_end: u64,
    url: ?[]const u8,
};

/// A downloaded xorb with its raw data.
pub const XorbData = struct {
    hash_val: MerkleHash,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *XorbData) void {
        self.allocator.free(self.data);
    }

    /// Verify the xorb data matches the expected hash.
    pub fn verify(self: *const XorbData) bool {
        const computed = hash.hashChunkData(self.data);
        return std.mem.eql(u8, &computed, &self.hash_val);
    }
};

/// Xorb local cache: stores xorbs by hash for reuse and seeding.
pub const XorbCache = struct {
    cfg: *const config.Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) XorbCache {
        return .{ .cfg = cfg, .allocator = allocator };
    }

    /// Check if a xorb is already in the local cache.
    pub fn has(self: *const XorbCache, hash_hex: []const u8) bool {
        const cache_path = self.cfg.xorbCachePath(hash_hex) catch return false;
        defer self.allocator.free(cache_path);
        std.fs.accessAbsolute(cache_path, .{}) catch return false;
        return true;
    }

    /// Read a cached xorb from disk.
    pub fn get(self: *const XorbCache, hash_hex: []const u8) !?XorbData {
        const cache_path = try self.cfg.xorbCachePath(hash_hex);
        defer self.allocator.free(cache_path);

        const file = std.fs.openFileAbsolute(cache_path, .{}) catch return null;
        defer file.close();

        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);

        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            self.allocator.free(data);
            return null;
        }

        const hash_val = try hash.fromHex(hash_hex);

        return .{
            .hash_val = hash_val,
            .data = data,
            .allocator = self.allocator,
        };
    }

    /// Write a xorb to the local cache.
    pub fn put(self: *const XorbCache, hash_hex: []const u8, data: []const u8) !void {
        const cache_path = try self.cfg.xorbCachePath(hash_hex);
        defer self.allocator.free(cache_path);

        // Ensure parent directory exists
        if (std.mem.lastIndexOfScalar(u8, cache_path, '/')) |sep| {
            std.fs.makeDirAbsolute(cache_path[0..sep]) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = try std.fs.createFileAbsolute(cache_path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    /// Ensure the xorb cache directory structure exists.
    pub fn ensureDirs(self: *const XorbCache) !void {
        std.fs.makeDirAbsolute(self.cfg.cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        std.fs.makeDirAbsolute(self.cfg.xorb_cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};

test "Term struct has expected fields" {
    const term = Term{
        .xorb_hash = hash.zero_hash,
        .xorb_hash_hex = [_]u8{'0'} ** 64,
        .chunk_range_start = 0,
        .chunk_range_end = 10,
        .byte_range_start = 0,
        .byte_range_end = 65536,
        .url = null,
    };
    try std.testing.expectEqual(@as(u32, 10), term.chunk_range_end);
}

test "XorbData verify" {
    const data = try std.testing.allocator.dupe(u8, "test xorb content");
    const expected_hash = hash.hashChunkData(data);
    var xorb = XorbData{
        .hash_val = expected_hash,
        .data = data,
        .allocator = std.testing.allocator,
    };
    defer xorb.deinit();
    try std.testing.expect(xorb.verify());
}
