# Contributing to zest

This guide explains zest's architecture, how the code fits together, and how to contribute effectively.

## Quick Start

```bash
# Prerequisites: Zig 0.16.0+ (https://ziglang.org/download/)
git clone https://github.com/praveer13/zest.git
cd zest

# Build
zig build

# Run tests (72 tests across 18 modules)
zig build test --summary all

# Check formatting
zig fmt --check src/

# Build release binary (~9 MB static)
zig build -Doptimize=ReleaseFast
```

## Architecture Overview

zest has three layers, each building on the one below:

```
┌───────────────────────────────────────────────┐
│  CLI + Python API                             │
│  main.zig, http_api.zig, python/              │
├───────────────────────────────────────────────┤
│  Transfer Pipeline                            │
│  xet_bridge.zig → parallel_download.zig       │
│  swarm.zig → peer_pool.zig → bt_peer.zig      │
│  server.zig (seeding)                         │
├───────────────────────────────────────────────┤
│  Protocol Layer                               │
│  bt_wire.zig, bep_xet.zig, bencode.zig        │
│  dht.zig, bt_tracker.zig, peer_id.zig         │
├───────────────────────────────────────────────┤
│  zig-xet (external dependency)                │
│  CAS, chunking, hashing, xorb format          │
└───────────────────────────────────────────────┘
```

**zig-xet** handles the Xet protocol (HuggingFace's content-addressing system). zest's unique contribution is the P2P layer on top.

## Reading the Code: Where to Start

### If you want to understand the download flow

Start here and follow the calls:

1. **`main.zig:cmdPull()`** — Entry point for `zest pull`. Sets up config, auth, and the download pipeline.
2. **`xet_bridge.zig:fetchXorbForTerm()`** — The core waterfall: cache check → P2P attempt → CDN fallback. This is where P2P meets Xet.
3. **`parallel_download.zig:reconstructToFile()`** — Wraps the bridge with concurrent Io.Group-based fetching.
4. **`swarm.zig:tryBtPeerDownload()`** — P2P download logic: discover peers (cached, TTL-gated), try each sequentially.

### If you want to understand the BitTorrent protocol

Read in this order:

1. **`bt_wire.zig`** — BEP 3 wire protocol: 68-byte handshake, length-prefixed messages, BEP 10 extension framing.
2. **`bep_xet.zig`** — BEP XET extension: 4 message types (CHUNK_REQUEST, CHUNK_RESPONSE, CHUNK_NOT_FOUND, CHUNK_ERROR).
3. **`bencode.zig`** — Bencode encoder/decoder used in BEP 10 extended handshakes and DHT.
4. **`dht.zig`** — Kademlia DHT (BEP 5) for decentralized peer discovery.

### If you want to understand peer connections

1. **`bt_peer.zig`** — Full peer lifecycle: TCP connect → BT handshake → BEP 10 → chunk request/response. Per-peer mutex serializes TCP access.
2. **`peer_pool.zig`** — Connection pool: reuses BT connections across xorb downloads. Double-checked locking pattern (connect outside lock).
3. **`server.zig`** — Seeding: accepts incoming BT connections, serves chunks from xorb cache.

### If you want to understand storage

1. **`config.zig`** — Cache paths, HF token resolution, peer ID generation.
2. **`storage.zig`** — File I/O, HF cache layout, xorb/chunk cache, XorbRegistry for seeding.
3. **`swarm.zig:XorbCache`** — Simple read/write cache for xorb blobs.

## Design Principles

### Never slower than CDN-only

The worst case for any zest download should be identical to downloading directly from HuggingFace. P2P is additive — if no peers exist or all fail, we fall back to CDN. Every P2P operation has a timeout or error path that degrades to CDN.

### Content-addressed, self-verifying

Xorbs are identified by BLAKE3 Merkle hash. Peers can't serve corrupted data — the hash is verified after download. This means P2P requires zero trust between peers.

### Graceful degradation everywhere

Every function that talks to a peer, DHT, or tracker handles errors by falling through to the next option:
- Peer connection fails → try next peer
- All peers fail → CDN fallback
- DHT unavailable → try BT tracker → try direct peers
- Concurrency unavailable → synchronous fallback

### Zig 0.16 I/O model

All I/O goes through `std.Io`, passed as a parameter from `main()`. This enables io_uring on Linux. Key patterns:

- Functions that do I/O take `io: Io` as a parameter
- Concurrent work uses `Io.Group` (not threads directly)
- Thread safety via `Io.Mutex` (not `std.Thread.Mutex`)
- Network via `Io.net` (not `std.net`)

## Key Data Types

| Type | File | Purpose |
|------|------|---------|
| `SwarmDownloader` | swarm.zig | Orchestrates P2P + CDN downloads, tracks stats |
| `XetBridge` | xet_bridge.zig | Connects zig-xet CAS to P2P swarm |
| `BtPeer` | bt_peer.zig | Single BT peer connection + state |
| `PeerPool` | peer_pool.zig | Connection pool (address → BtPeer) |
| `BtServer` | server.zig | Accepts incoming BT connections for seeding |
| `ParallelDownloader` | parallel_download.zig | Concurrent xorb fetching via Io.Group |
| `XorbCache` | swarm.zig | Disk cache for xorb blobs |
| `Config` | config.zig | Runtime configuration (paths, tokens, ports) |

## Thread Safety Model

zest uses fine-grained locking, not a global mutex:

- **`BtPeer.mutex`** — Per-peer. Serializes all TCP read/write on one connection. Held for the duration of `requestChunk()`.
- **`PeerPool.mutex`** — Per-pool. Protects the connections hashmap only. Held briefly for lookup/insert. Connect + handshake runs *outside* this lock (double-checked locking).
- **`SwarmDownloader.discovery_mutex`** — Protects cached peer discovery state. Held during DHT/tracker queries.

Rule: never hold two mutexes at the same time.

## Common Pitfalls

### Hash encoding mismatch

`xet.hashing.hashToHex` and `storage.hashToHex` produce **different output** for the same 32-byte hash. zig-xet reads 8-byte groups as little-endian u64, then formats hex. storage.zig does byte-by-byte. **Always use `xet.hashing.hashToHex` when dealing with xorb cache keys.**

### Io.Group deadlocks

- `group.await()` waits for ALL tasks — no cancellation.
- Don't nest Io.Groups where inner tasks block on I/O indefinitely.
- Always handle `error.ConcurrencyUnavailable` with a synchronous fallback.

### Merkle BLAKE3

Xorb hashes use Merkle BLAKE3 (branching factor 4, domain-separation keys), not simple `BLAKE3(bytes)`. You cannot verify an xorb hash by hashing the raw data. zig-xet handles verification internally.

### Blocking reads on TCP

Never speculatively read from a TCP stream expecting data that may not arrive. This causes deadlocks where both sides wait for each other. Only read when you know a response is expected.

## Testing

```bash
# All tests
zig build test --summary all

# Format check
zig fmt --check src/

# P2P integration test (requires Hetzner Cloud + HF tokens)
# Provisions 3 nodes, runs CDN baseline vs P2P download, tears down
export HCLOUD_TOKEN=... HF_TOKEN=...
./test/hetzner/p2p-test.sh all
```

Every module has unit tests. The test pattern is:
- Test struct initialization and default values
- Test serialization round-trips (encode → decode → compare)
- Test error paths (auth required, invalid input)
- Integration tests require real network (marked by needing tokens)

## Pull Request Guidelines

1. **Run tests**: `zig build test --summary all` must pass with all 72 tests
2. **Run formatter**: `zig fmt src/` (enforced by CI)
3. **Keep changes focused**: one logical change per PR
4. **Test P2P changes on real nodes**: use `test/hetzner/p2p-test.sh` for anything touching the transfer pipeline
5. **Error handling**: return errors, never panic. Always provide a fallback path.
6. **No trust assumptions**: peers can send anything. Verify all data via content hashes.

## File Reference

| File | Lines | Tests | What it does |
|------|------:|------:|-------------|
| `main.zig` | 805 | 1 | CLI entry point, command dispatch |
| `root.zig` | 36 | — | Library re-exports |
| `config.zig` | 183 | 2 | Configuration and paths |
| `bencode.zig` | 368 | 12 | Bencode encoder/decoder |
| `peer_id.zig` | 63 | 5 | Peer ID and info_hash |
| `bt_wire.zig` | 274 | 8 | BT wire protocol framing |
| `bep_xet.zig` | 349 | 6 | BEP XET extension messages |
| `bt_peer.zig` | 338 | 3 | Peer connection lifecycle |
| `peer_pool.zig` | 132 | 2 | Connection pooling |
| `dht.zig` | 671 | 11 | Kademlia DHT |
| `bt_tracker.zig` | 260 | 5 | BT HTTP tracker |
| `xet_bridge.zig` | 300 | 2 | CAS ↔ P2P bridge |
| `parallel_download.zig` | 230 | 2 | Concurrent fetching |
| `swarm.zig` | 441 | — | Download orchestrator |
| `storage.zig` | 228 | — | File I/O and cache |
| `server.zig` | 255 | 3 | BT TCP listener |
| `http_api.zig` | 375 | — | HTTP REST API |
| `bench.zig` | 311 | 2 | Benchmarks |

**Total: 18 files, ~5,644 lines, 72 tests.**
