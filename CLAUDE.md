# CLAUDE.md — zest (Zig + Xet): P2P Acceleration for ML Model Distribution

## Project Identity

**zest** — A P2P acceleration layer for ML model weight distribution, written in Zig.
Speaks HuggingFace's Xet protocol for content addressing, adds a peer swarm so downloads come from nearby nodes instead of (only) HF's CDN.

`zest pull meta-llama/Llama-3.1-70B` — pulls xorbs from peers first, falls back to HF CDN. Drop-in compatible with existing HuggingFace cache layout.

## zig-xet: Integrated Dependency

[jedisct1/zig-xet](https://github.com/jedisct1/zig-xet) (by Frank Denis, creator of libsodium) is a complete, production-quality Zig implementation of the Xet protocol. It is integrated as a `build.zig.zon` dependency — zest uses it directly for all Xet protocol operations.

### What zig-xet provides (so we don't reinvent)

| zig-xet module | What it does | How zest uses it |
|----------------|-------------|------------------|
| `model_download` | High-level download API (list files, detect Xet, token exchange, download) | `main.zig` calls `listFiles()` and `downloadModelToFile()` |
| `cas_client` | Full CAS API client (auth, reconstruction queries, xorb fetch) | Used internally by `model_download` |
| `hashing` | BLAKE3 Merkle hashing with domain-separation keys | Used internally for hash verification |
| `chunking` | GearHash CDC chunker (8KB-128KB, 64KB target) | Used internally for content addressing |
| `compression` | None / LZ4 / ByteGrouping4LZ4 / FullBitsliceLZ4 | Used internally for xorb decompression |
| `xorb` | XorbBuilder + XorbReader (XETBLOB format) | Used internally for xorb parsing |
| `reconstruction` | File reconstruction from CAS terms | Used internally by `downloadModelToFile` |

### How it's wired

```zig
// build.zig.zon — dependency declaration
.dependencies = .{
    .xet = .{ .url = "https://github.com/jedisct1/zig-xet/archive/..." },
},

// build.zig — module wiring
const xet_module = b.dependency("xet", .{ .target = target, .optimize = optimize }).module("xet");
// Added to exe and lib via .imports

// src/main.zig — usage
const xet = @import("xet");
var file_list = xet.model_download.listFiles(allocator, io, environ, repo_id, "model", revision, token);
xet.model_download.downloadModelToFile(allocator, io, environ, dl_config, output_path);
```

## Why This Exists

HuggingFace replaced Git LFS with Xet storage in 2025. Xet is excellent: chunk-level deduplication (~64KB CDC chunks), content-addressed xorbs, Merkle hashing, efficient incremental uploads. But it's still **centralized** — every download hits HF's servers via presigned S3 URLs.

When a popular model drops, tens of thousands of people download the same immutable xorbs from the same CDN. This is the exact topology BitTorrent was invented to fix. zest adds a peer swarm layer on top of Xet's content addressing. We don't reinvent the chunking or hashing — we reuse Xet's (via zig-xet), and just add peer-to-peer transfer.

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
- **zig-xet** (Zig implementation): https://github.com/jedisct1/zig-xet
- **xet-core** (Rust reference impl): https://github.com/huggingface/xet-core
- Frank Denis blog: XET intro [part 1](https://00f.net/2026/01/19/xet-intro-1/), [part 2](https://00f.net/2026/01/19/xet-intro-2/)
- IETF draft spec: https://github.com/jedisct1/draft-denis-xet

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                       CLI Layer                          │
│  zest pull <repo>    zest seed     zest daemon           │
├──────────────────────────────────────────────────────────┤
│          Xet Protocol Layer (zig-xet dependency)         │
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
│  P2P: TCP via std.Io.net (MVP) → QUIC (later)           │
│  CDN: HTTP range requests to presigned S3 URLs           │
│  Wire: length-prefixed, type-tagged binary protocol      │
├──────────────────────────────────────────────────────────┤
│                Storage Layer                             │
│  Xorb-level local cache (~/.cache/zest/xorbs/)           │
│  File reconstruction → HF cache layout                   │
│  refs/main → commit SHA for from_pretrained()            │
└──────────────────────────────────────────────────────────┘
```

**Key architectural split**: The Xet Protocol Layer is handled entirely by zig-xet. The Swarm Layer is zest's unique contribution — P2P transfer on top of Xet's content addressing.

## Integration Strategy (Frictionless Adoption)

### Phase 1: CLI drop-in (MVP) — current

- `zest pull org/model` uses zig-xet to list files and download via Xet protocol
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

We do NOT invent our own chunking or hashing. zig-xet handles:

- Content-defined chunking with gearhash (same parameters as xet-core)
- Merkle hash computation for xorbs (BLAKE3, branching factor 4)
- Xorb format parsing (XETBLOB, chunk headers, decompression)
- CAS API interaction (token exchange, reconstruction terms)

The only new thing zest adds is: a DHT that maps xorb_hash → list of peers who have it.

### Wire Protocol (P2P only — zest's unique contribution)

- Custom binary protocol for peer-to-peer xorb transfer
- Messages: Handshake, XorbRequest, XorbData, HaveXorbs, PeerExchange
- All messages length-prefixed (4 bytes LE), type-tagged (1 byte)
- XorbRequest includes byte range (for partial xorb fetching)
- Serialization via `std.mem.bytesToValue` / `std.mem.toBytes`

### Transport

- MVP: TCP via `std.Io.net` (Zig 0.16 unified I/O)
- Phase 2: QUIC — multiplexed streams, built-in TLS 1.3, better NAT traversal
- CDN fallback: HTTP fetch to presigned S3 URLs from CAS response

### Peer Discovery

- MVP: Simple HTTP tracker (GET /peers, POST /announce)
- Phase 2: Kademlia DHT, node ID = BLAKE3(public_key)
- PEX between connected peers downloading same model

### Authentication

- zest needs a HF token to get a Xet token
- Reads HF token from `$HF_TOKEN` env var or `~/.cache/huggingface/token`
- zig-xet handles Xet token exchange internally
- P2P layer does NOT require auth — xorbs are content-addressed and self-verifying

## Project Structure

```
zest/
├── build.zig              Build configuration (Zig 0.16-dev)
├── build.zig.zon          Package manifest (depends on zig-xet)
├── CLAUDE.md              ← this file
├── README.md
├── .github/workflows/
│   └── ci.yml             GitHub Actions CI
└── src/
    ├── main.zig           CLI entry (pull, seed, version, help)
    ├── root.zig           Library root, re-exports xet + zest modules
    ├── config.zig         Cache dirs, HF token, path builders
    ├── protocol.zig       P2P wire protocol (binary ser/de)
    ├── peer.zig           TCP peer connections via std.Io.net
    ├── tracker.zig        HTTP tracker client (peer discovery)
    ├── swarm.zig          Download orchestrator (cache→peers→CDN)
    └── storage.zig        File I/O, HF cache refs, xorb listing
```

**8 source files, ~1,234 lines** — the Xet protocol (~912 lines) is now handled by zig-xet.

## Zig 0.16 API Patterns

This project uses Zig 0.16-dev which has significant API changes from 0.14:

### I/O

All I/O goes through `std.Io`, passed as a parameter:

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const environ = init.minimal.environ;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
}
```

### File operations

```zig
const Io = std.Io;
// All file ops take io as first argument
const file = Io.Dir.openFileAbsolute(io, path, .{});
defer file.close(io);
Io.Dir.createDirAbsolute(io, path, .default_dir);
Io.Dir.accessAbsolute(io, path, .{});
```

### Stdout/stderr

```zig
var buf: [4096]u8 = undefined;
var fw: Io.File.Writer = .init(.stdout(), io, &buf);
const writer = &fw.interface;
try writer.print("hello {s}\n", .{"world"});
try writer.flush();
```

### HTTP client

```zig
var client: std.http.Client = .{ .allocator = allocator, .io = io };
var aw: Io.Writer.Allocating = .init(allocator);
const result = client.fetch(.{
    .location = .{ .url = url },
    .response_writer = &aw.writer,
});
const data = try aw.toOwnedSlice();
```

### Networking (TCP)

```zig
const net = std.Io.net;
const stream = try address.connect(io, .{ .mode = .nonblocking });
defer stream.close(io);
var sr = stream.reader(io, &read_buf);
var sw = stream.writer(io, &write_buf);
// Use &sr.interface and &sw.interface as *Io.Reader / *Io.Writer
```

### ArrayList

```zig
var list: std.ArrayList(u8) = .empty;  // no allocator in init
defer list.deinit(allocator);          // allocator passed to each method
try list.append(allocator, item);
try list.appendSlice(allocator, items);
const slice = try list.toOwnedSlice(allocator);
```

### Environment variables

```zig
const environ = init.minimal.environ;  // std.process.Environ
const home = environ.getPosix("HOME") orelse "/root";
```

## Coding Standards

- Zig 0.16-dev (uses `std.Io` unified I/O interface)
- Dependencies: zig-xet (Xet protocol), zig-lz4 + ultracdc (transitive via zig-xet)
- Zig standard library allocators: GeneralPurposeAllocator for long-lived state, ArenaAllocator per-session
- Error handling: return errors, never panic. Degrade gracefully (peer dies → next peer → CDN)
- Run `zig fmt` before committing (enforced by CI)
- All modules must have tests; run `zig build test --summary all`

## Commands

```bash
# Build (debug)
zig build

# Build (release, ~7 MB binary)
zig build -Doptimize=ReleaseFast

# Run tests (8 tests across all modules)
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

- **zig-xet** (Zig implementation by Frank Denis): https://github.com/jedisct1/zig-xet
- **Xet protocol spec**: https://huggingface.co/docs/xet/index
- **xet-core** (Rust reference impl): https://github.com/huggingface/xet-core
- **XET blog posts** by Frank Denis: [part 1](https://00f.net/2026/01/19/xet-intro-1/), [part 2](https://00f.net/2026/01/19/xet-intro-2/)
- **IETF draft spec**: https://github.com/jedisct1/draft-denis-xet
- **HF cache layout**: `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/{commit}/`

## Immediate Next Tasks

1. **End-to-end test** — download a small real model from HF, verify files match `huggingface-cli download`
2. **Tracker server** — implement for MVP P2P testing
3. **Benchmark** — compare download speed vs `huggingface-cli download` with 3+ LAN peers
4. **Background seeder daemon** — `zest daemon` with systemd service
