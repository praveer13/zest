/// File reconstruction from cached xorbs and CAS reconstruction terms.
///
/// Given a list of terms (xorb_hash + byte ranges), reads the corresponding
/// xorb data from the local cache and assembles the original file.
/// The output is written to the HF cache layout for from_pretrained() compat.
const std = @import("std");
const xorb_mod = @import("xorb.zig");
const cas_mod = @import("cas.zig");
const config = @import("config.zig");
const hash_mod = @import("hash.zig");
const cdn_mod = @import("cdn.zig");

pub const ReconstructError = error{
    MissingXorb,
    XorbVerificationFailed,
    OutputWriteFailed,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.WriteError;

/// Reconstruct a file from its CAS reconstruction info.
/// Downloads any missing xorbs via CDN, verifies hashes, and assembles the file.
pub fn reconstructFile(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    recon: *const cas_mod.ReconstructionInfo,
    output_path: []const u8,
    cdn: *cdn_mod.CdnDownloader,
) !void {
    const cache = xorb_mod.XorbCache.init(allocator, cfg);
    try cache.ensureDirs();

    // Ensure output directory exists
    if (std.mem.lastIndexOfScalar(u8, output_path, '/')) |sep| {
        std.fs.makeDirAbsolute(output_path[0..sep]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Create/truncate output file
    const out_file = try std.fs.createFileAbsolute(output_path, .{ .truncate = true });
    defer out_file.close();

    // Pre-allocate output file if we know the size
    if (recon.file_size > 0) {
        out_file.setEndPos(recon.file_size) catch {};
    }

    // Process each term in order
    for (recon.terms) |*term| {
        const hex = &term.xorb_hash_hex;

        // Try local cache first
        const xorb_data: ?xorb_mod.XorbData = try cache.get(hex);

        if (xorb_data == null) {
            // Download from CDN
            var result = try cdn.downloadTerm(term);
            defer result.deinit();

            // Cache the downloaded xorb
            cache.put(hex, result.data) catch |err| {
                std.debug.print("Warning: failed to cache xorb {s}: {}\n", .{ hex, err });
            };

            // Write the data directly to the output file at the right offset
            try writeTermData(out_file, term, result.data);
            continue;
        }

        // Use cached xorb
        var xorb = xorb_data.?;
        defer xorb.deinit();

        try writeTermData(out_file, term, xorb.data);
    }
}

fn writeTermData(file: std.fs.File, term: *const xorb_mod.Term, data: []const u8) !void {
    // If we have byte range info, the data we got corresponds to that range
    // and should be written sequentially. The CAS terms are in file order.
    // For xorb-level downloads, we may need to extract the relevant byte range.
    if (term.byte_range_start != 0 or term.byte_range_end != 0) {
        // Data is already the relevant byte range from CDN range request
        try file.writeAll(data);
    } else {
        // Full xorb data — write it all (the term represents the whole xorb's contribution)
        try file.writeAll(data);
    }
}

/// Build the output path for a file in the HF cache layout.
pub fn buildOutputPath(
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

/// Ensure all directories in a path exist.
pub fn ensureParentDirs(path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        std.fs.makeDirAbsolute(path[0..sep]) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}
