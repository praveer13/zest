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
