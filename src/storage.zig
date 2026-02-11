/// Storage layer: file I/O, pre-allocation, and cache management.
///
/// For Linux, this will use io_uring for async I/O in future phases.
/// For the MVP, we use standard synchronous file I/O.
const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");

/// Ensure a directory and all its parent directories exist.
pub fn ensureDirRecursive(io: Io, path: []const u8) !void {
    // Walk the path and create each directory component
    var i: usize = 1; // skip leading /
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            Io.Dir.createDirAbsolute(io, path[0..i], .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
    // Create the final directory
    Io.Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Write data to a file, creating parent directories as needed.
pub fn writeFileAtomic(io: Io, path: []const u8, data: []const u8) !void {
    // Ensure parent dir exists
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try ensureDirRecursive(io, path[0..sep]);
    }

    const file = try Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    fw.interface.writeAll(data) catch return error.WriteFailed;
    fw.interface.flush() catch return error.WriteFailed;
}

/// Pre-allocate a file to a given size (hint for the filesystem).
pub fn preallocateFile(io: Io, path: []const u8, size: u64) !Io.File {
    _ = size;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try ensureDirRecursive(io, path[0..sep]);
    }

    const file = try Io.Dir.createFileAbsolute(io, path, .{});
    // Pre-allocation not directly supported in new API; just return the file
    return file;
}

/// Write a symlink for the HF cache refs directory.
/// refs/main → commit SHA, so `from_pretrained("org/model")` resolves correctly.
pub fn writeRef(allocator: std.mem.Allocator, cfg: *const config.Config, repo_id: []const u8, ref_name: []const u8, commit_sha: []const u8) !void {
    const io = cfg.io;
    // Build refs path: ~/.cache/huggingface/hub/models--org--name/refs/main
    var sanitized: std.ArrayList(u8) = .empty;
    defer sanitized.deinit(allocator);
    for (repo_id) |c| {
        if (c == '/') {
            try sanitized.appendSlice(allocator, "--");
        } else {
            try sanitized.append(allocator, c);
        }
    }

    const refs_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/models--{s}/refs",
        .{ cfg.hf_cache_dir, sanitized.items },
    );
    defer allocator.free(refs_dir);
    try ensureDirRecursive(io, refs_dir);

    const ref_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ refs_dir, ref_name },
    );
    defer allocator.free(ref_path);

    try writeFileAtomic(io, ref_path, commit_sha);
}

// ── Chunk cache ──

/// Convert a 32-byte hash to 64-char hex string.
pub fn hashToHex(hash: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [64]u8 = undefined;
    for (0..32) |i| {
        result[i * 2] = hex_chars[hash[i] >> 4];
        result[i * 2 + 1] = hex_chars[hash[i] & 0x0F];
    }
    return result;
}

/// Write a chunk to the local cache by its BLAKE3 hash.
pub fn writeChunk(io: Io, cfg_ptr: *const config.Config, chunk_hash: [32]u8, data: []const u8) !void {
    const hex = hashToHex(chunk_hash);
    const path = try cfg_ptr.chunkCachePath(&hex);
    defer cfg_ptr.allocator.free(path);
    writeFileAtomic(io, path, data) catch {};
}

/// Read a chunk from the local cache. Returns null if not found.
pub fn readChunk(allocator: std.mem.Allocator, io: Io, cfg_ptr: *const config.Config, chunk_hash: [32]u8) !?[]u8 {
    const hex = hashToHex(chunk_hash);
    const path = try cfg_ptr.chunkCachePath(&hex);
    defer allocator.free(path);

    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    const data = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(data);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const bytes_read = reader.interface.readSliceShort(data) catch {
        allocator.free(data);
        return null;
    };
    if (bytes_read != stat.size) {
        allocator.free(data);
        return null;
    }

    return data;
}

/// Check if a chunk exists in the local cache.
pub fn hasChunk(io: Io, cfg_ptr: *const config.Config, chunk_hash: [32]u8) bool {
    const hex = hashToHex(chunk_hash);
    const path = cfg_ptr.chunkCachePath(&hex) catch return false;
    defer cfg_ptr.allocator.free(path);
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

// ── Xorb Registry ──

/// In-memory index of cached xorbs for fast seeding lookups.
pub const XorbRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) XorbRegistry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(void).init(allocator),
        };
    }

    /// Scan the xorb cache directory and populate the registry.
    pub fn scan(self: *XorbRegistry, cfg: *const config.Config) !void {
        const cached = try listCachedXorbs(self.allocator, cfg);
        defer {
            for (cached) |h| self.allocator.free(h);
            self.allocator.free(cached);
        }

        for (cached) |h| {
            const duped = try self.allocator.dupe(u8, h);
            self.entries.put(duped, {}) catch {
                self.allocator.free(duped);
            };
        }
    }

    pub fn has(self: *const XorbRegistry, hash_hex: []const u8) bool {
        return self.entries.contains(hash_hex);
    }

    pub fn add(self: *XorbRegistry, hash_hex: []const u8) !void {
        if (self.entries.contains(hash_hex)) return;
        const duped = try self.allocator.dupe(u8, hash_hex);
        try self.entries.put(duped, {});
    }

    pub fn count(self: *const XorbRegistry) u32 {
        return self.entries.count();
    }

    pub fn deinit(self: *XorbRegistry) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.entries.deinit();
    }
};

/// List all xorb hashes in the local cache (for seeding).
pub fn listCachedXorbs(allocator: std.mem.Allocator, cfg: *const config.Config) ![][]const u8 {
    const io = cfg.io;
    var hashes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (hashes.items) |h| allocator.free(h);
        hashes.deinit(allocator);
    }

    var dir = Io.Dir.openDirAbsolute(io, cfg.xorb_cache_dir, .{ .iterate = true }) catch return try hashes.toOwnedSlice(allocator);
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        // Each subdirectory is a 2-char prefix
        var subdir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer subdir.close(io);

        var sub_it = subdir.iterate();
        while (try sub_it.next(io)) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (file_entry.name.len == 64) {
                try hashes.append(allocator, try allocator.dupe(u8, file_entry.name));
            }
        }
    }

    return try hashes.toOwnedSlice(allocator);
}
