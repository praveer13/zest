# zest

**P2P acceleration for ML model distribution.**

[![Zig](https://img.shields.io/badge/Zig-0.14.1-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-16%20passing-brightgreen)](#testing)
[![License](https://img.shields.io/badge/license-MIT-blue)](#license)
[![Lines of Code](https://img.shields.io/badge/lines-2%2C007-informational)](#project-structure)

zest speaks HuggingFace's [Xet protocol](https://huggingface.co/docs/xet/index) for content addressing and adds a peer swarm so model downloads come from nearby nodes instead of (only) HF's CDN.

```bash
zest pull meta-llama/Llama-3.1-70B
# pulls xorbs from peers first, falls back to HF CDN
# drop-in compatible with existing HuggingFace cache layout
```

After pulling, `transformers.AutoModel.from_pretrained("meta-llama/Llama-3.1-70B")` just works — zero workflow change.

## Why

HuggingFace replaced Git LFS with [Xet storage](https://huggingface.co/blog/xet-on-the-hub) in 2025. Xet is excellent: chunk-level deduplication (~64KB CDC chunks), content-addressed xorbs, Merkle hashing, efficient incremental uploads. But it's still **centralized** — every download hits HF's servers via presigned S3 URLs.

When a popular model drops, tens of thousands of people download the same immutable xorbs from the same CDN. This is the exact topology BitTorrent was invented to fix.

**zest is to Xet what WebTorrent is to HTTP** — same content addressing, peers serve each other.

## Installation

### From source

Requires [Zig 0.14.1](https://ziglang.org/download/).

```bash
git clone https://github.com/praveer13/zest.git
cd zest
zig build -Doptimize=ReleaseFast
# binary at ./zig-out/bin/zest
```

### Quick install (pip)

```bash
pip install ziglang==0.14.1
git clone https://github.com/praveer13/zest.git && cd zest
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/zest /usr/local/bin/
```

## Usage

### Pull a model

```bash
# basic pull (CDN-only, no tracker needed)
zest pull meta-llama/Llama-3.1-8B

# specific revision
zest pull Qwen/Qwen2-7B --revision v1.0

# with P2P peer discovery via tracker
zest pull meta-llama/Llama-3.1-8B --tracker http://tracker.example.com:6881
```

### Seed your downloads

```bash
# announce your cached xorbs so other peers can fetch from you
zest seed --tracker http://tracker.example.com:6881
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
│  1. HF Hub API → authenticate, get file list             │
│  2. Resolve endpoint → detect Xet files (X-Xet-Hash)    │
│  3. CAS API → get reconstruction terms + presigned URLs  │
├──────────────────────────────────────────────────────────┤
│  For each xorb needed:                                   │
│    ✓ Check local cache (~/.cache/zest/xorbs/)            │
│    ✓ Query tracker for peers                             │
│    ✓ Download from peer (P2P) if available               │
│    ✓ Fall back to CDN (presigned S3 URL) if needed       │
│    ✓ Verify hash (BLAKE3 Merkle)                         │
│    ✓ Cache locally for future seeding                    │
├──────────────────────────────────────────────────────────┤
│  Reconstruct files → write to HF cache layout            │
│  → transformers.from_pretrained() just works             │
└──────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Reuses Xet's content addressing** — same chunking, same hashing, same xorb format. A xorb from a peer is verified the same way as one from CDN.
- **Never slower than vanilla hf_xet** — worst case is CDN-only (same as status quo).
- **No trust required for peers** — BLAKE3 Merkle hash verification on every xorb.
- **HF cache compatible** — writes to `~/.cache/huggingface/hub/` so all existing tooling works.

## Project Structure

```
zest/
├── build.zig              Build configuration
├── build.zig.zon          Package manifest
├── CLAUDE.md              AI assistant context
├── README.md              This file
└── src/
    ├── main.zig           CLI entry point (pull, seed, version, help)
    ├── root.zig           Library root, re-exports all modules
    ├── config.zig         Cache dirs, HF token discovery, path builders
    ├── hash.zig           BLAKE3 Merkle hash (Xet-compatible keys)
    ├── xorb.zig           Xorb types, hash verification, disk cache
    ├── hub.zig            HF Hub API client (auth, file list, Xet detection)
    ├── cas.zig            Xet CAS client (reconstruction terms, URLs)
    ├── cdn.zig            HTTP range-request downloader (CDN fallback)
    ├── reconstruct.zig    File assembly from xorbs + CAS terms
    ├── protocol.zig       P2P wire protocol (comptime ser/de)
    ├── peer.zig           TCP peer connections and xorb transfer
    ├── tracker.zig        HTTP tracker client (peer discovery)
    ├── swarm.zig          Download orchestrator (cache→peers→CDN)
    └── storage.zig        File I/O, HF cache refs, xorb listing
```

### Module Metrics

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `main.zig` | 306 | 1 | CLI entry, command routing |
| `hub.zig` | 215 | — | HF Hub API, Xet detection |
| `cas.zig` | 198 | — | CAS reconstruction queries |
| `hash.zig` | 150 | 7 | BLAKE3 Merkle (Xet-compat) |
| `protocol.zig` | 144 | 3 | P2P wire protocol |
| `xorb.zig` | 138 | 2 | Xorb types & cache |
| `tracker.zig` | 137 | — | Tracker client |
| `swarm.zig` | 133 | — | Download orchestrator |
| `config.zig` | 125 | 3 | Configuration |
| `peer.zig` | 115 | — | P2P connections |
| `storage.zig` | 112 | — | File I/O |
| `reconstruct.zig` | 112 | — | File reconstruction |
| `cdn.zig` | 99 | — | CDN downloader |
| `root.zig` | 23 | — | Library re-exports |
| **Total** | **2,007** | **16** | |

## Testing

```bash
# run all tests
zig build test

# run with summary
zig build test --summary all

# run tests for a specific module
zig test src/hash.zig
```

### Test Coverage

| Module | Tests | What's Covered |
|--------|------:|----------------|
| `hash.zig` | 7 | BLAKE3 keyed hashing, determinism, Merkle root, hex roundtrip |
| `config.zig` | 3 | Init/deinit, model snapshot paths, xorb cache paths |
| `protocol.zig` | 3 | Struct ser/de, message framing roundtrip |
| `xorb.zig` | 2 | Term struct, hash verification |
| `main.zig` | 1 | Compile smoke test |

## Development

```bash
# build (debug)
zig build

# build (release, ~7 MB binary)
zig build -Doptimize=ReleaseFast

# run directly
zig build run -- pull meta-llama/Llama-3.1-8B

# run tests
zig build test
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

## Roadmap

- [x] **Phase 1: CLI drop-in** — `zest pull` with CDN download, HF cache compat
- [ ] **Phase 1.5: P2P basics** — tracker server, peer xorb exchange, LAN benchmarks
- [ ] **Phase 2: Background seeder** — `zest daemon`, auto-index, systemd service
- [ ] **Phase 3: Python bridge** — `pip install zest`, monkey-patch `snapshot_download`
- [ ] **Phase 4: Ecosystem** — vLLM, Ollama, llama.cpp integrations

## Xet Protocol Compatibility

zest implements the client side of HuggingFace's Xet protocol:

- **Content-Defined Chunking**: Gear hash CDC with same parameters as [xet-core](https://github.com/huggingface/xet-core)
- **BLAKE3 Merkle Hashing**: Domain-separated with `DATA_KEY` (leaf) and `INTERNAL_NODE_KEY` (tree) — byte-identical to xet-core
- **Xorb Format**: `XETBLOB` magic, chunk headers (version + compression + lengths), footer with hash/boundary sections
- **Compression**: None, LZ4, ByteGrouping4LZ4
- **CAS API**: Reconstruction term queries with presigned URL extraction

## License

MIT
