/// Benchmarking framework for zest.
///
/// Synthetic benchmarks measure raw throughput of individual components:
///   - Bencode encode/decode
///   - BLAKE3 hashing
///   - BT wire message framing
///   - SHA-1 info_hash computation
///
/// Results can be output as human-readable text or JSON for CI.
const std = @import("std");
const Io = std.Io;
const bencode = @import("bencode.zig");
const bt_wire = @import("bt_wire.zig");
const peer_id_mod = @import("peer_id.zig");
const Blake3 = std.crypto.hash.Blake3;

pub const BenchResult = struct {
    name: []const u8,
    runs: u32,
    total_ns: u64,
    bytes_processed: u64,

    pub fn medianNs(self: *const BenchResult) u64 {
        if (self.runs == 0) return 0;
        return self.total_ns / self.runs;
    }

    pub fn throughputMbps(self: *const BenchResult) f64 {
        if (self.total_ns == 0) return 0;
        const bytes_f: f64 = @floatFromInt(self.bytes_processed);
        const ns_f: f64 = @floatFromInt(self.total_ns);
        return (bytes_f / (1024.0 * 1024.0)) / (ns_f / 1_000_000_000.0);
    }
};

/// Get current monotonic time in nanoseconds via Io.Clock.
fn nowNs(io: Io) u64 {
    const ts = Io.Clock.awake.now(io);
    // nanoseconds is i96, convert to u64 (always positive for monotonic clock)
    const ns: i96 = ts.nanoseconds;
    if (ns < 0) return 0;
    return @intCast(@min(ns, std.math.maxInt(u64)));
}

/// Run all synthetic benchmarks.
pub fn runSynthetic(allocator: std.mem.Allocator, writer: *Io.Writer, json: bool) !void {
    // We need Io for timing — use std.testing.io for testing context,
    // but when called from main, io is available via the init parameter.
    // For now, benchmarks report iteration counts without precise timing
    // when Io is not available.
    var results: std.ArrayList(BenchResult) = .empty;
    defer results.deinit(allocator);

    try results.append(allocator, benchBencodeEncode(allocator));
    try results.append(allocator, benchBencodeDecode(allocator));
    try results.append(allocator, benchBlake3Hash());
    try results.append(allocator, benchSha1InfoHash());
    try results.append(allocator, benchBtWireFraming());

    if (json) {
        try writeJson(allocator, writer, results.items);
    } else {
        try writeText(writer, results.items);
    }
}

fn benchBencodeEncode(allocator: std.mem.Allocator) BenchResult {
    const runs: u32 = 10000;
    var total_bytes: u64 = 0;

    for (0..runs) |_| {
        // Build a dict similar to a BEP 10 handshake
        const inner = allocator.alloc(bencode.DictEntry, 1) catch continue;
        defer allocator.free(inner);
        inner[0] = .{ .key = "ut_xet", .value = .{ .integer = 1 } };

        const outer = allocator.alloc(bencode.DictEntry, 3) catch continue;
        defer allocator.free(outer);
        outer[0] = .{ .key = "m", .value = .{ .dict = inner } };
        outer[1] = .{ .key = "p", .value = .{ .integer = 6881 } };
        outer[2] = .{ .key = "v", .value = .{ .string = "zest/0.3" } };

        const encoded = bencode.encode(allocator, .{ .dict = outer }) catch continue;
        total_bytes += encoded.len;
        allocator.free(encoded);
    }

    return .{ .name = "bencode_encode", .runs = runs, .total_ns = 0, .bytes_processed = total_bytes };
}

fn benchBencodeDecode(allocator: std.mem.Allocator) BenchResult {
    const runs: u32 = 10000;
    const input = "d1:md6:ut_xeti1ee1:pi6881e1:v8:zest/0.3e";
    const total_bytes: u64 = @as(u64, input.len) * runs;

    for (0..runs) |_| {
        const val = bencode.decode(allocator, input) catch continue;
        bencode.deinit(allocator, val);
    }

    return .{ .name = "bencode_decode", .runs = runs, .total_ns = 0, .bytes_processed = total_bytes };
}

fn benchBlake3Hash() BenchResult {
    const runs: u32 = 1000;
    const chunk_size: usize = 65536; // 64KB — typical Xet chunk
    var data: [chunk_size]u8 = undefined;
    @memset(&data, 0x42);
    const total_bytes: u64 = @as(u64, chunk_size) * runs;

    for (0..runs) |_| {
        var hash: [32]u8 = undefined;
        Blake3.hash(&data, &hash, .{});
        std.mem.doNotOptimizeAway(&hash);
    }

    return .{ .name = "blake3_64kb", .runs = runs, .total_ns = 0, .bytes_processed = total_bytes };
}

fn benchSha1InfoHash() BenchResult {
    const runs: u32 = 10000;
    const xorb_hash = [_]u8{0xAB} ** 32;
    const total_bytes: u64 = @as(u64, 44) * runs; // "zest-xet-v1:" (12) + hash (32)

    for (0..runs) |_| {
        const result = peer_id_mod.computeInfoHash(xorb_hash);
        std.mem.doNotOptimizeAway(&result);
    }

    return .{ .name = "sha1_info_hash", .runs = runs, .total_ns = 0, .bytes_processed = total_bytes };
}

fn benchBtWireFraming() BenchResult {
    const runs: u32 = 10000;
    var total_bytes: u64 = 0;
    const payload = [_]u8{0x42} ** 64; // Small payload

    for (0..runs) |_| {
        var buf: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&buf);

        bt_wire.writeMessage(&writer, .interested, &payload) catch continue;
        total_bytes += writer.buffered().len;
    }

    return .{ .name = "bt_wire_frame", .runs = runs, .total_ns = 0, .bytes_processed = total_bytes };
}

/// Run benchmarks with Io for precise timing.
pub fn runSyntheticWithIo(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, json: bool) !void {
    var results: std.ArrayList(BenchResult) = .empty;
    defer results.deinit(allocator);

    try results.append(allocator, benchBencodeEncodeIo(allocator, io));
    try results.append(allocator, benchBencodeDecodeIo(allocator, io));
    try results.append(allocator, benchBlake3HashIo(io));
    try results.append(allocator, benchSha1InfoHashIo(io));
    try results.append(allocator, benchBtWireFramingIo(io));

    if (json) {
        try writeJson(allocator, writer, results.items);
    } else {
        try writeText(writer, results.items);
    }
}

fn benchBencodeEncodeIo(allocator: std.mem.Allocator, io: Io) BenchResult {
    const runs: u32 = 10000;
    var total_bytes: u64 = 0;
    const start = nowNs(io);

    for (0..runs) |_| {
        const inner = allocator.alloc(bencode.DictEntry, 1) catch continue;
        defer allocator.free(inner);
        inner[0] = .{ .key = "ut_xet", .value = .{ .integer = 1 } };

        const outer = allocator.alloc(bencode.DictEntry, 3) catch continue;
        defer allocator.free(outer);
        outer[0] = .{ .key = "m", .value = .{ .dict = inner } };
        outer[1] = .{ .key = "p", .value = .{ .integer = 6881 } };
        outer[2] = .{ .key = "v", .value = .{ .string = "zest/0.3" } };

        const encoded = bencode.encode(allocator, .{ .dict = outer }) catch continue;
        total_bytes += encoded.len;
        allocator.free(encoded);
    }

    const elapsed = nowNs(io) -| start;
    return .{ .name = "bencode_encode", .runs = runs, .total_ns = elapsed, .bytes_processed = total_bytes };
}

fn benchBencodeDecodeIo(allocator: std.mem.Allocator, io: Io) BenchResult {
    const runs: u32 = 10000;
    const input = "d1:md6:ut_xeti1ee1:pi6881e1:v8:zest/0.3e";
    const total_bytes: u64 = @as(u64, input.len) * runs;
    const start = nowNs(io);

    for (0..runs) |_| {
        const val = bencode.decode(allocator, input) catch continue;
        bencode.deinit(allocator, val);
    }

    const elapsed = nowNs(io) -| start;
    return .{ .name = "bencode_decode", .runs = runs, .total_ns = elapsed, .bytes_processed = total_bytes };
}

fn benchBlake3HashIo(io: Io) BenchResult {
    const runs: u32 = 1000;
    const chunk_size: usize = 65536;
    var data: [chunk_size]u8 = undefined;
    @memset(&data, 0x42);
    const total_bytes: u64 = @as(u64, chunk_size) * runs;
    const start = nowNs(io);

    for (0..runs) |_| {
        var hash: [32]u8 = undefined;
        Blake3.hash(&data, &hash, .{});
        std.mem.doNotOptimizeAway(&hash);
    }

    const elapsed = nowNs(io) -| start;
    return .{ .name = "blake3_64kb", .runs = runs, .total_ns = elapsed, .bytes_processed = total_bytes };
}

fn benchSha1InfoHashIo(io: Io) BenchResult {
    const runs: u32 = 10000;
    const xorb_hash = [_]u8{0xAB} ** 32;
    const total_bytes: u64 = @as(u64, 44) * runs;
    const start = nowNs(io);

    for (0..runs) |_| {
        const result = peer_id_mod.computeInfoHash(xorb_hash);
        std.mem.doNotOptimizeAway(&result);
    }

    const elapsed = nowNs(io) -| start;
    return .{ .name = "sha1_info_hash", .runs = runs, .total_ns = elapsed, .bytes_processed = total_bytes };
}

fn benchBtWireFramingIo(io: Io) BenchResult {
    const runs: u32 = 10000;
    var total_bytes: u64 = 0;
    const payload = [_]u8{0x42} ** 64;
    const start = nowNs(io);

    for (0..runs) |_| {
        var buf: [256]u8 = undefined;
        var writer: Io.Writer = .fixed(&buf);
        bt_wire.writeMessage(&writer, .interested, &payload) catch continue;
        total_bytes += writer.buffered().len;
    }

    const elapsed = nowNs(io) -| start;
    return .{ .name = "bt_wire_frame", .runs = runs, .total_ns = elapsed, .bytes_processed = total_bytes };
}

fn writeText(writer: *Io.Writer, results: []const BenchResult) !void {
    try writer.print("\nzest benchmark results\n", .{});
    try writer.print("{s:>20} {s:>10} {s:>12} {s:>12}\n", .{ "Name", "Runs", "Median (ns)", "MB/s" });
    try writer.print("{s:->20} {s:->10} {s:->12} {s:->12}\n", .{ "", "", "", "" });

    for (results) |r| {
        try writer.print("{s:>20} {d:>10} {d:>12} {d:>12.1}\n", .{
            r.name,
            r.runs,
            r.medianNs(),
            r.throughputMbps(),
        });
    }
    try writer.print("\n", .{});
}

fn writeJson(allocator: std.mem.Allocator, writer: *Io.Writer, results: []const BenchResult) !void {
    _ = allocator;
    try writer.print("{{\"results\":[", .{});
    for (results, 0..) |r, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("{{\"name\":\"{s}\",\"runs\":{d},\"median_ns\":{d},\"throughput_mbps\":{d:.1},\"bytes_processed\":{d}}}", .{
            r.name,
            r.runs,
            r.medianNs(),
            r.throughputMbps(),
            r.bytes_processed,
        });
    }
    try writer.print("]}}\n", .{});
}

// ── Tests ──

test "BenchResult calculations" {
    const r = BenchResult{
        .name = "test",
        .runs = 100,
        .total_ns = 1_000_000, // 1ms total
        .bytes_processed = 1024 * 1024, // 1 MB
    };

    try std.testing.expectEqual(@as(u64, 10000), r.medianNs()); // 10us per run
    try std.testing.expect(r.throughputMbps() > 900.0); // ~1000 MB/s
}

test "synthetic benchmarks run without error" {
    const alloc = std.testing.allocator;
    // Just verify they don't crash
    _ = benchBencodeEncode(alloc);
    _ = benchBencodeDecode(alloc);
    _ = benchBlake3Hash();
    _ = benchSha1InfoHash();
    _ = benchBtWireFraming();
}
