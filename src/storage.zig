/// Storage layer: file I/O, pre-allocation, and cache management.
///
/// For Linux, this will use io_uring for async I/O in future phases.
/// For the MVP, we use standard synchronous file I/O.
const std = @import("std");
const config = @import("config.zig");

/// Ensure a directory and all its parent directories exist.
pub fn ensureDirRecursive(path: []const u8) !void {
    // Walk the path and create each directory component
    var i: usize = 1; // skip leading /
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            std.fs.makeDirAbsolute(path[0..i]) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
    // Create the final directory
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Write data to a file, creating parent directories as needed.
pub fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    // Ensure parent dir exists
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try ensureDirRecursive(path[0..sep]);
    }

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

/// Pre-allocate a file to a given size (hint for the filesystem).
pub fn preallocateFile(path: []const u8, size: u64) !std.fs.File {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try ensureDirRecursive(path[0..sep]);
    }

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    file.setEndPos(size) catch {}; // Best effort pre-allocation
    return file;
}

/// Write a symlink for the HF cache refs directory.
/// refs/main → commit SHA, so `from_pretrained("org/model")` resolves correctly.
pub fn writeRef(allocator: std.mem.Allocator, cfg: *const config.Config, repo_id: []const u8, ref_name: []const u8, commit_sha: []const u8) !void {
    // Build refs path: ~/.cache/huggingface/hub/models--org--name/refs/main
    var sanitized = std.ArrayList(u8).init(allocator);
    defer sanitized.deinit();
    for (repo_id) |c| {
        if (c == '/') {
            try sanitized.appendSlice("--");
        } else {
            try sanitized.append(c);
        }
    }

    const refs_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/models--{s}/refs",
        .{ cfg.hf_cache_dir, sanitized.items },
    );
    defer allocator.free(refs_dir);
    try ensureDirRecursive(refs_dir);

    const ref_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ refs_dir, ref_name },
    );
    defer allocator.free(ref_path);

    try writeFileAtomic(ref_path, commit_sha);
}

/// List all xorb hashes in the local cache (for seeding).
pub fn listCachedXorbs(allocator: std.mem.Allocator, cfg: *const config.Config) ![][]const u8 {
    var hashes = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (hashes.items) |h| allocator.free(h);
        hashes.deinit();
    }

    var dir = std.fs.openDirAbsolute(cfg.xorb_cache_dir, .{ .iterate = true }) catch return try hashes.toOwnedSlice();

    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Each subdirectory is a 2-char prefix
        var subdir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var sub_it = subdir.iterate();
        while (try sub_it.next()) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (file_entry.name.len == 64) {
                try hashes.append(try allocator.dupe(u8, file_entry.name));
            }
        }
    }

    return try hashes.toOwnedSlice();
}
