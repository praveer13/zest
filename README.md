# zest

**P2P acceleration for ML model distribution.**

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-72%20passing-brightgreen)](#testing)
[![License](https://img.shields.io/badge/license-MIT-blue)](#license)
[![Lines of Code](https://img.shields.io/badge/lines-5%2C644-informational)](#project-structure)

zest speaks HuggingFace's [Xet protocol](https://huggingface.co/docs/xet/index) (via [zig-xet](https://github.com/jedisct1/zig-xet)) for content addressing and [BitTorrent](https://www.bittorrent.org/beps/bep_0003.html) (BEP 3 / BEP 10 / [BEP XET](https://ccbittorrent.readthedocs.io/en/latest/bep_xet/)) for peer-to-peer transfer. Models download from nearby peers first, fall back to HF's CDN.

```bash
zest pull meta-llama/Llama-3.1-70B
# pulls chunks from peers via BitTorrent, falls back to HF CDN
# drop-in compatible with existing HuggingFace cache layout
```

After pulling, `transformers.AutoModel.from_pretrained("meta-llama/Llama-3.1-70B")` just works — zero workflow change.

## Why

HuggingFace replaced Git LFS with [Xet storage](https://huggingface.co/blog/xet-on-the-hub) in 2025. Xet is excellent: chunk-level deduplication (~64KB CDC chunks), content-addressed xorbs, Merkle hashing, efficient incremental uploads. But it's still **centralized** — every download hits HF's servers via presigned S3 URLs.

When a popular model drops, tens of thousands of people download the same immutable xorbs from the same CDN. This is the exact topology BitTorrent was invented to fix.

**zest is to Xet what WebTorrent is to HTTP** — same content addressing, peers serve each other.

## Installation

```bash
pip install zest-transfer
# or
uv pip install zest-transfer
```

This installs the `zest` CLI and the Python library. No Zig toolchain needed.

### Authentication

zest needs a HuggingFace token to download models. Set it up once:

```bash
# option 1: environment variable
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxx

# option 2: huggingface-cli (token saved to ~/.cache/huggingface/token)
pip install huggingface_hub
huggingface-cli login
```

Get your token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).

### Python API

```python
import zest

zest.enable()   # monkey-patches huggingface_hub for P2P downloads
zest.pull("meta-llama/Llama-3.1-8B")  # download via P2P + CDN
zest.status()   # server stats
zest.stop()     # stop the server

# or auto-enable via env var:
# ZEST=1 python your_script.py
```

### From source (for contributors)

Requires [Zig 0.16.0+](https://ziglang.org/download/).

```bash
git clone https://github.com/praveer13/zest.git
cd zest
zig build -Doptimize=ReleaseFast
# binary at ./zig-out/bin/zest (~9 MB static binary)
```

## Usage

### Pull a model

```bash
# basic pull (CDN + DHT peer discovery)
zest pull meta-llama/Llama-3.1-8B

# specific revision
zest pull Qwen/Qwen2-7B --revision v1.0

# direct peer connection (no tracker/DHT needed)
zest pull gpt2 --peer 10.0.0.5:6881

# with BT tracker for peer discovery
zest pull meta-llama/Llama-3.1-8B --tracker http://tracker.example.com:6881

# CDN-only (disable P2P)
zest pull meta-llama/Llama-3.1-8B --no-p2p
```

### Server mode

```bash
# run server in foreground (BT listener on :6881, HTTP API on :9847)
zest serve

# custom ports
zest serve --http-port 8080 --listen-port 7000

# start/stop as background service
zest start
zest stop
```

The HTTP API provides:

- `GET /v1/health` — health check
- `GET /v1/status` — JSON stats (peers, chunks served, xorbs cached)
- `POST /v1/pull` — trigger model download
- `POST /v1/stop` — graceful shutdown

### Seed your downloads

```bash
# announce cached xorbs via BT protocol so peers can fetch from you
zest seed --tracker http://tracker.example.com:6881
```

### Benchmarks

```bash
# synthetic benchmarks (bencode, BLAKE3, wire framing)
zest bench --synthetic

# JSON output for CI
zest bench --synthetic --json
```

### Other commands

```bash
zest version    # print version
zest help       # show usage
```

## Testing P2P Between Two Servers

This is the quickest way to verify end-to-end P2P transfer works.

### 1. Install on both servers

```bash
# on each server:
pip install zest-transfer
```

### 2. Server A: download and seed

```bash
# download a small model from HF (CDN)
zest pull gpt2

# start seeding (BT listener on :6881, HTTP API on :9847)
zest serve
```

### 3. Server B: download from Server A via P2P

```bash
# --peer tells zest to try Server A directly
zest pull gpt2 --peer <server-a-ip>:6881
```

The output will show download stats including how much came from peers vs CDN.

### Python workflow

Same test, but from Python:

```python
# server_a.py
import zest
zest.pull("gpt2")  # downloads from CDN, auto-starts server, seeds

# server_b.py — once Server A is running
import subprocess
subprocess.run(["zest", "pull", "gpt2", "--peer", "<server-a-ip>:6881"])
```

Or with the programmatic API:

```python
# server A
import zest
zest.pull("gpt2")

# check status
print(zest.status())
# {"version": "0.3.1", "bt_peers": 0, "chunks_served": 0, "xorbs_cached": 12, ...}
```

### Verify P2P is working

On Server B, check the download stats output:

```
Download stats:
  From peers:      12     ← chunks came from Server A
  From CDN:        0      ← nothing from HF servers
  P2P ratio:       100.0%
```

On Server A, check the HTTP API:

```bash
curl http://localhost:9847/v1/status
# {"version":"0.3.0","bt_peers":1,"chunks_served":12,...}
```

## How It Works

```
┌──────────────────────────────────────────────────────────┐
│  zest pull org/model                                     │
├──────────────────────────────────────────────────────────┤
│  1. zig-xet: list files, detect Xet-backed files         │
│  2. For each xorb:                                       │
│     ✓ Check local cache (~/.cache/zest/xorbs/)           │
│     ✓ Try direct peers (--peer flag)                     │
│     ✓ DHT get_peers(info_hash) + BT tracker announce     │
│     ✓ BT handshake → BEP 10 → BEP XET CHUNK_REQUEST     │
│     ✓ Download chunks from peers (P2P)                   │
│     ✓ Fall back to CDN (presigned S3 URL) if needed      │
│     ✓ Verify BLAKE3 hash on every chunk                  │
│     ✓ Cache locally for future seeding                   │
├──────────────────────────────────────────────────────────┤
│  Reconstruct files → write to HF cache layout            │
│  → transformers.from_pretrained() just works             │
└──────────────────────────────────────────────────────────┘
```

### BitTorrent Protocol Compliance

zest implements the standard BitTorrent wire protocol with the [BEP XET extension](https://ccbittorrent.readthedocs.io/en/latest/bep_xet/) for chunk-level transfer:

- **BEP 3** — Wire protocol (68-byte handshake, length-prefixed messages)
- **BEP 5** — Kademlia DHT for decentralized peer discovery
- **BEP 10** — Extension protocol (negotiates ut_xet support)
- **BEP XET** — CHUNK_REQUEST / CHUNK_RESPONSE / CHUNK_NOT_FOUND / CHUNK_ERROR

This means zest peers can interoperate with any BEP XET-compliant client, including [ccbittorrent](https://ccbittorrent.readthedocs.io/).

### Key Design Decisions

- **Uses [zig-xet](https://github.com/jedisct1/zig-xet) for Xet protocol** — production-quality implementation by Frank Denis (creator of libsodium). Handles auth, CAS, chunking, hashing, compression, and reconstruction.
- **Never slower than vanilla hf_xet** — worst case is CDN-only (same as status quo).
- **No trust required for peers** — BLAKE3 hash verification on every chunk.
- **HF cache compatible** — writes to `~/.cache/huggingface/hub/` so all existing tooling works.
- **64KB chunks** — matches HuggingFace Xet's CDC parameters for content-level interop.
- **Connection pooling** — persistent BT connections reused across xorb downloads.
- **Cached peer discovery** — DHT/tracker queried once, reused for all xorbs (30s TTL refresh).
- **Direct P2P data return** — P2P data used immediately, no disk cache round-trip.
- **Seed-while-downloading** — newly downloaded xorbs are immediately available for serving to other peers.

## Project Structure

```
zest/
├── build.zig              Build configuration (Zig 0.16)
├── build.zig.zon          Package manifest (depends on zig-xet)
├── DESIGN.md              Design document (architecture, roadmap, BEP XET details)
├── CLAUDE.md              AI assistant context
├── README.md              This file
├── scripts/
│   └── build-wheel.sh     Build Zig binary + Python wheel
├── python/
│   ├── pyproject.toml      Python package metadata
│   └── zest/
│       ├── __init__.py     Public API: enable(), pull(), status(), stop()
│       ├── server.py       Zig binary lifecycle management
│       ├── client.py       HTTP client for localhost API
│       └── hf_backend.py   huggingface_hub monkey-patch
├── .github/workflows/
│   └── ci.yml             CI: build, test, lint, benchmark, metrics
└── src/
    ├── main.zig           CLI: pull, seed, serve, start, stop, bench
    ├── root.zig           Library root, re-exports all modules
    ├── config.zig         Cache dirs, HF token, DHT config, peer ID
    ├── bencode.zig        Bencode encoder/decoder (BT message serialization)
    ├── peer_id.zig        BT peer ID generation + SHA-1 info_hash
    ├── bt_wire.zig        BT wire protocol (BEP 3 + BEP 10 framing)
    ├── bep_xet.zig        BEP XET extension (4 message types)
    ├── bt_peer.zig        BT peer connection lifecycle + pipelining
    ├── peer_pool.zig      Connection pool for BT peer reuse
    ├── dht.zig            Kademlia DHT (BEP 5) for peer discovery
    ├── bt_tracker.zig     Standard BT HTTP tracker client
    ├── xet_bridge.zig     Bridges zig-xet CAS with P2P swarm (cache→P2P→CDN waterfall)
    ├── parallel_download.zig  Concurrent xorb fetching via Io.Group (up to 16 parallel)
    ├── swarm.zig          Download orchestrator (cache→peers→CDN)
    ├── storage.zig        File I/O, HF cache refs, xorb/chunk cache, XorbRegistry
    ├── server.zig         BT TCP listener for seeding chunks (concurrent via Io.Group)
    ├── http_api.zig       HTTP REST API for Python integration
    └── bench.zig          Synthetic benchmarks with JSON output
├── test/
│   └── hetzner/
│       └── p2p-test.sh    3-node Hetzner Cloud P2P integration test
```

## Performance

Synthetic benchmark results (ReleaseFast, x86_64):

| Benchmark | Throughput | What it measures |
|-----------|----------:|-----------------|
| blake3_64kb | 3,517 MB/s | Chunk hash verification speed |
| bt_wire_frame | 11,943 MB/s | BT message framing overhead |
| sha1_info_hash | 755 MB/s | info_hash computation |
| bencode_decode | 324 MB/s | BT message deserialization |
| bencode_encode | 206 MB/s | BT message serialization |

Run benchmarks: `zest bench --synthetic` or `zest bench --synthetic --json` for CI.

## Testing

```bash
# run all tests (72 tests across 18 modules)
zig build test --summary all

# check formatting
zig fmt --check src/
```

## Development

```bash
# build (debug)
zig build

# build (release, ~9 MB static binary)
zig build -Doptimize=ReleaseFast

# run directly
zig build run -- pull meta-llama/Llama-3.1-8B

# run tests
zig build test --summary all
```

### Cache Layout

| Path | Contents |
|------|----------|
| `~/.cache/huggingface/hub/models--{org}--{name}/` | HF-compatible model cache |
| `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{commit}/` | Model files |
| `~/.cache/huggingface/hub/models--{org}--{name}/refs/main` | Commit SHA ref |
| `~/.cache/zest/xorbs/{prefix}/{hash}` | Downloaded xorbs (for seeding) |
| `~/.cache/zest/chunks/{prefix}/{hash}` | Individual chunks (for BEP XET serving) |
| `~/.cache/zest/zest.pid` | PID file for background server |

## Roadmap

- [x] **Phase 1: BT-Compliant P2P Core** — BEP 3/5/10/XET, DHT, bencode, benchmarks
- [x] **Phase 2: Server Mode** — BT TCP listener, HTTP REST API, serve/start/stop commands
- [x] **Phase 3: Transfer Optimizations** — connection pooling, request pipelining, seed-while-downloading
- [x] **Phase 4: Python Package** — `pip install zest`, HF backend hook, auto-enable via `ZEST=1`
- [x] **Phase 5: XET Bridge + Parallel Downloads** — xorb-level cache→P2P→CDN waterfall, 16x concurrent downloads, thread-safe peer pool
- [x] **Phase 6: P2P Optimizations** — cached peer discovery (30s TTL), direct P2P data return (no cache round-trip), larger batch depth, typed P2P errors
- [ ] **Phase 7: Ecosystem** — vLLM, Ollama, llama.cpp integrations

See [DESIGN.md](DESIGN.md) for the full design document with architecture, BEP XET compliance details, and UX plans.

## References

- [BEP XET Specification](https://ccbittorrent.readthedocs.io/en/latest/bep_xet/) — chunk-level BitTorrent extension
- [zig-xet](https://github.com/jedisct1/zig-xet) — Zig Xet protocol implementation by Frank Denis
- [Xet Protocol Spec](https://huggingface.co/docs/xet/index) — HuggingFace content addressing
- [xet-core](https://github.com/huggingface/xet-core) — Rust reference implementation

## License

MIT
