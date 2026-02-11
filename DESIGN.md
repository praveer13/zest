# zest Design Document

**P2P acceleration for ML model distribution. 10x faster downloads. Zero workflow change.**

zest speaks HuggingFace's Xet protocol (via zig-xet) for content addressing and BitTorrent (BEP 3 / BEP 10 / BEP XET) for peer-to-peer transfer. Models download from nearby peers first, fall back to HF's CDN. The result is a `pip install` that makes every `from_pretrained()` call faster — with automatic seeding that solves the free-rider problem by design.

---

## Table of Contents

1. [Vision](#vision)
2. [Architecture Overview](#architecture-overview)
3. [Current State](#current-state)
4. [BEP XET Protocol Compliance](#bep-xet-protocol-compliance)
5. [Python Server Architecture](#python-server-architecture)
6. [UX Design](#ux-design)
7. [Performance Targets](#performance-targets)
8. [Implementation Roadmap](#implementation-roadmap)

---

## Vision

### The Problem

HuggingFace replaced Git LFS with Xet storage in 2025. Xet is excellent: chunk-level deduplication (~64KB CDC chunks), content-addressed xorbs, BLAKE3 Merkle hashing. But it's still **centralized** — every download hits HF's servers via presigned S3 URLs.

When a popular model drops, tens of thousands of researchers download the same immutable xorbs from the same CDN. This is the exact topology BitTorrent was invented to fix.

### The Solution

zest adds a peer swarm on top of Xet's content addressing, using the standard BitTorrent protocol with the BEP XET extension for chunk-level transfer. Two design goals:

1. **10x better performance** — LAN peers serve each other at wire speed. WAN peers saturate links that CDN alone cannot. io_uring-backed async I/O with zero-copy paths.

2. **10x more lovable UX** — `pip install zest` + one line of Python. No CLI tools to learn, no daemons to configure, no seeding to remember. The Python package IS the seeder.

### The Pitch

zest is to Xet what WebTorrent is to HTTP — same content addressing, peers serve each other.

For ML engineers: it's a `pip install` that makes model downloads faster. That's it. No P2P jargon, no configuration, no terminal skills required.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  ML Code (unchanged)                                         │
│  model = AutoModel.from_pretrained("meta-llama/Llama-3.1-8B")│
└───────────────────────┬──────────────────────────────────────┘
                        │  huggingface_hub internally
                        ▼
┌──────────────────────────────────────────────────────────────┐
│  zest Python package                     pip install zest    │
│  Thin HTTP client to localhost:9847                          │
│  Auto-starts Zig server on first call                        │
│  Registers as HF transfer backend                            │
└───────────────────────┬──────────────────────────────────────┘
                        │  localhost:9847 (REST + SSE)
                        ▼
┌──────────────────────────────────────────────────────────────┐
│  zest server (Zig binary, bundled in pip wheel)              │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  REST API                                               │ │
│  │  POST /v1/pull    — download a model (streams progress) │ │
│  │  GET  /v1/status  — peers, bandwidth, models seeded     │ │
│  │  POST /v1/stop    — graceful shutdown                   │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Xet Protocol │  │ BT Protocol  │  │ Transfer Strategy │  │
│  │ (zig-xet)    │  │ BEP 3/10/XET │  │ peers→CDN race    │  │
│  │              │  │              │  │                   │  │
│  │ • Auth       │  │ • Handshake  │  │ • Chunk pipeline  │  │
│  │ • CAS        │  │ • BEP 10 ext │  │ • Multi-peer ||   │  │
│  │ • Chunking   │  │ • XET msgs   │  │ • CDN fallback    │  │
│  │ • Hashing    │  │ • DHT (BEP5) │  │ • io_uring async  │  │
│  │ • Xorb fmt   │  │ • Tracker    │  │ • Zero-alloc hot  │  │
│  └──────────────┘  └──────────────┘  └───────────────────┘  │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  Storage                                                │ │
│  │  HF cache: ~/.cache/huggingface/hub/models--org--name/  │ │
│  │  Xorb cache: ~/.cache/zest/xorbs/{prefix}/{hash}       │ │
│  │  Chunk cache: ~/.cache/zest/chunks/{prefix}/{hash}      │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  Seeds automatically. Always. As long as the server runs.    │
└──────────────────────────────────────────────────────────────┘
```

**Key architectural split:**
- **Xet Protocol Layer** — handled entirely by zig-xet (auth, CAS, chunking, hashing, compression, reconstruction)
- **BitTorrent Protocol Layer** — BEP 3 wire protocol, BEP 10 extensions, BEP XET chunk transfer, BEP 5 DHT
- **Transfer Strategy** — zest's orchestration: which chunks from which source, pipelining, concurrency
- **Python Package** — thin lifecycle manager + HF integration hooks

---

## Current State

### What's Built (v0.3.0)

The Zig core is fully BitTorrent-compliant with 58 tests passing across 13 source files (~3,670 lines):

| Module | Lines | Tests | What it does |
|--------|------:|------:|--------------|
| `dht.zig` | 671 | 11 | Kademlia DHT (BEP 5) — routing table, KRPC messages, UDP transport |
| `main.zig` | 399 | 1 | CLI: pull, seed, bench, version, help |
| `bencode.zig` | 368 | 12 | Bencode encoder/decoder for all BT messages |
| `bep_xet.zig` | 349 | 6 | BEP XET extension — 4 message types on BEP 10 |
| `swarm.zig` | 334 | — | Download orchestrator: cache check → BT P2P → CDN fallback |
| `bench.zig` | 311 | 2 | Synthetic benchmarks with JSON output for CI |
| `bt_wire.zig` | 274 | 8 | BT wire protocol — handshake, message framing, BEP 10 |
| `bt_peer.zig` | 274 | 3 | Full peer lifecycle: connect → handshake → chunk transfer |
| `bt_tracker.zig` | 260 | 5 | Standard BT HTTP tracker (compact peer format) |
| `storage.zig` | 175 | — | File I/O, HF cache layout, xorb/chunk cache |
| `config.zig` | 161 | 3 | Config, HF token, cache paths, DHT bootstrap nodes |
| `peer_id.zig` | 63 | 5 | Azureus-style peer ID + SHA-1 info_hash computation |
| `root.zig` | 31 | 2 | Library re-exports |
| **Total** | **3,670** | **58** | |

### CLI Commands

```bash
zest pull <repo> [--revision <ref>] [--tracker <url>] [--dht-port <port>] [--no-p2p]
zest seed [--tracker <url>] [--dht-port <port>] [--listen <addr>]
zest bench --synthetic [--json]
zest version
zest help
```

### What's Not Built Yet

- REST API server mode (for Python integration)
- Python package (`pip install zest`)
- TCP listener for incoming peer connections (seeding)
- File system watcher for auto-indexing new downloads
- Connection reuse across xorbs
- Chunk pipelining (send N requests before waiting)
- Multi-peer concurrent downloads
- Reciprocity-based peer prioritization

---

## BEP XET Protocol Compliance

zest implements the BEP XET specification as defined at [ccbittorrent.readthedocs.io/en/latest/bep_xet](https://ccbittorrent.readthedocs.io/en/latest/bep_xet/). This ensures interoperability with ccbittorrent and any other BEP XET-compliant client.

### Wire Protocol Stack

```
Layer 4: BEP XET messages (CHUNK_REQUEST, CHUNK_RESPONSE, ...)
Layer 3: BEP 10 extension messages (msg_id=20, ext_id negotiated)
Layer 2: BT wire protocol (4-byte BE length prefix + msg_id + payload)
Layer 1: TCP (via std.Io.net, io_uring on Linux, kqueue on macOS)
```

### Message Types (src/bep_xet.zig)

All messages ride on BEP 10 extended messages (BitTorrent msg_id=20).

#### CHUNK_REQUEST (0x01) — 37 bytes

```
Offset  Size  Field
0       1     XET message type (0x01)
1       4     Request ID (big-endian uint32)
5       32    Chunk hash (BLAKE3-256)
```

#### CHUNK_RESPONSE (0x02) — 9 + N bytes

```
Offset  Size  Field
0       1     XET message type (0x02)
1       4     Request ID (big-endian uint32)
5       4     Data length (big-endian uint32)
9       N     Chunk data (raw bytes, typically ~64KB)
```

#### CHUNK_NOT_FOUND (0x03) — 37 bytes

```
Offset  Size  Field
0       1     XET message type (0x03)
1       4     Request ID (big-endian uint32)
5       32    Chunk hash (BLAKE3-256)
```

#### CHUNK_ERROR (0x04) — 9 + N bytes

```
Offset  Size  Field
0       1     XET message type (0x04)
1       4     Request ID (big-endian uint32)
5       4     Error code (big-endian uint32)
9       N     Error message (UTF-8)
```

### Extension Handshake

During BEP 10 handshake (msg_id=20, ext_id=0), zest sends a bencoded dictionary advertising XET support:

```
{
    "m": {"ut_xet": <our_ext_id>},
    "p": <listen_port>,
    "v": "zest/0.3"
}
```

The peer responds with their own `ut_xet` ext_id. All subsequent XET messages use the peer's advertised ext_id.

### Connection Flow (src/bt_peer.zig)

```
Client                              Peer
  │                                   │
  │──── BT Handshake (68 bytes) ─────►│  Step 1: protocol + info_hash + peer_id
  │◄─── BT Handshake (68 bytes) ──────│  Step 2: verify info_hash match
  │                                   │
  │──── BEP 10 Extended Handshake ───►│  Step 3: advertise ut_xet support
  │──── Unchoke ─────────────────────►│  Step 4: ready to serve
  │──── Interested ──────────────────►│
  │◄─── BEP 10 Extended Handshake ────│  Step 5: learn peer's ut_xet ext_id
  │◄─── Unchoke ──────────────────────│
  │                                   │
  │──── CHUNK_REQUEST ───────────────►│  Step 6: request by BLAKE3 hash
  │◄─── CHUNK_RESPONSE ──────────────│  Step 7: receive data, verify hash
  │                                   │
```

### info_hash Computation (src/peer_id.zig)

Each xorb maps to a BT swarm via a deterministic info_hash:

```
info_hash = SHA-1("zest-xet-v1:" || xorb_hash_32bytes)
```

This gives per-xorb granularity — peers announce which specific xorbs they have, and downloaders find exactly the right peers. Both zest and ccbittorrent must use the same convention.

### Peer Discovery

Two mechanisms, used together:

1. **Kademlia DHT (BEP 5)** — Primary, decentralized. `get_peers(info_hash)` finds peers for a specific xorb. `announce_peer(info_hash, port)` advertises availability. Bootstrap nodes: `router.bittorrent.com:6881`, `dht.transmissionbt.com:6881`.

2. **BT HTTP Tracker (BEP 3)** — Optional, via `--tracker <url>`. Standard `GET /announce?info_hash=...&peer_id=...&port=...&compact=1` with bencoded response.

### Peer ID Format

Azureus-style: `-ZE0300-` + 12 random bytes (20 bytes total).

- `ZE` = zest client identifier
- `03` = version 0.3
- `00` = patch 0

### Chunk Size

zest uses 64KB target chunk size (matching HuggingFace Xet's CDC parameters via zig-xet), not BEP XET's default 16KB. ccbittorrent clients joining HF model swarms must configure `xet_chunk_target_size = 65536` for interoperability.

| Parameter | zest | BEP XET default | Notes |
|-----------|------|-----------------|-------|
| Min chunk | 8 KB | 8 KB | Same |
| Target chunk | 64 KB | 16 KB | zest matches HF Xet |
| Max chunk | 128 KB | 128 KB | Same |
| Hash algorithm | BLAKE3-256 | BLAKE3-256 | Same |
| Chunking algorithm | Gearhash CDC | Gearhash CDC | Same (via zig-xet) |

### Differences from BEP XET Spec

| Aspect | BEP XET spec | zest implementation | Rationale |
|--------|-------------|---------------------|-----------|
| Target chunk size | 16 KB | 64 KB | Match HuggingFace Xet CDC parameters |
| DHT key | `sha1(chunk_hash)` per-chunk | `sha1("zest-xet-v1:" \|\| xorb_hash)` per-xorb | Fewer DHT queries (one per xorb, not per chunk) |
| Dedup cache | SQLite with ref counting | Filesystem-based | Simpler, no SQLite dependency |
| Compression | LZ4 configurable | Via zig-xet (LZ4, ByteGrouping4LZ4, etc.) | Matches HF Xet format |

These are parameterization choices, not protocol incompatibilities. The wire format (message types, byte ordering, BEP 10 framing) is identical.

---

## Python Server Architecture

### Core Insight: The Package IS the Seeder

If seeding requires a separate command (`zest daemon`, `zest seed`), nobody in the ML community will do it. The Python package design makes seeding invisible and automatic:

1. User runs `pip install zest`
2. First `from_pretrained()` call auto-starts the zest server
3. Server downloads model (peers + CDN), files land in normal HF cache
4. **Server keeps running after Python script exits**
5. Server seeds everything in the cache — automatically, silently, always
6. Next ML script finds the server already warm — instant peer connections

There is no separate seeder concept. The server IS the seeder.

### Why Server, Not Subprocess-Per-Download

| | Long-lived server | Per-download subprocess |
|---|---|---|
| Peer connections | Warm, persistent | Cold start every time |
| Seeding | Always, between downloads | Only during download |
| Multiple Python processes | Shared, one server | Each spawns its own |
| Cache indexing | Once on startup | Every invocation |
| Free-rider problem | **Solved** — seeds 24/7 | Not solved — exits after pull |
| DHT presence | Continuous | Ephemeral |

### Server API (localhost:9847)

The Zig binary exposes a minimal REST API on localhost only (not network-accessible):

#### POST /v1/pull

Request:
```json
{"repo": "meta-llama/Llama-3.1-8B", "revision": "main"}
```

Response: Server-Sent Events (SSE) stream for real-time progress:
```
event: file
data: {"path": "model-00001-of-00004.safetensors", "size": 1258291200, "index": 1, "total": 4}

event: progress
data: {"bytes": 52428800, "total": 1258291200, "source": "peer", "peers": 5}

event: progress
data: {"bytes": 104857600, "total": 1258291200, "source": "cdn", "peers": 5}

event: complete
data: {"path": "/home/user/.cache/huggingface/hub/models--meta-llama--Llama-3.1-8B/snapshots/abc123"}
```

SSE enables: progress bars in terminals, Jupyter widget updates, or silent background downloads — the caller decides.

#### GET /v1/status

```json
{
  "version": "0.3.0",
  "uptime_seconds": 86400,
  "peers_connected": 7,
  "models_cached": 3,
  "xorbs_cached": 3655,
  "uploaded_bytes": 25123456789,
  "downloaded_bytes": 4936291200,
  "ratio": 5.1,
  "seeding": [
    {"repo": "meta-llama/Llama-3.1-8B", "xorbs": 12, "peers": 3},
    {"repo": "meta-llama/Llama-3.1-70B", "xorbs": 2187, "peers": 14}
  ]
}
```

#### POST /v1/stop

Graceful shutdown. Server finishes in-flight transfers, closes peer connections, exits.

### Python Package Structure

```
zest/                          # pip install zest
├── __init__.py                # enable(), pull(), status(), stop()
├── client.py                  # HTTP client to localhost:9847
├── server.py                  # Server lifecycle (start, health check, auto-restart)
├── hf_backend.py              # huggingface_hub transfer backend hook
├── jupyter.py                 # %load_ext zest IPython magic
└── bin/
    ├── zest-linux-x86_64      # Zig binary (prebuilt, in platform wheel)
    ├── zest-linux-aarch64
    ├── zest-darwin-x86_64
    └── zest-darwin-aarch64
```

The Python layer is ~300 lines. All real work is the Zig server.

### Integration Tiers

#### Tier 0: Environment variable (zero code changes)

```bash
pip install zest
ZEST=1 python train.py
```

The zest package installs an HF transfer backend hook. When `ZEST=1` is set, `huggingface_hub` routes downloads through the local zest server. The user's `train.py` is completely untouched.

#### Tier 1: One line of Python

```python
import zest
zest.enable()

# Everything below is unchanged
from transformers import AutoModel
model = AutoModel.from_pretrained("meta-llama/Llama-3.1-8B")
```

`zest.enable()` monkey-patches `huggingface_hub.snapshot_download` to route through the local server. Starts the server if it's not running.

#### Tier 2: Explicit pull

```python
import zest

path = zest.pull("meta-llama/Llama-3.1-8B")  # returns cache path
model = AutoModel.from_pretrained(path)
```

#### Tier 3: Jupyter magic

```python
%load_ext zest
# All HF downloads in this notebook now go through zest
```

#### Tier 4: Framework flags

```bash
# vLLM
vllm serve meta-llama/Llama-3.1-8B --download-backend zest

# Environment variable
HF_HUB_DOWNLOAD_BACKEND=zest vllm serve meta-llama/Llama-3.1-8B
```

---

## UX Design

### Design Philosophy

**Make the generous path the easy path.** If the default behavior seeds, most users contribute without thinking about it. No guilt, no punishment, no accounts.

### The Download Experience

```
$ zest pull meta-llama/Llama-3.1-8B

  meta-llama/Llama-3.1-8B                         4.6 GB

  Fetching file list...
  model-00001-of-00004.safetensors  ━━━━━━━━━━━━━━━━━  1.2 GB
    ↓ 847 MB from 5 peers · 353 MB from CDN
  model-00002-of-00004.safetensors  ━━━━━━━━━━━━━╸      68%
    ↓ 612 MB from 3 peers · 201 MB from CDN
  model-00003-of-00004.safetensors  ━━━╸                22%
  model-00004-of-00004.safetensors   waiting

  ↓ 42.3 MB/s from peers  ↑ 8.1 MB/s seeding
  7 peers connected
```

Key details:
- **Seeds while downloading.** If you already have xorbs from a previous model (shared layers, fine-tuned variants), you serve them to peers during your download.
- **Shows peer vs CDN split.** Users see the value P2P provides.
- **After download, lingers briefly seeding:**

```
  ✓ meta-llama/Llama-3.1-8B  4.6 GB in 2m 31s
    ↓ 2.9 GB from peers · 1.7 GB from CDN — 2.4x faster than CDN alone

  Seeding to 4 peers...  ↑ 12.3 MB/s    (Ctrl+C to stop)

  Tip: run `zest start` to keep seeding in the background.
```

- Ctrl+C exits cleanly. No guilt.
- `--exit` flag for CI/Docker (exits immediately after download).

### The Status Dashboard

Running `zest` with no arguments shows a friendly overview:

```
$ zest

  zest v0.3.0                              daemon: running ●

  Models                           Size       Xorbs    Peers
  meta-llama/Llama-3.1-8B         4.6 GB        12      3 ↕
  meta-llama/Llama-3.1-70B       140 GB      2,187     14 ↕
  mistralai/Mixtral-8x7B          93 GB      1,456      8 ↕

  Today          ↓ 4.6 GB received  ↑ 23.4 GB shared
  All time       ↓ 238 GB received  ↑ 1.2 TB shared
  Ratio          5.1x

  7 peers connected right now

  Commands: zest pull <model>    zest start/stop    zest help
```

No P2P jargon. ML engineers see what they have, what's seeding, and their contribution.

### Background Daemon

```bash
$ zest start
  zest daemon started (PID 48291)
  Indexing local cache... found 3 models, 3,655 xorbs (237 GB)
  Seeding to swarm. Run `zest status` to check activity.

$ zest stop
  zest daemon stopped. Uploaded 23.4 GB to 31 peers today.
```

Framed as "make your future downloads faster" — not "please seed for the community."

### First-Run Experience

```
$ zest pull meta-llama/Llama-3.1-8B

  First time using zest! Here's what's happening:
  • Downloads model files using peers + HuggingFace CDN
  • Shares pieces with other downloaders while you wait
  • Files end up in your normal HuggingFace cache

  Your HF token: ✓ found (~/.cache/huggingface/token)

  model-00001-of-00004.safetensors  ━━━━━━━━━━━━━╸  ...
```

One-time, non-intrusive. After that, just progress bars.

### Solving the Free-Rider Problem

Six layers, from most to least subtle:

| Strategy | How it works | User sees |
|----------|-------------|-----------|
| **Seed-while-downloading** | While pulling model A, serve xorbs you already have from model B | `↑ seeding` line in progress |
| **Post-download linger** | `zest pull` stays alive seeding for ~5 min after download | "Seeding to 4 peers... Ctrl+C to stop" |
| **Server persistence** | Python server keeps running between scripts | Nothing — it's invisible |
| **Nudge on exit** | When Ctrl+C, show one-liner | "Tip: zest start keeps seeding" |
| **Reciprocity priority** | Peers who seed get served first by other seeders | Invisible — just faster downloads |
| **Ratio visibility** | Show upload/download ratio in status | "Ratio: 5.1x" — social motivation |

What we don't do:
- No throttling or punishment for non-seeders (CDN fallback is always there)
- No accounts or reputation systems
- No guilt-tripping

### Lab Adoption Dynamics

1. One researcher installs zest. Downloads are fast.
2. They tell their labmate. Now two machines seed to each other over LAN.
3. Third person installs. The entire lab is a local CDN.
4. Every subsequent model download is nearly instant over LAN.

This is the WebTorrent/Popcorn Time growth dynamic: the product is better with more users, and each user makes it better for others automatically.

---

## Performance Targets

### 10x Performance Goal

| Scenario | CDN-only (baseline) | zest target | Speedup |
|----------|-------------------|-------------|---------|
| Single user, cold cache | 5 min (Llama-3.1-8B) | 5 min (CDN fallback) | 1x |
| Single user, warm LAN peer | 5 min | 30 sec (10 Gbps LAN) | 10x |
| Lab with 5 warm peers | 5 min | 15 sec (parallel LAN) | 20x |
| Popular model, 100 WAN peers | 5 min | 1 min (distributed) | 5x |
| Re-download (local cache hit) | 5 min | <1 sec | >300x |

The 10x target is realistic for the common case: labs and clusters where multiple people download the same models.

### Zig Performance Advantages

These are specific to the Zig implementation and would be difficult to replicate in Python or even Rust without significant effort.

#### 1. io_uring-backed concurrent chunk downloads

Zig 0.16's `std.Io` provides native async I/O (io_uring on Linux, kqueue on macOS). Download chunks from N peers concurrently without threads:

```zig
// Submit CHUNK_REQUESTs to multiple peers simultaneously
// io_uring's submission queue handles multiplexing
// No tokio/asyncio runtime — std.Io IS the event loop
var wg: std.Io.WaitGroup = .{};
for (peers) |*peer| {
    wg.start();
    io.async(downloadFromPeer, .{peer, chunks, &wg});
}
wg.wait(io);
```

A single zest process can saturate 100Gbps with io_uring. No extra event loop library needed.

#### 2. Zero-allocation hot paths

Pre-allocate everything on the download hot path:

- **Chunk buffers**: Pool of 64KB buffers, reused across downloads
- **Connection buffers**: 16KB read/write buffers stack-allocated in BtPeer
- **BT messages**: All fixed-size messages (handshake, keepalive, CHUNK_REQUEST) constructed on stack
- **Hash computation**: BLAKE3 state is 1.8KB — stack-allocated, no heap

#### 3. Pipelined chunk requests

Send multiple CHUNK_REQUESTs before waiting for any response:

```zig
// Pipeline: send all requests first
for (chunk_hashes) |hash| {
    try peer.sendChunkRequest(hash);  // queued in io_uring
}
// Collect responses as they arrive (matched by request_id)
for (chunk_hashes) |_| {
    const response = try peer.receiveChunkResponse();
}
```

Each CHUNK_REQUEST is 37 bytes. Each CHUNK_RESPONSE is ~64KB. Pipelining keeps the TCP pipe full.

#### 4. Static binary, instant startup

~7MB static binary, no runtime dependencies. `zest pull` starts downloading immediately — no VM warmup, no dependency resolution. Compare to `pip install hf_transfer` which pulls in Python + Rust + OpenSSL.

#### 5. Comptime wire protocol construction

BT message headers are computed at compile time:

```zig
pub fn writeChunkRequest(writer: *Io.Writer, comptime ext_id: u8, ...) !void {
    const header = comptime blk: {
        var h: [6]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], 43, .big);
        h[4] = 20; // extended
        h[5] = ext_id;
        break :blk h;
    };
    try writer.writeAll(&header);
}
```

### Current Benchmark Results

From `zest bench --synthetic --json` (ReleaseFast, measured with Io.Clock):

| Benchmark | Runs | Median (ns) | Throughput |
|-----------|-----:|------------:|-----------:|
| bencode_encode | 10,000 | 185 | 206 MB/s |
| bencode_decode | 10,000 | 117 | 324 MB/s |
| blake3_64kb | 1,000 | 17,768 | 3,517 MB/s |
| sha1_info_hash | 10,000 | 55 | 755 MB/s |
| bt_wire_frame | 10,000 | 5 | 11,943 MB/s |

BLAKE3 at 3.5 GB/s means hash verification is never the bottleneck — even 100Gbps networking is slower than our hashing.

---

## Implementation Roadmap

### Phase 1: BT-Compliant P2P Core (DONE)

Full BitTorrent protocol stack:
- [x] Bencode encoder/decoder
- [x] BT wire protocol (BEP 3 handshake + message framing)
- [x] BEP 10 extension protocol
- [x] BEP XET extension (4 message types)
- [x] BT peer lifecycle (connect → handshake → chunk transfer)
- [x] Kademlia DHT (BEP 5) for peer discovery
- [x] BT HTTP tracker client
- [x] Synthetic benchmarks with JSON output
- [x] CI benchmark job
- [x] 58 tests passing

### Phase 2: Server Mode + Connection Infrastructure

Add REST API server to the Zig binary so Python can drive it:

- [ ] HTTP server on localhost:9847 (using std.http.Server)
- [ ] `POST /v1/pull` with SSE progress streaming
- [ ] `GET /v1/status` endpoint
- [ ] `POST /v1/stop` graceful shutdown
- [ ] TCP listener for incoming BT peer connections (seeding)
- [ ] Connection pool — reuse BtPeer connections across xorbs
- [ ] Auto-index HF cache on startup (scan for cached xorbs)
- [ ] `zest serve` command (foreground server mode)
- [ ] `zest start` / `zest stop` (background daemon with PID file)

### Phase 3: Transfer Optimizations

The performance-critical layer:

- [ ] Chunk request pipelining (send N requests before waiting)
- [ ] Multi-peer concurrent downloads (different chunks from different peers)
- [ ] io_uring batch submission for peer I/O
- [ ] Chunk buffer pool (pre-allocated 64KB buffers)
- [ ] Reciprocity-based peer prioritization (seeders get served first)
- [ ] Seed-while-downloading (serve cached xorbs during pull)
- [ ] Post-download linger (stay alive ~5 min seeding after pull completes)
- [ ] Integration benchmarks (loopback P2P transfer, LAN 2-node test)

### Phase 4: Python Package

The user-facing integration layer:

- [ ] `pip install zest` — platform wheels with prebuilt Zig binaries
- [ ] `zest.enable()` — monkey-patch huggingface_hub
- [ ] `zest.pull()` — explicit download API
- [ ] `ZEST=1` env var — zero-code integration
- [ ] Server auto-start on first call
- [ ] Server auto-restart on crash
- [ ] Progress callbacks for Jupyter / tqdm
- [ ] `%load_ext zest` Jupyter magic

### Phase 5: Polish + Ecosystem

- [ ] `zest` (no args) status dashboard
- [ ] First-run welcome message
- [ ] Upload/download ratio tracking
- [ ] Bandwidth limiting (`--max-upload`, `--max-download`)
- [ ] Selective seeding (seed only specific models)
- [ ] vLLM integration PR
- [ ] Ollama integration PR
- [ ] llama.cpp integration PR
- [ ] Documentation site

---

## Key References

- **BEP XET Specification**: [ccbittorrent.readthedocs.io/en/latest/bep_xet](https://ccbittorrent.readthedocs.io/en/latest/bep_xet/)
- **zig-xet** (Zig Xet implementation): [github.com/jedisct1/zig-xet](https://github.com/jedisct1/zig-xet)
- **Xet Protocol Spec**: [huggingface.co/docs/xet/index](https://huggingface.co/docs/xet/index)
- **xet-core** (Rust reference): [github.com/huggingface/xet-core](https://github.com/huggingface/xet-core)
- **BEP 3** (BitTorrent Protocol): [bittorrent.org/beps/bep_0003.html](https://www.bittorrent.org/beps/bep_0003.html)
- **BEP 5** (DHT Protocol): [bittorrent.org/beps/bep_0005.html](https://www.bittorrent.org/beps/bep_0005.html)
- **BEP 10** (Extension Protocol): [bittorrent.org/beps/bep_0010.html](https://www.bittorrent.org/beps/bep_0010.html)
- **Frank Denis blog**: [XET intro part 1](https://00f.net/2026/01/19/xet-intro-1/), [part 2](https://00f.net/2026/01/19/xet-intro-2/)

---

## License

MIT
