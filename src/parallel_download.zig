/// Parallel xorb fetcher using Io.Group for concurrent downloads.
///
/// Fetches multiple xorbs concurrently via XetBridge (cache → P2P → CDN),
/// then writes chunks to the output file in the correct term order.
/// Each concurrent task delegates to bridge.fetchXorbForTerm which handles
/// P2P vs CDN racing (Phase 4) per xorb.
const std = @import("std");
const Io = std.Io;
const xet = @import("xet");
const config = @import("config.zig");
const storage = @import("storage.zig");
const xet_bridge_mod = @import("xet_bridge.zig");

const cas_client = xet.cas_client;
const xorb_mod = xet.xorb;

/// Result of processing a single term (extracted chunk data, ready to write).
const TermResult = struct {
    data: []u8,
    index: usize,
    allocator: std.mem.Allocator,

    fn deinit(self: *TermResult) void {
        self.allocator.free(self.data);
    }
};

/// Context for a single concurrent fetch task.
const FetchContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bridge: *xet_bridge_mod.XetBridge,
    term: cas_client.ReconstructionTerm,
    fetch_info_map: std.StringHashMap([]cas_client.FetchInfo),
    index: usize,
    results: []?TermResult,
    mutex: *Io.Mutex,
    error_occurred: *std.atomic.Value(bool),
    first_error: *?anyerror,
    error_mutex: *Io.Mutex,
};

/// Process a single term — called concurrently via Io.Group.
fn fetchTermTask(ctx: *FetchContext) void {
    if (ctx.error_occurred.load(.acquire)) return;

    const result = fetchTermInner(ctx) catch |err| {
        ctx.error_mutex.lockUncancelable(ctx.io);
        defer ctx.error_mutex.unlock(ctx.io);
        if (ctx.first_error.* == null) ctx.first_error.* = err;
        ctx.error_occurred.store(true, .release);
        return;
    };

    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);
    ctx.results[ctx.index] = result;
}

fn fetchTermInner(ctx: *FetchContext) !TermResult {
    // Delegate to bridge: cache → race(P2P, CDN) → fallback
    const result = try ctx.bridge.fetchXorbForTerm(ctx.term, ctx.fetch_info_map);
    defer ctx.allocator.free(result.data);

    var reader = xorb_mod.XorbReader.init(ctx.allocator, result.data);
    const chunk_data = try reader.extractChunkRange(result.local_start, result.local_end);
    return .{ .data = chunk_data, .index = ctx.index, .allocator = ctx.allocator };
}

pub const ParallelDownloader = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bridge: *xet_bridge_mod.XetBridge,
    max_concurrent: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        bridge: *xet_bridge_mod.XetBridge,
        max_concurrent: u32,
    ) ParallelDownloader {
        return .{
            .allocator = allocator,
            .io = io,
            .bridge = bridge,
            .max_concurrent = max_concurrent,
        };
    }

    /// Reconstruct a file with parallel xorb fetching.
    pub fn reconstructToFile(
        self: *ParallelDownloader,
        file_hash_hex: []const u8,
        output_path: []const u8,
    ) !void {
        // Ensure parent directory exists
        if (std.mem.lastIndexOfScalar(u8, output_path, '/')) |sep| {
            try storage.ensureDirRecursive(self.io, output_path[0..sep]);
        }

        // Get reconstruction info from CAS
        var recon = try self.bridge.getReconstruction(file_hash_hex);
        defer recon.deinit();

        if (recon.terms.len == 0) return;

        // Open output file
        const file = try Io.Dir.createFileAbsolute(self.io, output_path, .{});
        defer file.close(self.io);
        var file_buf: [8192]u8 = undefined;
        var fw = file.writer(self.io, &file_buf);

        // Process terms in batches — each task uses bridge (cache → P2P → CDN)
        var batch_start: usize = 0;
        while (batch_start < recon.terms.len) {
            const batch_end = @min(batch_start + self.max_concurrent, recon.terms.len);
            const batch_size = batch_end - batch_start;

            try self.processBatch(
                recon.terms[batch_start..batch_end],
                recon.fetch_info,
                batch_size,
                &fw.interface,
            );

            batch_start = batch_end;
        }

        fw.interface.flush() catch return error.WriteFailed;
    }

    fn processBatch(
        self: *ParallelDownloader,
        terms: []cas_client.ReconstructionTerm,
        fetch_info_map: std.StringHashMap([]cas_client.FetchInfo),
        batch_size: usize,
        writer: *Io.Writer,
    ) !void {
        // Allocate results and contexts
        const results = try self.allocator.alloc(?TermResult, batch_size);
        defer self.allocator.free(results);
        @memset(results, null);

        const contexts = try self.allocator.alloc(FetchContext, batch_size);
        defer self.allocator.free(contexts);

        var mutex: Io.Mutex = Io.Mutex.init;
        var error_occurred = std.atomic.Value(bool).init(false);
        var first_error: ?anyerror = null;
        var error_mutex: Io.Mutex = Io.Mutex.init;

        // Build contexts
        for (terms, 0..) |term, i| {
            contexts[i] = .{
                .allocator = self.allocator,
                .io = self.io,
                .bridge = self.bridge,
                .term = term,
                .fetch_info_map = fetch_info_map,
                .index = i,
                .results = results,
                .mutex = &mutex,
                .error_occurred = &error_occurred,
                .first_error = &first_error,
                .error_mutex = &error_mutex,
            };
        }

        // Launch concurrent fetches
        var group: Io.Group = Io.Group.init;

        for (contexts) |*ctx| {
            group.concurrent(self.io, fetchTermTask, .{ctx}) catch |err| {
                switch (err) {
                    error.ConcurrencyUnavailable => fetchTermTask(ctx),
                }
            };
        }

        group.await(self.io) catch unreachable;

        // Check for errors
        if (error_occurred.load(.acquire)) {
            // Clean up any successful results
            for (results) |*opt| {
                if (opt.*) |*r| r.deinit();
            }
            return first_error orelse error.UnknownFetchError;
        }

        // Write results in order
        for (results) |*opt| {
            if (opt.*) |*r| {
                defer r.deinit();
                writer.writeAll(r.data) catch return error.WriteFailed;
            } else {
                return error.MissingResult;
            }
        }
    }
};

// ── Tests ──

test "ParallelDownloader init" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    var bridge = xet_bridge_mod.XetBridge.init(std.testing.allocator, std.testing.io, &cfg, null);
    defer bridge.deinit();

    var dl = ParallelDownloader.init(std.testing.allocator, std.testing.io, &bridge, 16);
    try std.testing.expectEqual(@as(u32, 16), dl.max_concurrent);
}

test "ParallelDownloader reconstructToFile requires auth" {
    var cfg = try config.Config.init(std.testing.allocator, std.testing.io, std.testing.environ);
    defer cfg.deinit();

    var bridge = xet_bridge_mod.XetBridge.init(std.testing.allocator, std.testing.io, &cfg, null);
    defer bridge.deinit();

    var dl = ParallelDownloader.init(std.testing.allocator, std.testing.io, &bridge, 16);
    const result = dl.reconstructToFile("0" ** 64, "/tmp/test-output");
    try std.testing.expectError(error.NotAuthenticated, result);
}
