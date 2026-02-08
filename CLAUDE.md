# CLAUDE.md — zest (Zig + Xet): P2P Acceleration for ML Model Distribution

## Project Identity

**zest** — A P2P acceleration layer for ML model weight distribution, written in Zig.
Speaks HuggingFace's Xet protocol for content addressing, adds a peer swarm so downloads come from nearby nodes instead of (only) HF's CDN.

`zest pull meta-llama/Llama-3.1-70B` — pulls xorbs from peers first, falls back to HF CDN. Drop-in compatible with existing HuggingFace cache layout.

## Why This Exists

HuggingFace replaced Git LFS with Xet storage in 2025. Xet is excellent: chunk-level deduplication (~64KB CDC chunks), content-addressed xorbs, Merkle hashing, efficient incremental uploads. But it's still **centralized** — every download hits HF's servers via presigned S3 URLs.

When a popular model drops, tens of thousands of people download the same immutable xorbs from the same CDN. This is the exact topology BitTorrent was invented to fix. zest adds a peer swarm layer on top of Xet's content addressing. We don't reinvent the chunking or hashing — we reuse Xet's, and just add peer-to-peer transfer.

**Pitch:** zest is to Xet what WebTorrent is to HTTP — same content addressing, peers serve each other.

## How Xet Works (essential context)

Xet breaks files into ~64KB chunks using content-defined chunking (CDC, gearhash-based). Chunks are grouped into **xorbs** (up to 64 MiB each). Files are reconstructed from a list of **terms** — each term is a (xorb_hash, chunk_range) pair.

Download flow in vanilla Xet:

1. Client authenticates with HF Hub, gets a Xet token
1. Client queries CAS (Content-Addressable Service) with the file's LFS SHA256 hash
1. CAS returns reconstruction metadata: list of terms (xorb_hash + chunk ranges) + presigned URLs for each xorb
1. Client downloads xorb byte ranges from presigned URLs
1. Client reassembles file on disk from chunks

Key Xet concepts:

- **Chunk**: ~64KB content-defined piece of a file (CDC with gearhash)
- **Xorb**: A block of chunks grouped together, up to 64 MiB. Identified by hash.
- **Shard**: Metadata mapping file → list of (xorb, chunk_range) terms
- **CAS**: Content-Addressable Service — the API that resolves file hashes to reconstruction info
- **Term**: A reference to a range of chunks within a xorb, used to reconstruct a file

Reference materials:

- Xet protocol spec: https://huggingface.co/docs/xet/index
- xet-core (Rust reference impl): https://github.com/huggingface/xet-core
- Key crates: cas_client, cas_types, mdb_shard, deduplication, merklehash
- Chunking algorithm: deduplication/src/chunking.rs in xet-core
- hf_xet Python bindings: the user-facing download/upload layer

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      CLI Layer                          │
│  zest pull <repo>    zest seed     zest daemon │
├─────────────────────────────────────────────────────────┤
│                   Resolver Layer                        │
│  HF Hub API → authenticate → Xet token                 │
│  CAS API → file hash → reconstruction terms            │
│  Output: list of (xorb_hash, byte_ranges, presigned_url)│
├─────────────────────────────────────────────────────────┤
│                 Swarm Layer (DHT)                       │
│  Kademlia DHT for peer discovery                       │
│  Peers indexed by xorb_hash → peer_address             │
│  Peer exchange (PEX) between connected peers           │
├─────────────────────────────────────────────────────────┤
│               Transfer Strategy                        │
│  For each needed xorb:                                 │
│    1. Check local cache (already have it?)             │
│    2. Query swarm for peers with this xorb             │
│    3. If peers found → download from peer (P2P)        │
│    4. If no peers / slow → CDN fallback (presigned URL)│
│    5. Race P2P vs CDN, take whichever finishes first   │
├─────────────────────────────────────────────────────────┤
│                Transfer Layer                          │
│  P2P: QUIC streams per peer, xorb-level exchange       │
│  CDN: HTTP range requests to presigned S3 URLs         │
│  Adaptive: measure peer speed, drop slow peers         │
├─────────────────────────────────────────────────────────┤
│                Storage Layer                           │
│  io_uring async disk I/O (Linux)                       │
│  Xorb-level local cache (~/.cache/zest/xorbs/)     │
│  File reconstruction: terms → assemble from cached xorbs│
│  Final output: HF cache layout for from_pretrained()   │
├─────────────────────────────────────────────────────────┤
│               Integrity Layer                          │
│  Xet-compatible Merkle hashes on xorbs                 │
│  Verify xorb hash on receive (from peer or CDN)        │
│  No trust required for peers — hash verification is free│
└─────────────────────────────────────────────────────────┘
```

## Integration Strategy (Frictionless Adoption)

### Phase 1: CLI drop-in (MVP)

- `zest pull org/model` resolves via HF Hub API + Xet CAS
- Downloads xorbs (from peers when available, CDN fallback)
- Reconstructs files into HF cache dir (`~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{commit}/`)
- After pull, `transformers.from_pretrained("org/model")` just works — zero workflow change
- Also maintains a local xorb cache (`~/.cache/zest/xorbs/`) for seeding
- **Never slower than vanilla hf_xet** — worst case is CDN-only (same as status quo)

### Phase 2: Background seeder daemon

- `zest daemon` runs in background
- Watches HF cache dir, indexes xorbs from already-downloaded models
- Auto-seeds to swarm — if you have the xorbs, you're a peer
- systemd / launchd service with zero config

### Phase 3: Python bridge

- `pip install zest` — thin wrapper calling Zig binary via subprocess or FFI
- Monkey-patches `huggingface_hub.snapshot_download` to route through zest
- One line: `import zest; zest.enable()`
- Falls through to normal hf_xet if zest binary not found

### Phase 4: Ecosystem PRs

- vLLM: use zest as download backend (they have open issues about speed)
- Ollama: same
- llama.cpp: same (GGUF downloads)
- These projects all suffer from download bottlenecks

## Technical Decisions

### Content Addressing — Reuse Xet's

We do NOT invent our own chunking or hashing. We use Xet's:

- Content-defined chunking with gearhash (same parameters as xet-core)
- Same Merkle hash computation for xorbs
- Same xorb format (so our cached xorbs are byte-identical to what CAS serves)
- This means: a xorb downloaded from a peer is verified the same way as one from CDN

The only new thing we add is: a DHT that maps xorb_hash → list of peers who have it.

### Wire Protocol (P2P only — not replacing Xet wire format)

- Custom binary protocol for peer-to-peer xorb transfer
- Comptime-generated message serialization from Zig structs
- Messages: Handshake, XorbRequest, XorbData, HaveXorbs, XorbBitfield, PeerExchange
- All messages length-prefixed, version-tagged
- XorbRequest includes byte range (for partial xorb fetching)

### Transport

- MVP: TCP with length-prefixed messages
- Phase 2: QUIC — multiplexed streams, built-in TLS 1.3, better NAT traversal
- CDN fallback: HTTP range requests to presigned S3 URLs from CAS response

### Peer Discovery

- Kademlia DHT, node ID = BLAKE3(public_key)
- Bootstrap nodes hardcoded + configurable
- Announce: xorb_hash → peer_address (peers announce which xorbs they have)
- Also announce at model level: model_repo_id → peer_address (for peer exchange)
- PEX between connected peers downloading same model

### Xorb Selection Strategy

- **Rarest-first among xorbs** needed for current model (standard torrent logic)
- **Priority ordering**: config/tokenizer xorbs first (users need these immediately for from_pretrained to start), then weight shards in order
- **Speculative CDN**: if a xorb has zero peers, start CDN download immediately (don't wait)
- **Racing**: for the last few xorbs, request from both peers and CDN, cancel loser

### Disk I/O

- io_uring for all file operations on Linux
- Xorb cache: write complete xorbs to `~/.cache/zest/xorbs/{hash_prefix}/{hash}`
- File reconstruction: read from xorb cache, assemble per Xet reconstruction terms
- Pre-allocate output files before reconstruction begins

### Authentication

- zest needs a HF token to query CAS (same token as huggingface-cli)
- Reads from `~/.cache/huggingface/token` (standard location)
- Xet tokens are scoped and short-lived — we request them per download session
- P2P layer does NOT require auth — xorbs are content-addressed and self-verifying
- Peers can serve xorbs for public models without any HF account

### Privacy Considerations

- Peers in the DHT can see which xorb hashes you're requesting
- For public models this is fine (anyone can see HF repos)
- For private/gated models: peers still can't reconstruct files without the CAS reconstruction metadata (which requires auth). Xorb hashes alone don't reveal content structure.
- Optional: skip P2P entirely for private repos, CDN-only mode

## MVP Scope (Build This First)

Intentionally narrow — prove the speed win:

1. **CLI arg parsing** — `zest pull <repo_id> [--revision <ref>]`
1. **HF Hub resolver** — authenticate, get file list, get Xet file IDs
1. **CAS client** — query CAS for reconstruction terms (xorb hashes + ranges + presigned URLs)
1. **Xorb downloader (CDN)** — HTTP range-request xorbs from presigned URLs (the baseline)
1. **Xorb cache** — store downloaded xorbs locally by hash
1. **File reconstructor** — assemble files from cached xorbs per reconstruction terms
1. **Write to HF cache layout** — so `from_pretrained()` works
1. **Simple tracker** — HTTP endpoint returning peer list per xorb_hash (not full DHT yet)
1. **P2P xorb transfer** — TCP connect to peer, request xorb by hash, receive, verify, cache
1. **Swarm orchestrator** — for each needed xorb: check cache → check peers → CDN fallback → verify → reconstruct

### MVP non-goals

Full Kademlia DHT, QUIC, daemon mode, Python wrapper, NAT traversal, upload/push support.

### MVP success metric

Download a 7B model faster than `huggingface-cli download` (using hf_xet) when 3+ peers are seeding on LAN. Benchmark it, screenshot it, post it.

## Project Structure

```
zest/
├── build.zig
├── build.zig.zon
├── CLAUDE.md              ← this file
├── README.md
├── src/
│   ├── main.zig           ← CLI entry, arg parsing
│   ├── hub.zig            ← HF Hub API client (auth, file list, Xet file IDs)
│   ├── cas.zig            ← Xet CAS client (reconstruction terms, presigned URLs)
│   ├── xorb.zig           ← Xorb types, hash verification, cache read/write
│   ├── reconstruct.zig    ← File reconstruction from terms + cached xorbs
│   ├── peer.zig           ← Peer connection, P2P xorb request/transfer
│   ├── swarm.zig          ← Peer set management, xorb selection, orchestration
│   ├── tracker.zig        ← Simple HTTP tracker client (MVP peer discovery)
│   ├── cdn.zig            ← HTTP range-request downloader (presigned URL fallback)
│   ├── storage.zig        ← io_uring file I/O, pre-allocation, xorb cache management
│   ├── protocol.zig       ← P2P wire protocol message types (comptime ser/de)
│   ├── hash.zig           ← Merkle hash compat with Xet (verify xorbs from any source)
│   └── config.zig         ← Cache dirs, HF token, defaults
├── tracker-server/
│   └── main.zig           ← Minimal tracker (GET /peers?xorb=<hash> returns peer list)
└── test/
    ├── protocol_test.zig
    ├── cas_test.zig
    ├── reconstruct_test.zig
    └── xorb_test.zig
```

## Coding Standards

- Zig standard library allocators: GeneralPurposeAllocator for long-lived state, ArenaAllocator per-session/per-peer.
- Minimize external Zig dependencies. Vendor or C-call for crypto (BLAKE3, SHA256).
- All network I/O non-blocking. io_uring on Linux, fallback for macOS dev.
- Comptime-generate P2P wire protocol ser/de from struct definitions.
- Error handling: return errors, never panic. Degrade gracefully (peer dies → next peer → CDN).
- Xet compatibility is paramount — our xorb hashes MUST match xet-core's. Test against their reference implementation.
- Test hash verification, protocol roundtrips, and file reconstruction. Integration tests with localhost peers.

## Key References

- **Xet protocol spec**: https://huggingface.co/docs/xet/index (READ THIS FIRST)
- **xet-core source**: https://github.com/huggingface/xet-core
  - `cas_client/` — how the official client talks to CAS
  - `deduplication/src/chunking.rs` — the CDC algorithm (gearhash params)
  - `merklehash/` — how xorb/chunk hashes are computed
  - `data/` — upload/download orchestration
  - `hf_xet/` — Python bindings, good for understanding the user-facing flow
- **HF Hub API**: `GET https://huggingface.co/api/models/{repo_id}` for file listing
- **HF cache layout**: `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{commit}/`
- **io_uring**: `std.os.linux.io_uring` from Zig stdlib
- **Kademlia paper**: for DHT design reference

## Commands

```bash
# Build
zig build

# Run tests
zig build test

# Pull a model (MVP target)
./zig-out/bin/zest pull meta-llama/Llama-3.1-8B

# Seed your existing downloads
./zig-out/bin/zest seed

# Run tracker server (separate terminal)
./zig-out/bin/zest-tracker --port 6881

# Benchmark against vanilla hf_xet
time huggingface-cli download meta-llama/Llama-3.1-8B
time ./zig-out/bin/zest pull meta-llama/Llama-3.1-8B
```

## Immediate First Tasks

Start here, in order:

1. **Read the Xet protocol spec** — https://huggingface.co/docs/xet/index — understand CAS API, reconstruction, xorb format, chunking, hashing
1. **Read xet-core source** — especially `cas_client/` and `merklehash/` to understand exact hash computation
1. `zig init` the project, get build.zig compiling
1. `hub.zig` — HTTP GET to HF Hub API, parse JSON, extract file list + Xet file IDs
1. `cas.zig` — authenticate, query CAS, parse reconstruction response (terms + presigned URLs)
1. `cdn.zig` — download xorbs via presigned URLs (HTTP range requests). This alone gives us a working downloader.
1. `xorb.zig` + `hash.zig` — xorb cache, hash verification matching xet-core's computation
1. `reconstruct.zig` — assemble files from cached xorbs + terms. **At this point we have a working non-P2P downloader.**
1. `protocol.zig` — P2P message types, comptime ser/de, roundtrip tests
1. `peer.zig` — TCP connect, handshake, request/receive one xorb
1. `swarm.zig` — wire it all together: resolve → check cache → check peers → CDN fallback → verify → reconstruct
1. **Benchmark against `huggingface-cli download`**

Steps 4-8 give you a working Xet-compatible downloader with no P2P. That's valuable on its own (a fast Zig-native HF downloader) and proves you understand the protocol before adding the swarm layer.
