/// zest library root — re-exports all public modules.
///
/// This is the library entry point for consumers who use zest as a dependency.
/// The executable entry point is in main.zig.
///
/// Xet protocol support is provided by zig-xet (https://github.com/jedisct1/zig-xet).
/// zest adds BT-compliant P2P swarm download on top of Xet's content addressing.
const std = @import("std");

// zig-xet: complete Xet protocol implementation
pub const xet = @import("xet");

// zest core modules
pub const config = @import("config.zig");
pub const swarm = @import("swarm.zig");
pub const storage = @import("storage.zig");

// BitTorrent protocol layer (BEP 3 / BEP 10 / BEP XET)
pub const bencode = @import("bencode.zig");
pub const peer_id = @import("peer_id.zig");
pub const bt_wire = @import("bt_wire.zig");
pub const bep_xet = @import("bep_xet.zig");
pub const bt_peer = @import("bt_peer.zig");
pub const dht = @import("dht.zig");
pub const bt_tracker = @import("bt_tracker.zig");
pub const bench = @import("bench.zig");

test {
    // Run tests from all modules
    std.testing.refAllDecls(@This());
}
