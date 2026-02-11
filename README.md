# zest

**P2P acceleration for ML model distribution.**

[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-8%20passing-brightgreen)](#testing)
[![License](https://img.shields.io/badge/license-MIT-blue)](#license)
[![Lines of Code](https://img.shields.io/badge/lines-1%2C234-informational)](#project-structure)

zest speaks HuggingFace's [Xet protocol](https://huggingface.co/docs/xet/index) (via [zig-xet](https://github.com/jedisct1/zig-xet)) for content addressing and adds a peer swarm so model downloads come from nearby nodes instead of (only) HF's CDN.

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

Requires [Zig 0.16.0+](https://ziglang.org/download/).

```bash
git clone https://github.com/praveer13/zest.git
cd zest
zig build -Doptimize=ReleaseFast
# binary at ./zig-out/bin/zest
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
│  1. zig-xet: list files, detect Xet-backed files         │
│  2. zig-xet: download via Xet protocol (auth, CAS, CDN) │
├──────────────────────────────────────────────────────────┤
│  For each xorb needed (P2P layer):                       │
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

- **Uses [zig-xet](https://github.com/jedisct1/zig-xet) for Xet protocol** — production-quality implementation by Frank Denis (creator of libsodium). Handles auth, CAS, chunking, hashing, compression, and reconstruction.
- **Never slower than vanilla hf_xet** — worst case is CDN-only (same as status quo).
- **No trust required for peers** — BLAKE3 Merkle hash verification on every xorb.
- **HF cache compatible** — writes to `~/.cache/huggingface/hub/` so all existing tooling works.

## Project Structure

```
zest/
├── build.zig              Build configuration (Zig 0.16-dev)
├── build.zig.zon          Package manifest (depends on zig-xet)
├── CLAUDE.md              AI assistant context
├── README.md              This file
└── src/
    ├── main.zig           CLI entry point (pull, seed, version, help)
    ├── root.zig           Library root, re-exports xet + zest modules
    ├── config.zig         Cache dirs, HF token discovery, path builders
    ├── protocol.zig       P2P wire protocol (binary ser/de)
    ├── peer.zig           TCP peer connections via std.Io.net
    ├── tracker.zig        HTTP tracker client (peer discovery)
    ├── swarm.zig          Download orchestrator (cache→peers→CDN)
    └── storage.zig        File I/O, HF cache refs, xorb listing
```

### Module Metrics

| Module | Lines | Tests | Purpose |
|--------|------:|------:|---------|
| `main.zig` | 334 | 1 | CLI entry, command routing, zig-xet integration |
| `swarm.zig` | 236 | — | Download orchestrator, xorb cache, CDN fallback |
| `protocol.zig` | 141 | 3 | P2P wire protocol (binary ser/de) |
| `config.zig` | 130 | 3 | Configuration, HF token, cache paths |
| `tracker.zig` | 129 | — | HTTP tracker client |
| `peer.zig` | 122 | — | TCP peer connections via std.Io.net |
| `storage.zig` | 118 | — | File I/O, HF cache refs |
| `root.zig` | 24 | 1 | Library re-exports |
| **Total** | **1,234** | **8** | |

## Testing

```bash
# run all tests
zig build test --summary all

# check formatting
zig fmt --check src/
```

### Test Coverage

| Module | Tests | What's Covered |
|--------|------:|----------------|
| `config.zig` | 3 | Init/deinit, model snapshot paths, xorb cache paths |
| `protocol.zig` | 3 | Struct ser/de, message framing roundtrip |
| `main.zig` | 1 | Compile smoke test |
| `root.zig` | 1 | Module re-export validation |

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

## Roadmap

- [x] **Phase 1: CLI drop-in** — `zest pull` with zig-xet integration, HF cache compat
- [ ] **Phase 1.5: P2P basics** — tracker server, peer xorb exchange, LAN benchmarks
- [ ] **Phase 2: Background seeder** — `zest daemon`, auto-index, systemd service
- [ ] **Phase 3: Python bridge** — `pip install zest`, monkey-patch `snapshot_download`
- [ ] **Phase 4: Ecosystem** — vLLM, Ollama, llama.cpp integrations

## Xet Protocol Compatibility

zest uses [zig-xet](https://github.com/jedisct1/zig-xet) by Frank Denis for full Xet protocol support:

- **Content-Defined Chunking**: Gear hash CDC with same parameters as [xet-core](https://github.com/huggingface/xet-core)
- **BLAKE3 Merkle Hashing**: Domain-separated with branching factor 4
- **Xorb Format**: `XETBLOB` magic, chunk headers, footer parsing
- **Compression**: None, LZ4, ByteGrouping4LZ4, FullBitsliceLZ4
- **CAS API**: Token exchange, reconstruction term queries, parallel download
- **Model Download**: High-level API for listing files, detecting Xet, downloading

## License

MIT
