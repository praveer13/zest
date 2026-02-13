# CLAUDE.md — zest: P2P Acceleration for ML Model Distribution

## Project Identity

**zest** — P2P acceleration for ML model downloads, written in Zig.
Speaks HuggingFace's Xet protocol (via zig-xet) for content addressing, BitTorrent (BEP 3 / BEP 10 / BEP XET) for peer-to-peer transfer. Models download from nearby peers first, fall back to HF's CDN.

`zest pull meta-llama/Llama-3.1-70B` — pulls chunks from peers via BT protocol, falls back to HF CDN. Drop-in compatible with existing HuggingFace cache layout.

See [DESIGN.md](DESIGN.md) for the full design document (architecture, BEP XET compliance, Python server plans, UX design, performance targets, roadmap).

## zig-xet: Integrated Dependency

[jedisct1/zig-xet](https://github.com/jedisct1/zig-xet) (by Frank Denis, creator of libsodium) is a complete Zig implementation of the Xet protocol. Integrated as a `build.zig.zon` dependency — zest uses it for all Xet protocol operations.

| zig-xet module | What it does | How zest uses it |
|----------------|-------------|------------------|
| `model_download` | High-level download API (list files, detect Xet, token exchange, download) | `main.zig` calls `listFiles()` and `downloadModelToFile()` |
| `cas_client` | Full CAS API client (auth, reconstruction queries, xorb fetch) | Used internally by `model_download` |
| `hashing` | BLAKE3 Merkle hashing with domain-separation keys | Used internally for hash verification |
| `chunking` | GearHash CDC chunker (8KB-128KB, 64KB target) | Used internally for content addressing |
| `compression` | None / LZ4 / ByteGrouping4LZ4 / FullBitsliceLZ4 | Used internally for xorb decompression |
| `xorb` | XorbBuilder + XorbReader (XETBLOB format) | Used internally for xorb parsing |
| `reconstruction` | File reconstruction from CAS terms | Used internally by `downloadModelToFile` |

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                       CLI Layer                          │
│  zest pull    zest seed    zest bench    zest start/stop │
├──────────────────────────────────────────────────────────┤
│          Xet Protocol Layer (zig-xet dependency)         │
│  Auth · CAS · Chunking · Hashing · Xorb · Reconstruction│
├──────────────────────────────────────────────────────────┤
│            BitTorrent Protocol Layer (zest)              │
│  BEP 3 wire · BEP 10 extensions · BEP XET chunks        │
│  BEP 5 Kademlia DHT · BT HTTP tracker                   │
├──────────────────────────────────────────────────────────┤
│               Transfer Strategy (zest)                   │
│  cache check → DHT/tracker → BT peer → CDN fallback     │
│  io_uring async · chunk pipelining · multi-peer          │
├──────────────────────────────────────────────────────────┤
│                   Storage Layer                          │
│  HF cache: ~/.cache/huggingface/hub/                     │
│  Xorb cache: ~/.cache/zest/xorbs/                        │
│  Chunk cache: ~/.cache/zest/chunks/                      │
└──────────────────────────────────────────────────────────┘
```

## Project Structure

```
zest/
├── build.zig              Build configuration (Zig 0.16)
├── build.zig.zon          Package manifest (depends on zig-xet)
├── DESIGN.md              Full design document
├── CLAUDE.md              ← this file
├── README.md
├── scripts/
│   └── build-wheel.sh     Build Zig binary + Python wheel
├── python/
│   ├── pyproject.toml      Python package metadata (zest-transfer)
│   └── zest/               Python API: enable(), pull(), status(), stop()
├── test/
│   └── hetzner/
│       └── p2p-test.sh     3-node Hetzner Cloud P2P integration test
├── .github/workflows/
│   └── ci.yml             CI: build, test, lint, benchmark, metrics
└── src/
    ├── main.zig           CLI: pull, seed, serve, start, stop, bench (805 lines)
    ├── root.zig           Library re-exports (36 lines)
    ├── config.zig         Config, HF token, DHT/peer settings (183 lines)
    ├── bencode.zig        Bencode encoder/decoder (368 lines, 12 tests)
    ├── peer_id.zig        BT peer ID + SHA-1 info_hash (63 lines, 5 tests)
    ├── bt_wire.zig        BT wire protocol, BEP 3+10 (274 lines, 8 tests)
    ├── bep_xet.zig        BEP XET extension messages (349 lines, 6 tests)
    ├── bt_peer.zig        BT peer lifecycle + state machine (322 lines, 3 tests)
    ├── peer_pool.zig      Connection pool for BT peer reuse (132 lines, 2 tests)
    ├── dht.zig            Kademlia DHT, BEP 5 (671 lines, 11 tests)
    ├── bt_tracker.zig     BT HTTP tracker client (260 lines, 5 tests)
    ├── xet_bridge.zig     Bridges zig-xet CAS with P2P swarm (304 lines, 2 tests)
    ├── parallel_download.zig  Concurrent xorb fetching (226 lines, 2 tests)
    ├── swarm.zig          Download orchestrator (386 lines)
    ├── storage.zig        File I/O, xorb/chunk cache (228 lines)
    ├── server.zig         BT TCP listener + concurrent peers (255 lines, 3 tests)
    ├── http_api.zig       HTTP REST API for Python integration (375 lines)
    └── bench.zig          Synthetic benchmarks + JSON (311 lines, 2 tests)
```

**18 source files, ~5,548 lines, 72 tests.**

## BEP XET Protocol

zest is compliant with the [BEP XET specification](https://ccbittorrent.readthedocs.io/en/latest/bep_xet/). Key details:

- **Wire format**: BEP 10 extension messages (msg_id=20), 4 XET message types
- **CHUNK_REQUEST** (0x01): 37 bytes — [type][request_id BE][chunk_hash BLAKE3-256]
- **CHUNK_RESPONSE** (0x02): 9+N bytes — [type][request_id BE][data_len BE][data]
- **CHUNK_NOT_FOUND** (0x03): 37 bytes — [type][request_id BE][chunk_hash]
- **CHUNK_ERROR** (0x04): 9+N bytes — [type][request_id BE][error_code BE][message]
- **info_hash**: `SHA-1("zest-xet-v1:" || xorb_hash_32bytes)` — per-xorb swarm granularity
- **Peer ID**: Azureus-style `-ZE0400-` + 12 random bytes
- **Chunk size**: 64KB target (matches HF Xet, not BEP XET default 16KB)
- **Hash algorithm**: BLAKE3-256 for chunk verification

## Zig 0.16 API Patterns

### Critical differences from earlier Zig versions

- `std.crypto.hash.Sha1` (NOT `std.crypto.Sha1`)
- `std.crypto.hash.Blake3` (NOT `std.crypto.blake3.Blake3`)
- `@enumFromInt(value)` (NOT `std.meta.intToEnum`)
- `Io.Clock.awake.now(io)` for monotonic timing (NOT `std.time.Timer`)
- All I/O through `std.Io`, passed as parameter from `std.process.Init`
- `std.ArrayList(T) = .empty` — allocator passed to each method, not init

### I/O

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

### Networking (TCP)

```zig
const net = std.Io.net;
const stream = try address.connect(io, .{ .mode = .nonblocking });
defer stream.close(io);
var sr = stream.reader(io, &read_buf);
var sw = stream.writer(io, &write_buf);
// Use &sr.interface and &sw.interface as *Io.Reader / *Io.Writer
```

### HTTP client

```zig
var client: std.http.Client = .{ .allocator = allocator, .io = io };
var aw: Io.Writer.Allocating = .init(allocator);
const result = client.fetch(.{
    .location = .{ .url = url },
    .response_writer = &aw.writer,
});
```

### ArrayList

```zig
var list: std.ArrayList(u8) = .empty;  // no allocator in init
defer list.deinit(allocator);          // allocator passed to each method
try list.append(allocator, item);
```

## Coding Standards

- Zig 0.16-dev (uses `std.Io` unified I/O interface)
- Dependencies: zig-xet (Xet protocol), zig-lz4 + ultracdc (transitive via zig-xet)
- Error handling: return errors, never panic. Degrade gracefully (peer dies → next peer → CDN)
- Run `zig fmt` before committing (enforced by CI)
- All modules must have tests; run `zig build test --summary all`

## Commands

```bash
zig build                              # Build (debug)
zig build -Doptimize=ReleaseFast       # Build (release, ~7 MB binary)
zig build test --summary all           # Run all 58 tests
zig fmt --check src/                   # Check formatting
./zig-out/bin/zest pull <repo>         # Download a model
./zig-out/bin/zest seed --tracker <url> # Seed cached xorbs
./zig-out/bin/zest bench --synthetic   # Run benchmarks
./zig-out/bin/zest bench --synthetic --json  # Benchmarks as JSON
```

## Key References

- **BEP XET spec**: https://ccbittorrent.readthedocs.io/en/latest/bep_xet/
- **zig-xet**: https://github.com/jedisct1/zig-xet
- **Xet protocol spec**: https://huggingface.co/docs/xet/index
- **xet-core** (Rust reference): https://github.com/huggingface/xet-core
- **BEP 3/5/10**: https://www.bittorrent.org/beps/
- **Full design doc**: [DESIGN.md](DESIGN.md)

## Next Tasks

1. **Server mode** — REST API on localhost:9847 for Python integration (`zest serve`)
2. **TCP listener** — accept incoming BT peer connections for seeding
3. **Python package** — `pip install zest` with bundled Zig binary
4. **Transfer optimizations** — chunk pipelining, multi-peer concurrent, reciprocity
