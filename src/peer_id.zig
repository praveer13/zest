/// BT peer ID generation and info_hash computation.
///
/// Peer IDs follow the Azureus-style convention: "-ZE0200-" + 12 random bytes.
/// info_hash maps xorb hashes to BT swarm identifiers:
///   info_hash = SHA-1("zest-xet-v1:" || xorb_hash_32bytes)
const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;

/// Azureus-style client prefix: ZE = zest, 02 = v0.2, 00 = patch 0
pub const CLIENT_PREFIX = "-ZE0200-";

/// Generate a 20-byte BT peer ID: 8-byte prefix + 12 random bytes.
pub fn generate(io: std.Io) [20]u8 {
    var id: [20]u8 = undefined;
    @memcpy(id[0..8], CLIENT_PREFIX);
    io.random(id[8..20]);
    return id;
}

/// Domain separation prefix for info_hash derivation.
const INFO_HASH_PREFIX = "zest-xet-v1:";

/// Compute the BT info_hash for a given xorb hash.
/// info_hash = SHA-1("zest-xet-v1:" || xorb_hash)
///
/// This maps each xorb to a unique BT swarm. Both zest and
/// ccbittorrent clients must agree on this convention.
pub fn computeInfoHash(xorb_hash: [32]u8) [20]u8 {
    var hasher = Sha1.init(.{});
    hasher.update(INFO_HASH_PREFIX);
    hasher.update(&xorb_hash);
    return hasher.finalResult();
}

test "peer ID has correct prefix" {
    const id = generate(std.testing.io);
    try std.testing.expectEqualSlices(u8, CLIENT_PREFIX, id[0..8]);
}

test "peer ID random bytes differ" {
    const id1 = generate(std.testing.io);
    const id2 = generate(std.testing.io);
    // Random portions should differ (vanishingly unlikely to match)
    try std.testing.expect(!std.mem.eql(u8, id1[8..20], id2[8..20]));
}

test "info_hash is deterministic" {
    const xorb_hash = [_]u8{0xAB} ** 32;
    const h1 = computeInfoHash(xorb_hash);
    const h2 = computeInfoHash(xorb_hash);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "different xorb hashes produce different info_hashes" {
    const h1 = computeInfoHash([_]u8{0x00} ** 32);
    const h2 = computeInfoHash([_]u8{0xFF} ** 32);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "info_hash is 20 bytes" {
    const h = computeInfoHash([_]u8{0x42} ** 32);
    try std.testing.expectEqual(@as(usize, 20), h.len);
}
