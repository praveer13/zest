/// Merkle hash computation compatible with xet-core.
///
/// xet-core uses BLAKE3 with domain-separation keys:
///   - DATA_KEY: for hashing leaf/chunk data
///   - INTERNAL_NODE_HASH: for combining child hashes in the Merkle tree
///
/// A MerkleHash is 32 bytes (256 bits), stored as [4]u64 in xet-core
/// but we use [32]u8 for simplicity.
const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;

/// 32-byte hash used throughout Xet for content addressing.
pub const MerkleHash = [32]u8;

pub const zero_hash: MerkleHash = [_]u8{0} ** 32;

/// BLAKE3 key for hashing leaf/chunk data (from xet-core merklehash/src/data_hash.rs).
pub const DATA_KEY: [32]u8 = .{
    102, 151, 245, 119, 91,  149, 80, 222, 49,  53,  203, 172, 165, 151, 24,  28,
    157, 228, 33,  16,  155, 235, 43, 88,  180, 208, 176, 75,  147, 173, 242, 41,
};

/// BLAKE3 key for combining internal tree nodes (from xet-core merklehash/src/data_hash.rs).
pub const INTERNAL_NODE_KEY: [32]u8 = .{
    1,  126, 197, 199, 165, 71,  41,  150, 253, 148, 102, 102, 180, 138, 2,   230,
    93, 221, 83,  111, 55,  199, 109, 210, 248, 99,  82,  230, 74,  83,  113, 63,
};

/// Compute the hash of a data chunk using the DATA_KEY domain separator.
pub fn hashChunkData(data: []const u8) MerkleHash {
    var hasher = Blake3.init(.{ .key = DATA_KEY });
    hasher.update(data);
    var result: MerkleHash = undefined;
    hasher.final(&result);
    return result;
}

/// Combine two child hashes into a parent hash using INTERNAL_NODE_KEY.
pub fn hashInternal(left: MerkleHash, right: MerkleHash) MerkleHash {
    var hasher = Blake3.init(.{ .key = INTERNAL_NODE_KEY });
    hasher.update(&left);
    hasher.update(&right);
    var result: MerkleHash = undefined;
    hasher.final(&result);
    return result;
}

/// Compute the Merkle tree root hash over a list of chunk hashes.
/// This builds a balanced binary Merkle tree, combining pairs bottom-up.
/// For a single hash, returns it as-is.
/// For empty input, returns zero_hash.
pub fn merkleRoot(chunk_hashes: []const MerkleHash) MerkleHash {
    if (chunk_hashes.len == 0) return zero_hash;
    if (chunk_hashes.len == 1) return chunk_hashes[0];

    // Work bottom-up: copy hashes, combine pairs repeatedly
    var buf: [1024]MerkleHash = undefined;
    var current: []MerkleHash = undefined;

    if (chunk_hashes.len <= buf.len) {
        @memcpy(buf[0..chunk_hashes.len], chunk_hashes);
        current = buf[0..chunk_hashes.len];
    } else {
        // For very large sets, fall back to recursive approach
        const mid = chunk_hashes.len / 2;
        const left = merkleRoot(chunk_hashes[0..mid]);
        const right = merkleRoot(chunk_hashes[mid..]);
        return hashInternal(left, right);
    }

    while (current.len > 1) {
        var next_len: usize = 0;
        var i: usize = 0;
        while (i + 1 < current.len) : (i += 2) {
            current[next_len] = hashInternal(current[i], current[i + 1]);
            next_len += 1;
        }
        // If odd number, carry the last one forward
        if (i < current.len) {
            current[next_len] = current[i];
            next_len += 1;
        }
        current = current[0..next_len];
    }

    return current[0];
}

/// Format a MerkleHash as a lowercase hex string.
pub fn toHex(hash: MerkleHash) [64]u8 {
    return std.fmt.bytesToHex(hash, .lower);
}

/// Parse a 64-char hex string into a MerkleHash.
pub fn fromHex(hex: []const u8) !MerkleHash {
    if (hex.len != 64) return error.InvalidHashLength;
    var result: MerkleHash = undefined;
    for (0..32) |i| {
        result[i] = std.fmt.parseUnsigned(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidHexChar;
    }
    return result;
}

test "hashChunkData produces 32 bytes" {
    const hash = hashChunkData("hello world");
    try std.testing.expectEqual(@as(usize, 32), hash.len);
    // Should not be zero
    try std.testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "hashChunkData is deterministic" {
    const h1 = hashChunkData("test data");
    const h2 = hashChunkData("test data");
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "hashChunkData differs for different data" {
    const h1 = hashChunkData("data1");
    const h2 = hashChunkData("data2");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "hashInternal combines hashes" {
    const h1 = hashChunkData("chunk1");
    const h2 = hashChunkData("chunk2");
    const parent = hashInternal(h1, h2);
    try std.testing.expect(!std.mem.eql(u8, &parent, &h1));
    try std.testing.expect(!std.mem.eql(u8, &parent, &h2));
}

test "merkleRoot single element" {
    const h1 = hashChunkData("only one");
    const root = merkleRoot(&[_]MerkleHash{h1});
    try std.testing.expectEqualSlices(u8, &h1, &root);
}

test "merkleRoot two elements" {
    const h1 = hashChunkData("a");
    const h2 = hashChunkData("b");
    const root = merkleRoot(&[_]MerkleHash{ h1, h2 });
    const expected = hashInternal(h1, h2);
    try std.testing.expectEqualSlices(u8, &expected, &root);
}

test "toHex and fromHex roundtrip" {
    const hash = hashChunkData("roundtrip test");
    const hex = toHex(hash);
    const parsed = try fromHex(&hex);
    try std.testing.expectEqualSlices(u8, &hash, &parsed);
}
