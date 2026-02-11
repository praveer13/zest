/// zest library root — re-exports all public modules.
///
/// This is the library entry point for consumers who use zest as a dependency.
/// The executable entry point is in main.zig.
///
/// Xet protocol support is provided by zig-xet (https://github.com/jedisct1/zig-xet).
/// zest adds P2P swarm download on top of Xet's content addressing.
const std = @import("std");

// zig-xet: complete Xet protocol implementation
pub const xet = @import("xet");

// zest-specific modules (P2P layer)
pub const config = @import("config.zig");
pub const protocol = @import("protocol.zig");
pub const peer = @import("peer.zig");
pub const tracker = @import("tracker.zig");
pub const swarm = @import("swarm.zig");
pub const storage = @import("storage.zig");

test {
    // Run tests from all modules
    std.testing.refAllDecls(@This());
}
