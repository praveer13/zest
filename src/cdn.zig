/// CDN fallback downloader: HTTP range-request downloader for presigned S3 URLs.
///
/// Downloads xorb byte ranges from the presigned URLs provided by the CAS API.
/// This is the baseline download path — no P2P, just direct CDN access.
/// Used as fallback when no peers are available or as a racing contender.
const std = @import("std");
const hash_mod = @import("hash.zig");
const xorb_mod = @import("xorb.zig");

pub const DownloadResult = struct {
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DownloadResult) void {
        self.allocator.free(self.data);
    }
};

pub const CdnDownloader = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator) CdnDownloader {
        return .{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *CdnDownloader) void {
        self.http_client.deinit();
    }

    /// Download a full xorb from a presigned URL.
    pub fn downloadXorb(self: *CdnDownloader, url: []const u8) !DownloadResult {
        return self.downloadRange(url, null, null);
    }

    /// Download a byte range of a xorb from a presigned URL.
    /// If range_start and range_end are both null, downloads the full content.
    pub fn downloadRange(
        self: *CdnDownloader,
        url: []const u8,
        range_start: ?u64,
        range_end: ?u64,
    ) !DownloadResult {
        const uri = try std.Uri.parse(url);

        // Build Range header if needed
        var range_header_buf: [128]u8 = undefined;
        var extra_headers_buf: [1]std.http.Header = undefined;
        var num_headers: usize = 0;

        if (range_start != null or range_end != null) {
            const start = range_start orelse 0;
            const range_str = if (range_end) |end|
                try std.fmt.bufPrint(&range_header_buf, "bytes={d}-{d}", .{ start, end })
            else
                try std.fmt.bufPrint(&range_header_buf, "bytes={d}-", .{start});

            extra_headers_buf[num_headers] = .{ .name = "Range", .value = range_str };
            num_headers += 1;
        }

        var header_buf: [16 * 1024]u8 = undefined;
        var req = try self.http_client.open(.GET, uri, .{
            .server_header_buffer = &header_buf,
            .extra_headers = extra_headers_buf[0..num_headers],
        });
        defer req.deinit();
        try req.send();
        try req.wait();

        // Accept both 200 OK and 206 Partial Content
        if (req.response.status != .ok and req.response.status != .partial_content) {
            return error.HttpError;
        }

        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();
        try req.reader().readAllArrayList(&body, 64 * 1024 * 1024);

        return .{
            .data = try body.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }

    /// Download a xorb from its term info (presigned URL + range).
    pub fn downloadTerm(self: *CdnDownloader, term: *const xorb_mod.Term) !DownloadResult {
        const url = term.url orelse return error.NoUrl;

        if (term.byte_range_start != 0 or term.byte_range_end != 0) {
            return self.downloadRange(url, term.byte_range_start, term.byte_range_end);
        }

        return self.downloadXorb(url);
    }
};
