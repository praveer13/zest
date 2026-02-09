# CLAUDE.md — zest (Zig + Xet): P2P Acceleration for ML Model Distribution

## Project Identity

**zest** — A P2P acceleration layer for ML model weight distribution, written in Zig.
Speaks HuggingFace's Xet protocol for content addressing, adds a peer swarm so downloads come from nearby nodes instead of (only) HF's CDN.

`zest pull meta-llama/Llama-3.1-70B` — pulls xorbs from peers first, falls back to HF CDN. Drop-in compatible with existing HuggingFace cache layout.

## zig-xet: Reference Library

**IMPORTANT**: [jedisct1/zig-xet](https://github.com/jedisct1/zig-xet) (by Frank Denis, creator of libsodium) is a complete, production-quality Zig implementation of the Xet protocol. It is our **primary reference** and **future dependency target**.

### What zig-xet provides (so we don't reinvent)

| zig-xet module | What it does | Our equivalent |
|----------------|-------------|----------------|
| `constants` | All Xet protocol constants (chunk sizes, GearHash table, BLAKE3 keys, xorb limits) | `config.zig` + `hash.zig` constants |
| `chunking` | GearHash CDC chunker (8KB-128KB, 64KB target) | Not yet implemented |
| `hashing` | BLAKE3 Merkle hashing with domain-separation keys, Merkle tree with branching factor 4 | `hash.zig` |
| `compression` | None / LZ4 / ByteGrouping4LZ4 / FullBitsliceLZ4 | Not yet implemented |
| `xorb` | XorbBuilder + XorbReader (XETBLOB format, chunk headers, footer) | `xorb.zig` (types only) |
| `shard` | MDB shard format parsing | Not yet implemented |
| `reconstruction` | File reconstruction from CAS terms (serial + parallel) | `reconstruct.zig` |
| `cas_client` | Full CAS API client (auth, reconstruction queries, xorb fetch, upload) | `cas.zig` |
| `model_download` | High-level download API (list files, detect Xet, token exchange, parallel download) | `hub.zig` + `main.zig` |
| `parallel_fetcher` | Thread-pool parallel chunk fetching | Not yet implemented |

### Integration status

- **Current**: Zig 0.14.1 — zig-xet requires 0.16-dev+ (incompatible; 0.15.x panics on Linux 4.4)
- **Plan**: When stable Zig >= 0.16 is available, **replace** our Xet protocol modules (`hash.zig`, `xorb.zig`, `cas.zig`, `hub.zig`, `cdn.zig`, `reconstruct.zig`) with `zig-xet` as a `build.zig.zon` dependency
- **Now**: Align our implementations with zig-xet's architecture and validate against its test vectors
- **Zig version ceiling**: 0.14.1 works; 0.15.x has a compiler panic on this kernel (Linux 4.4). CI should test on both 0.13.0 and 0.14.1.

### Key differences from zig-xet we must fix

1. **Hash hex encoding**: zig-xet uses little-endian 8-byte segment hex (`hashToApiHex` / `apiHexToHash`). Our `hash.zig` uses naive byte-order hex. **Must align for CAS API compatibility.**
2. **Merkle tree branching factor**: zig-xet uses branching factor 4 (not binary). Our `merkleRoot()` uses binary. **Must fix.**
3. **Xet token exchange**: zig-xet gets tokens via `GET /api/models/{repo}/xet-read-token/{revision}`. Our `hub.zig` doesn't do this yet. **Must implement.**
4. **Chunk header format**: 11 bytes (version:1 + compressed_length:3 + compression_scheme:1 + uncompressed_length:3 + padding). Our `xorb.zig` doesn't parse this. **Must implement for hash verification.**
5. **Compression**: zig-xet supports LZ4 + ByteGrouping4LZ4. We have no decompression. **Must implement for real xorb data.**

### zig-xet constants to match exactly

```
Target chunk size:  65536 (64 KB)
Min chunk size:     8192  (8 KB)
Max chunk size:     131072 (128 KB)
Max xorb size:      67108864 (64 MiB)
Max chunks/xorb:    8192
Xorb format magic:  "XETBLOB"
Xorb format version: 1
```

BLAKE3 keys (already in our `hash.zig`, verified against zig-xet):
- `DATA_KEY` for leaf/chunk hashes
- `INTERNAL_NODE_KEY` for internal Merkle tree nodes
- zig-xet also has `FILE_HASH_KEY` and `VERIFICATION_KEY` — we need to add these

## Why This Exists

HuggingFace replaced Git LFS with Xet storage in 2025. Xet is excellent: chunk-level deduplication (~64KB CDC chunks), content-addressed xorbs, Merkle hashing, efficient incremental uploads. But it's still **centralized** — every download hits HF's servers via presigned S3 URLs.

When a popular model drops, tens of thousands of people download the same immutable xorbs from the same CDN. This is the exact topology BitTorrent was invented to fix. zest adds a peer swarm layer on top of Xet's content addressing. We don't reinvent the chunking or hashing — we reuse Xet's, and just add peer-to-peer transfer.

**Pitch:** zest is to Xet what WebTorrent is to HTTP — same content addressing, peers serve each other.

## How Xet Works (essential context)

Xet breaks files into ~64KB chunks using content-defined chunking (CDC, gearhash-based). Chunks are grouped into **xorbs** (up to 64 MiB each). Files are reconstructed from a list of **terms** — each term is a (xorb_hash, chunk_range) pair.

Download flow in vanilla Xet:

1. Client authenticates with HF Hub, gets a Xet token via `GET /api/models/{repo}/xet-read-token/{revision}`
1. Client resolves file → checks `X-Xet-Hash` header on `GET /{repo}/resolve/{rev}/{path}` (must NOT follow redirect)
1. Client queries CAS with the file's Xet hash → gets reconstruction terms (xorb_hash + chunk ranges + presigned URLs)
1. Client downloads xorb byte ranges from presigned URLs
1. Client decompresses chunks (LZ4 / ByteGrouping4LZ4) and reassembles file

Key Xet concepts:

- **Chunk**: ~64KB content-defined piece (CDC with gearhash, 8KB-128KB range)
- **Xorb**: A block of chunks grouped together, up to 64 MiB. Identified by BLAKE3 Merkle hash.
- **Shard**: Metadata mapping file → list of (xorb, chunk_range) terms
- **CAS**: Content-Addressable Service — the API that resolves file hashes to reconstruction info
- **Term**: A reference to a range of chunks within a xorb, used to reconstruct a file

Reference materials:

- Xet protocol spec: https://huggingface.co/docs/xet/index
- **zig-xet** (Zig reference impl): https://github.com/jedisct1/zig-xet ← PRIMARY REFERENCE
- xet-core (Rust reference impl): https://github.com/huggingface/xet-core
- Frank Denis blog: XET intro [part 1](https://00f.net/2026/01/19/xet-intro-1/), [part 2](https://00f.net/2026/01/19/xet-intro-2/)
- IETF draft spec: https://github.com/jedisct1/draft-denis-xet

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                       CLI Layer                          │
│  zest pull <repo>    zest seed     zest daemon           │
├──────────────────────────────────────────────────────────┤
│              Xet Protocol Layer (→ zig-xet)              │
│  Auth: HF token → Xet token exchange                    │
│  Resolve: X-Xet-Hash detection on /resolve endpoint     │
│  CAS: reconstruction terms + presigned URLs              │
│  Xorb: parse XETBLOB format, decompress chunks          │
│  Hash: BLAKE3 Merkle verification (branching factor 4)   │
├──────────────────────────────────────────────────────────┤
│               Swarm Layer (zest-specific)                │
│  Tracker / Kademlia DHT for peer discovery               │
│  Peers indexed by xorb_hash → peer_address               │
│  Peer exchange (PEX) between connected peers             │
├──────────────────────────────────────────────────────────┤
│               Transfer Strategy                          │
│  For each needed xorb:                                   │
│    1. Check local cache (already have it?)               │
│    2. Query swarm for peers with this xorb               │
│    3. If peers found → download from peer (P2P)          │
│    4. If no peers / slow → CDN fallback (presigned URL)  │
│    5. Race P2P vs CDN, take whichever finishes first     │
├──────────────────────────────────────────────────────────┤
│                Transfer Layer                            │
│  P2P: TCP (MVP) → QUIC (later), xorb-level exchange     │
│  CDN: HTTP range requests to presigned S3 URLs           │
│  Wire: length-prefixed, type-tagged binary protocol      │
├──────────────────────────────────────────────────────────┤
│                Storage Layer                             │
│  Xorb-level local cache (~/.cache/zest/xorbs/)           │
│  File reconstruction → HF cache layout                   │
│  refs/main → commit SHA for from_pretrained()            │
└──────────────────────────────────────────────────────────┘
```

**Key architectural split**: The Xet Protocol Layer handles all HuggingFace/Xet interaction (and will eventually be replaced by zig-xet). The Swarm Layer is zest's unique contribution — P2P transfer on top of Xet's content addressing.

## Refactoring Plan: Align with zig-xet

### Phase 0: Fix correctness issues (do first)

These must be fixed before real-world testing:

1. **`hash.zig`**: Fix Merkle tree to use branching factor 4 (not binary). Add `FILE_HASH_KEY` and `VERIFICATION_KEY` constants. Fix hex encoding to match zig-xet's little-endian segment format for CAS API calls.
2. **`hub.zig`**: Implement Xet token exchange (`GET /api/models/{repo}/xet-read-token/{rev}`). Pass Xet token (not HF token) to CAS client.
3. **`cas.zig`**: Use Xet token for auth. Fix reconstruction response parsing to match real CAS API JSON schema. Set CAS endpoint URL from Xet token response.
4. **`xorb.zig`**: Add chunk header parsing (11-byte headers). Add XETBLOB footer parsing.
5. **Add LZ4 decompression**: Required to read real xorb data. Either vendor a Zig LZ4 implementation or port from zig-xet's dependency (`jedisct1/zig-lz4`).
6. **`reconstruct.zig`**: Use chunk-level extraction (parse xorb → extract chunk range → decompress → write) instead of raw byte copying.

### Phase 1: Module alignment (current Zig 0.13)

Refactor our modules to match zig-xet's API surface, even though we can't import it directly:

| Our module | Refactor to match | Key changes |
|-----------|-------------------|-------------|
| `hash.zig` | zig-xet `hashing` | Branching factor 4 Merkle tree, add `computeFileHash()`, `computeVerificationHash()` |
| `config.zig` | zig-xet `constants` | Add all Xet protocol constants (chunk sizes, gearhash table, xorb limits) |
| `xorb.zig` | zig-xet `xorb` | Add `XorbReader` (parse footer, iterate chunks), `ChunkHeader` parsing |
| `cas.zig` | zig-xet `cas_client` | Match `ReconstructionTerm` type, add token exchange, fix API hex encoding |
| `hub.zig` | zig-xet `model_download` | Add `listFiles()`, `getFileXetHash()`, `requestXetToken()` |
| `reconstruct.zig` | zig-xet `reconstruction` | Chunk-level extraction with decompression |

### Phase 2: Direct dependency (Zig >= 0.16)

When stable Zig catches up:

1. Add `zig-xet` to `build.zig.zon` as a dependency
2. Replace `hash.zig`, `xorb.zig`, `cas.zig`, `hub.zig`, `cdn.zig`, `reconstruct.zig` with imports from `zig-xet`
3. Keep only zest-specific modules: `protocol.zig`, `peer.zig`, `tracker.zig`, `swarm.zig`, `storage.zig`, `config.zig`, `main.zig`
4. Reduce codebase by ~50%

## Integration Strategy (Frictionless Adoption)

### Phase 1: CLI drop-in (MVP) — current

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

### Content Addressing — Reuse Xet's (via zig-xet)

We do NOT invent our own chunking or hashing. We use Xet's:

- Content-defined chunking with gearhash (same parameters as xet-core and zig-xet)
- Same Merkle hash computation for xorbs (BLAKE3, branching factor 4)
- Same xorb format (XETBLOB, so our cached xorbs are byte-identical to what CAS serves)
- This means: a xorb downloaded from a peer is verified the same way as one from CDN

The only new thing we add is: a DHT that maps xorb_hash → list of peers who have it.

### Wire Protocol (P2P only — zest's unique contribution)

- Custom binary protocol for peer-to-peer xorb transfer
- Comptime-generated message serialization from Zig structs
- Messages: Handshake, XorbRequest, XorbData, HaveXorbs, PeerExchange
- All messages length-prefixed (4 bytes LE), version-tagged (1 byte)
- XorbRequest includes byte range (for partial xorb fetching)

### Transport

- MVP: TCP with length-prefixed messages
- Phase 2: QUIC — multiplexed streams, built-in TLS 1.3, better NAT traversal
- CDN fallback: HTTP range requests to presigned S3 URLs from CAS response

### Peer Discovery

- MVP: Simple HTTP tracker (GET /peers, POST /announce)
- Phase 2: Kademlia DHT, node ID = BLAKE3(public_key)
- PEX between connected peers downloading same model

### Authentication

- zest needs a HF token to get a Xet token
- Reads HF token from `$HF_TOKEN` env var or `~/.cache/huggingface/token`
- Exchanges HF token for scoped Xet token via `GET /api/models/{repo}/xet-read-token/{rev}`
- Xet tokens are scoped and short-lived — we request them per download session
- P2P layer does NOT require auth — xorbs are content-addressed and self-verifying

## Project Structure

```
zest/
├── build.zig              Build configuration (Zig 0.14.1)
├── build.zig.zon          Package manifest
├── CLAUDE.md              ← this file
├── README.md
├── .github/workflows/
│   └── ci.yml             GitHub Actions CI
└── src/
    ├── main.zig           CLI entry (pull, seed, version, help)
    ├── root.zig           Library root, re-exports all modules
    │
    │── Xet Protocol (→ replace with zig-xet when Zig >= 0.16)
    ├── config.zig         Cache dirs, HF token, protocol constants
    ├── hash.zig           BLAKE3 Merkle hash (Xet-compatible keys)
    ├── xorb.zig           Xorb types, hash verification, disk cache
    ├── hub.zig            HF Hub API client (auth, file list, Xet detection)
    ├── cas.zig            Xet CAS client (reconstruction terms, URLs)
    ├── cdn.zig            HTTP range-request downloader (CDN fallback)
    ├── reconstruct.zig    File assembly from xorbs + CAS terms
    │
    │── P2P Layer (zest-specific, keep forever)
    ├── protocol.zig       P2P wire protocol (comptime ser/de)
    ├── peer.zig           TCP peer connections and xorb transfer
    ├── tracker.zig        HTTP tracker client (peer discovery)
    ├── swarm.zig          Download orchestrator (cache→peers→CDN)
    └── storage.zig        File I/O, HF cache refs, xorb listing
```

## Coding Standards

- Zig 0.14.1 (upgraded from 0.13.0); plan upgrade path to 0.16+ for zig-xet integration
- Zig standard library allocators: GeneralPurposeAllocator for long-lived state, ArenaAllocator per-session/per-peer
- No external dependencies yet (future: zig-xet, zig-lz4)
- Error handling: return errors, never panic. Degrade gracefully (peer dies → next peer → CDN)
- Xet compatibility is paramount — validate hashes against zig-xet's test vectors
- Run `zig fmt` before committing (enforced by CI)
- All modules must have tests; run `zig build test --summary all`

## Commands

```bash
# Build (debug)
zig build

# Build (release, ~7 MB binary)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test --summary all

# Check formatting
zig fmt --check src/

# Pull a model
./zig-out/bin/zest pull meta-llama/Llama-3.1-8B

# Seed cached xorbs
./zig-out/bin/zest seed --tracker http://tracker.example.com:6881

# Benchmark against vanilla hf_xet
time huggingface-cli download meta-llama/Llama-3.1-8B
time ./zig-out/bin/zest pull meta-llama/Llama-3.1-8B
```

## Key References

- **zig-xet** (Zig implementation by Frank Denis): https://github.com/jedisct1/zig-xet ← PRIMARY REFERENCE
- **Xet protocol spec**: https://huggingface.co/docs/xet/index
- **xet-core** (Rust reference impl): https://github.com/huggingface/xet-core
- **XET blog posts** by Frank Denis: [part 1](https://00f.net/2026/01/19/xet-intro-1/), [part 2](https://00f.net/2026/01/19/xet-intro-2/)
- **IETF draft spec**: https://github.com/jedisct1/draft-denis-xet
- **HF Hub API**: `GET https://huggingface.co/api/models/{repo_id}` for file listing
- **HF cache layout**: `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{commit}/`

## Immediate Next Tasks

Priority order — fix correctness before adding features:

1. **Fix `hash.zig` Merkle tree** — branching factor 4, not binary. Add FILE_HASH_KEY, VERIFICATION_KEY. Fix hex encoding for CAS API.
2. **Implement Xet token exchange in `hub.zig`** — `GET /api/models/{repo}/xet-read-token/{rev}`. Pass Xet token to CAS.
3. **Fix `cas.zig` response parsing** — match real CAS JSON schema. Test against live API.
4. **Add LZ4 decompression** — port from zig-lz4 or implement. Required for real xorb data.
5. **Add xorb format parsing in `xorb.zig`** — XETBLOB footer, chunk headers, boundary offsets.
6. **Fix `reconstruct.zig`** — chunk-level extraction with decompression.
7. **End-to-end test** — download a small real model from HF, verify files match `huggingface-cli download`.
8. **Tracker server** — implement `tracker-server/main.zig` for MVP P2P testing.
9. **Benchmark** — compare download speed vs `huggingface-cli download` with 3+ LAN peers.
