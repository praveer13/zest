/// Xet CAS (Content-Addressable Service) client.
///
/// Queries the CAS API to get reconstruction metadata for a file:
///   - List of terms (xorb_hash + chunk ranges + byte ranges)
///   - Presigned URLs for downloading each xorb from S3/CDN
///
/// The CAS endpoint URL comes from the X-Xet-Cas-Url header or a default.
/// Authentication uses a Xet token obtained from the HF Hub.
const std = @import("std");
const hash_mod = @import("hash.zig");
const xorb_mod = @import("xorb.zig");
const cfg = @import("config.zig");

pub const CasEndpoint = struct {
    base_url: []const u8,
    token: []const u8,
};

/// Reconstruction info for a single file: the ordered list of terms
/// needed to reassemble the file from xorb chunks.
pub const ReconstructionInfo = struct {
    file_hash: hash_mod.MerkleHash,
    file_size: u64,
    terms: []xorb_mod.Term,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReconstructionInfo) void {
        for (self.terms) |term| {
            if (term.url) |url| self.allocator.free(url);
        }
        self.allocator.free(self.terms);
    }
};

pub const CasClient = struct {
    allocator: std.mem.Allocator,
    config: *const cfg.Config,
    http_client: std.http.Client,
    /// CAS endpoint URL, discovered from X-Xet-Cas-Url or default.
    cas_url: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, config: *const cfg.Config) CasClient {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = std.http.Client{ .allocator = allocator },
            .cas_url = null,
        };
    }

    pub fn deinit(self: *CasClient) void {
        self.http_client.deinit();
        if (self.cas_url) |url| self.allocator.free(url);
    }

    /// Set the CAS endpoint URL (from X-Xet-Cas-Url header or other source).
    pub fn setEndpoint(self: *CasClient, url: []const u8) !void {
        if (self.cas_url) |old| self.allocator.free(old);
        self.cas_url = try self.allocator.dupe(u8, url);
    }

    /// Query the CAS API for reconstruction metadata for a file given its Xet hash.
    /// The Xet hash comes from the X-Xet-Hash header on the HF resolve endpoint.
    pub fn getReconstructionInfo(self: *CasClient, file_hash_hex: []const u8) !ReconstructionInfo {
        const base = self.cas_url orelse return error.NoCasEndpoint;

        // CAS reconstruction endpoint: GET {cas_url}/reconstruction/{file_hash}
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/api/v1/reconstruction/{s}",
            .{ base, file_hash_hex },
        );
        defer self.allocator.free(url);

        const body = try self.httpGet(url);
        defer self.allocator.free(body);

        return try self.parseReconstructionResponse(body, file_hash_hex);
    }

    fn parseReconstructionResponse(self: *CasClient, body: []const u8, file_hash_hex: []const u8) !ReconstructionInfo {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJson;

        var file_size: u64 = 0;
        if (root.object.get("size")) |size_val| {
            if (size_val == .integer) {
                file_size = @intCast(size_val.integer);
            }
        }

        var terms = std.ArrayList(xorb_mod.Term).init(self.allocator);
        errdefer {
            for (terms.items) |term| {
                if (term.url) |u| self.allocator.free(u);
            }
            terms.deinit();
        }

        // Parse "terms" or "ranges" array from CAS response
        const terms_key = if (root.object.get("terms")) |_| "terms" else "ranges";
        if (root.object.get(terms_key)) |terms_val| {
            if (terms_val == .array) {
                for (terms_val.array.items) |item| {
                    if (item != .object) continue;

                    var term = xorb_mod.Term{
                        .xorb_hash = hash_mod.zero_hash,
                        .xorb_hash_hex = [_]u8{'0'} ** 64,
                        .chunk_range_start = 0,
                        .chunk_range_end = 0,
                        .byte_range_start = 0,
                        .byte_range_end = 0,
                        .url = null,
                    };

                    // Parse xorb hash
                    if (item.object.get("hash") orelse item.object.get("xorb_hash")) |hash_val| {
                        if (hash_val == .string) {
                            const hex = hash_val.string;
                            term.xorb_hash = hash_mod.fromHex(hex) catch hash_mod.zero_hash;
                            if (hex.len == 64) {
                                @memcpy(&term.xorb_hash_hex, hex);
                            }
                        }
                    }

                    // Parse ranges
                    if (item.object.get("chunk_start") orelse item.object.get("chunk_range_start")) |v| {
                        if (v == .integer) term.chunk_range_start = @intCast(v.integer);
                    }
                    if (item.object.get("chunk_end") orelse item.object.get("chunk_range_end")) |v| {
                        if (v == .integer) term.chunk_range_end = @intCast(v.integer);
                    }
                    if (item.object.get("range_start") orelse item.object.get("byte_range_start")) |v| {
                        if (v == .integer) term.byte_range_start = @intCast(v.integer);
                    }
                    if (item.object.get("range_end") orelse item.object.get("byte_range_end")) |v| {
                        if (v == .integer) term.byte_range_end = @intCast(v.integer);
                    }

                    // Parse presigned URL
                    if (item.object.get("url") orelse item.object.get("download_url")) |url_val| {
                        if (url_val == .string) {
                            term.url = try self.allocator.dupe(u8, url_val.string);
                        }
                    }

                    try terms.append(term);
                }
            }
        }

        const file_hash = hash_mod.fromHex(file_hash_hex) catch hash_mod.zero_hash;

        return .{
            .file_hash = file_hash,
            .file_size = file_size,
            .terms = try terms.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    fn httpGet(self: *CasClient, url: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        var header_buf: [16 * 1024]u8 = undefined;

        var extra_headers_buf: [2]std.http.Header = undefined;
        var num_headers: usize = 0;

        if (self.config.hf_token) |token| {
            extra_headers_buf[num_headers] = .{ .name = "Authorization", .value = token };
            num_headers += 1;
        }

        var req = try self.http_client.open(.GET, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = extra_headers_buf[0..num_headers],
        });
        defer req.deinit();
        try req.send();
        try req.wait();

        if (req.response.status != .ok) {
            return error.HttpError;
        }

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();
        try req.reader().readAllArrayList(&body, 64 * 1024 * 1024);
        return try body.toOwnedSlice();
    }
};
