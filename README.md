# zest

**P2P acceleration for ML model distribution.**

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-58%20passing-brightgreen)](#testing)
[![License](https://img.shields.io/badge/license-MIT-blue)](#license)
[![Lines of Code](https://img.shields.io/badge/lines-3%2C670-informational)](#project-structure)

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

### From source

Requires [Zig 0.16.0+](https://ziglang.org/download/).

```bash
git clone https://github.com/praveer13/zest.git
cd zest
zig build -Doptimize=ReleaseFast
# binary at ./zig-out/bin/zest (~7 MB static binary)
```

### Python (coming soon)

```bash
pip install zest
```

## Usage

### Pull a model

```bash
# basic pull (CDN + DHT peer discovery)
zest pull meta-llama/Llama-3.1-8B

# specific revision
zest pull Qwen/Qwen2-7B --revision v1.0

# with BT tracker for peer discovery
zest pull meta-llama/Llama-3.1-8B --tracker http://tracker.example.com:6881

# CDN-only (disable P2P)
zest pull meta-llama/Llama-3.1-8B --no-p2p
```

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

## How It Works

```
┌──────────────────────────────────────────────────────────┐
│  zest pull org/model                                     │
├──────────────────────────────────────────────────────────┤
│  1. zig-xet: list files, detect Xet-backed files         │
│  2. For each xorb:                                       │
│     ✓ Check local cache (~/.cache/zest/xorbs/)           │
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

## Project Structure

```
zest/
├── build.zig              Build configuration (Zig 0.16)
├── build.zig.zon          Package manifest (depends on zig-xet)
├── DESIGN.md              Design document (architecture, roadmap, BEP XET details)
├── CLAUDE.md              AI assistant context
├── README.md              This file
├── .github/workflows/
│   └── ci.yml             CI: build, test, lint, benchmark, metrics
└── src/
    ├── main.zig           CLI entry: pull, seed, bench, version, help
    ├── root.zig           Library root, re-exports all modules
    ├── config.zig         Cache dirs, HF token, DHT config, peer ID
    ├── bencode.zig        Bencode encoder/decoder (BT message serialization)
    ├── peer_id.zig        BT peer ID generation + SHA-1 info_hash
    ├── bt_wire.zig        BT wire protocol (BEP 3 + BEP 10 framing)
    ├── bep_xet.zig        BEP XET extension (4 message types)
    ├── bt_peer.zig        BT peer connection lifecycle + state machine
    ├── dht.zig            Kademlia DHT (BEP 5) for peer discovery
    ├── bt_tracker.zig     Standard BT HTTP tracker client
    ├── swarm.zig          Download orchestrator (cache→peers→CDN)
    ├── storage.zig        File I/O, HF cache refs, xorb/chunk cache
    └── bench.zig          Synthetic benchmarks with JSON output
```

### Module Metrics

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `dht.zig` | 671 | 11 | Kademlia DHT — routing table, KRPC, UDP |
| `main.zig` | 399 | 1 | CLI entry, command routing |
| `bencode.zig` | 368 | 12 | Bencode encoder/decoder |
| `bep_xet.zig` | 349 | 6 | BEP XET chunk transfer messages |
| `swarm.zig` | 334 | — | Download orchestration |
| `bench.zig` | 311 | 2 | Benchmarking framework |
| `bt_wire.zig` | 274 | 8 | BT wire protocol framing |
| `bt_peer.zig` | 274 | 3 | BT peer connections |
| `bt_tracker.zig` | 260 | 5 | BT HTTP tracker client |
| `storage.zig` | 175 | — | File I/O, caching |
| `config.zig` | 161 | 3 | Configuration |
| `peer_id.zig` | 63 | 5 | Peer ID + info_hash |
| `root.zig` | 31 | 2 | Library re-exports |
| **Total** | **3,670** | **58** | |

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
# run all tests (58 tests across 13 modules)
zig build test --summary all

# check formatting
zig fmt --check src/
```

## Development

```bash
# build (debug)
zig build

# build (release, ~7 MB binary)
zig build -Doptimize=ReleaseFast

# run directly
zig build run -- pull meta-llama/Llama-3.1-8B

# run tests
zig build test --summary all
```

### Authentication

zest reads your HuggingFace token from (in order):
1. `$HF_TOKEN` environment variable
2. `~/.cache/huggingface/token` (written by `huggingface-cli login`)

### Cache Layout

| Path | Contents |
|------|----------|
| `~/.cache/huggingface/hub/models--{org}--{name}/` | HF-compatible model cache |
| `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{commit}/` | Model files |
| `~/.cache/huggingface/hub/models--{org}--{name}/refs/main` | Commit SHA ref |
| `~/.cache/zest/xorbs/{prefix}/{hash}` | Downloaded xorbs (for seeding) |
| `~/.cache/zest/chunks/{prefix}/{hash}` | Individual chunks (for BEP XET serving) |

## Roadmap

- [x] **Phase 1: BT-Compliant P2P Core** — BEP 3/5/10/XET, DHT, bencode, benchmarks (58 tests)
- [ ] **Phase 2: Server Mode** — REST API, TCP listener, daemon lifecycle
- [ ] **Phase 3: Transfer Optimizations** — pipelining, multi-peer, io_uring batch, reciprocity
- [ ] **Phase 4: Python Package** — `pip install zest`, HF backend hook, Jupyter magic
- [ ] **Phase 5: Ecosystem** — vLLM, Ollama, llama.cpp integrations

See [DESIGN.md](DESIGN.md) for the full design document with architecture, BEP XET compliance details, and UX plans.

## References

- [BEP XET Specification](https://ccbittorrent.readthedocs.io/en/latest/bep_xet/) — chunk-level BitTorrent extension
- [zig-xet](https://github.com/jedisct1/zig-xet) — Zig Xet protocol implementation by Frank Denis
- [Xet Protocol Spec](https://huggingface.co/docs/xet/index) — HuggingFace content addressing
- [xet-core](https://github.com/huggingface/xet-core) — Rust reference implementation

## License

MIT
