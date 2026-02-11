/// Bencode encoder/decoder — prerequisite for all BitTorrent messages.
///
/// Bencode is a simple serialization format used by BitTorrent for
/// tracker responses, DHT KRPC messages, and BEP 10 extended handshakes.
///
/// Types: integers (i42e), strings (4:spam), lists (l...e), dicts (d...e).
/// Dict keys must be sorted lexicographically.
const std = @import("std");

pub const Value = union(enum) {
    integer: i64,
    string: []const u8,
    list: []const Value,
    dict: []const DictEntry,
};

pub const DictEntry = struct {
    key: []const u8,
    value: Value,
};

pub const DecodeError = error{
    InvalidFormat,
    UnexpectedEnd,
    InvalidInteger,
    LeadingZero,
    NegativeZero,
    InvalidStringLength,
    UnsortedDictKeys,
    OutOfMemory,
};

// ── Decoding ──

pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!Value {
    var pos: usize = 0;
    const result = try decodeValue(allocator, data, &pos);
    return result;
}

fn decodeValue(allocator: std.mem.Allocator, data: []const u8, pos: *usize) DecodeError!Value {
    if (pos.* >= data.len) return error.UnexpectedEnd;

    return switch (data[pos.*]) {
        'i' => .{ .integer = try decodeInteger(data, pos) },
        'l' => .{ .list = try decodeList(allocator, data, pos) },
        'd' => .{ .dict = try decodeDict(allocator, data, pos) },
        '0'...'9' => .{ .string = try decodeString(data, pos) },
        else => error.InvalidFormat,
    };
}

fn decodeInteger(data: []const u8, pos: *usize) DecodeError!i64 {
    if (pos.* >= data.len or data[pos.*] != 'i') return error.InvalidFormat;
    pos.* += 1; // skip 'i'

    const start = pos.*;
    // Find 'e' terminator
    while (pos.* < data.len and data[pos.*] != 'e') : (pos.* += 1) {}
    if (pos.* >= data.len) return error.UnexpectedEnd;

    const num_str = data[start..pos.*];
    pos.* += 1; // skip 'e'

    if (num_str.len == 0) return error.InvalidInteger;

    // No leading zeros (except "0" itself)
    if (num_str.len > 1 and num_str[0] == '0') return error.LeadingZero;
    // No negative zero
    if (std.mem.eql(u8, num_str, "-0")) return error.NegativeZero;
    // No leading zeros after minus
    if (num_str.len > 2 and num_str[0] == '-' and num_str[1] == '0') return error.LeadingZero;

    return std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidInteger;
}

fn decodeString(data: []const u8, pos: *usize) DecodeError![]const u8 {
    const start = pos.*;
    // Find ':'
    while (pos.* < data.len and data[pos.*] != ':') : (pos.* += 1) {}
    if (pos.* >= data.len) return error.UnexpectedEnd;

    const len_str = data[start..pos.*];
    const len = std.fmt.parseInt(usize, len_str, 10) catch return error.InvalidStringLength;
    pos.* += 1; // skip ':'

    if (pos.* + len > data.len) return error.UnexpectedEnd;
    const str = data[pos.* .. pos.* + len];
    pos.* += len;
    return str;
}

fn decodeList(allocator: std.mem.Allocator, data: []const u8, pos: *usize) DecodeError![]const Value {
    if (pos.* >= data.len or data[pos.*] != 'l') return error.InvalidFormat;
    pos.* += 1; // skip 'l'

    var items: std.ArrayList(Value) = .empty;
    errdefer items.deinit(allocator);

    while (pos.* < data.len and data[pos.*] != 'e') {
        const val = try decodeValue(allocator, data, pos);
        try items.append(allocator, val);
    }
    if (pos.* >= data.len) return error.UnexpectedEnd;
    pos.* += 1; // skip 'e'

    return try items.toOwnedSlice(allocator);
}

fn decodeDict(allocator: std.mem.Allocator, data: []const u8, pos: *usize) DecodeError![]const DictEntry {
    if (pos.* >= data.len or data[pos.*] != 'd') return error.InvalidFormat;
    pos.* += 1; // skip 'd'

    var entries: std.ArrayList(DictEntry) = .empty;
    errdefer entries.deinit(allocator);

    var last_key: ?[]const u8 = null;
    while (pos.* < data.len and data[pos.*] != 'e') {
        const key = try decodeString(data, pos);

        // Verify lexicographic key ordering
        if (last_key) |prev| {
            if (std.mem.order(u8, prev, key) != .lt) return error.UnsortedDictKeys;
        }
        last_key = key;

        const value = try decodeValue(allocator, data, pos);
        try entries.append(allocator, .{ .key = key, .value = value });
    }
    if (pos.* >= data.len) return error.UnexpectedEnd;
    pos.* += 1; // skip 'e'

    return try entries.toOwnedSlice(allocator);
}

// ── Encoding ──

pub fn encode(allocator: std.mem.Allocator, value: Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try encodeValue(allocator, &buf, value);
    return try buf.toOwnedSlice(allocator);
}

fn encodeValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .integer => |i| {
            try buf.append(allocator, 'i');
            var num_buf: [24]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch unreachable;
            try buf.appendSlice(allocator, num_str);
            try buf.append(allocator, 'e');
        },
        .string => |s| {
            var len_buf: [20]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{s.len}) catch unreachable;
            try buf.appendSlice(allocator, len_str);
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, s);
        },
        .list => |items| {
            try buf.append(allocator, 'l');
            for (items) |item| {
                try encodeValue(allocator, buf, item);
            }
            try buf.append(allocator, 'e');
        },
        .dict => |entries| {
            try buf.append(allocator, 'd');
            for (entries) |entry| {
                // Encode key as bencoded string
                var len_buf: [20]u8 = undefined;
                const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{entry.key.len}) catch unreachable;
                try buf.appendSlice(allocator, len_str);
                try buf.append(allocator, ':');
                try buf.appendSlice(allocator, entry.key);
                // Encode value
                try encodeValue(allocator, buf, entry.value);
            }
            try buf.append(allocator, 'e');
        },
    }
}

// ── Helpers ──

/// Look up a key in a bencoded dict.
pub fn dictGet(entries: []const DictEntry, key: []const u8) ?Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

/// Look up a key and return its integer value.
pub fn dictGetInt(entries: []const DictEntry, key: []const u8) ?i64 {
    const val = dictGet(entries, key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// Look up a key and return its string value.
pub fn dictGetStr(entries: []const DictEntry, key: []const u8) ?[]const u8 {
    const val = dictGet(entries, key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Look up a key and return its dict value.
pub fn dictGetDict(entries: []const DictEntry, key: []const u8) ?[]const DictEntry {
    const val = dictGet(entries, key) orelse return null;
    return switch (val) {
        .dict => |d| d,
        else => null,
    };
}

/// Free all memory allocated by decode(). Only frees containers (lists, dicts),
/// not the string slices (which point into the original data buffer).
pub fn deinit(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .list => |items| {
            for (items) |item| deinit(allocator, item);
            allocator.free(items);
        },
        .dict => |entries| {
            for (entries) |entry| deinit(allocator, entry.value);
            allocator.free(entries);
        },
        .integer, .string => {},
    }
}

// ── Tests ──

test "decode and encode integer" {
    const alloc = std.testing.allocator;
    const val = try decode(alloc, "i42e");
    defer deinit(alloc, val);
    try std.testing.expectEqual(@as(i64, 42), val.integer);

    const encoded = try encode(alloc, val);
    defer alloc.free(encoded);
    try std.testing.expectEqualSlices(u8, "i42e", encoded);
}

test "decode and encode negative integer" {
    const alloc = std.testing.allocator;
    const val = try decode(alloc, "i-7e");
    defer deinit(alloc, val);
    try std.testing.expectEqual(@as(i64, -7), val.integer);

    const encoded = try encode(alloc, val);
    defer alloc.free(encoded);
    try std.testing.expectEqualSlices(u8, "i-7e", encoded);
}

test "decode and encode zero" {
    const alloc = std.testing.allocator;
    const val = try decode(alloc, "i0e");
    defer deinit(alloc, val);
    try std.testing.expectEqual(@as(i64, 0), val.integer);
}

test "reject leading zeros" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.LeadingZero, decode(alloc, "i03e"));
}

test "reject negative zero" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.NegativeZero, decode(alloc, "i-0e"));
}

test "decode and encode string" {
    const alloc = std.testing.allocator;
    const val = try decode(alloc, "4:spam");
    defer deinit(alloc, val);
    try std.testing.expectEqualSlices(u8, "spam", val.string);

    const encoded = try encode(alloc, val);
    defer alloc.free(encoded);
    try std.testing.expectEqualSlices(u8, "4:spam", encoded);
}

test "decode and encode empty string" {
    const alloc = std.testing.allocator;
    const val = try decode(alloc, "0:");
    defer deinit(alloc, val);
    try std.testing.expectEqual(@as(usize, 0), val.string.len);

    const encoded = try encode(alloc, val);
    defer alloc.free(encoded);
    try std.testing.expectEqualSlices(u8, "0:", encoded);
}

test "decode and encode list" {
    const alloc = std.testing.allocator;
    const val = try decode(alloc, "li1ei2ei3ee");
    defer deinit(alloc, val);
    try std.testing.expectEqual(@as(usize, 3), val.list.len);
    try std.testing.expectEqual(@as(i64, 1), val.list[0].integer);
    try std.testing.expectEqual(@as(i64, 2), val.list[1].integer);
    try std.testing.expectEqual(@as(i64, 3), val.list[2].integer);

    const encoded = try encode(alloc, val);
    defer alloc.free(encoded);
    try std.testing.expectEqualSlices(u8, "li1ei2ei3ee", encoded);
}

test "decode and encode dict" {
    const alloc = std.testing.allocator;
    // d3:bar4:spam3:fooi42ee
    const val = try decode(alloc, "d3:bar4:spam3:fooi42ee");
    defer deinit(alloc, val);
    try std.testing.expectEqual(@as(usize, 2), val.dict.len);
    try std.testing.expectEqualSlices(u8, "bar", val.dict[0].key);
    try std.testing.expectEqualSlices(u8, "spam", val.dict[0].value.string);
    try std.testing.expectEqualSlices(u8, "foo", val.dict[1].key);
    try std.testing.expectEqual(@as(i64, 42), val.dict[1].value.integer);

    const encoded = try encode(alloc, val);
    defer alloc.free(encoded);
    try std.testing.expectEqualSlices(u8, "d3:bar4:spam3:fooi42ee", encoded);
}

test "decode nested dict" {
    const alloc = std.testing.allocator;
    // d1:md6:ut_xeti1eee — BEP 10 style
    const val = try decode(alloc, "d1:md6:ut_xeti1eee");
    defer deinit(alloc, val);

    const m = dictGetDict(val.dict, "m") orelse return error.InvalidFormat;
    const ut_xet = dictGetInt(m, "ut_xet") orelse return error.InvalidFormat;
    try std.testing.expectEqual(@as(i64, 1), ut_xet);
}

test "reject unsorted dict keys" {
    const alloc = std.testing.allocator;
    // "z" before "a" is out of order
    try std.testing.expectError(error.UnsortedDictKeys, decode(alloc, "d1:zi1e1:ai2ee"));
}

test "dictGet helpers" {
    const alloc = std.testing.allocator;
    const val = try decode(alloc, "d4:name4:zest4:porti6881ee");
    defer deinit(alloc, val);

    try std.testing.expectEqual(@as(i64, 6881), dictGetInt(val.dict, "port").?);
    try std.testing.expectEqualSlices(u8, "zest", dictGetStr(val.dict, "name").?);
    try std.testing.expect(dictGet(val.dict, "missing") == null);
}

test "encode roundtrip complex structure" {
    const alloc = std.testing.allocator;
    // BEP 10 extended handshake-like structure
    const input = "d1:md6:ut_xeti1ee1:pi6881e1:v4:zeste";
    const val = try decode(alloc, input);
    defer deinit(alloc, val);

    const encoded = try encode(alloc, val);
    defer alloc.free(encoded);
    try std.testing.expectEqualSlices(u8, input, encoded);
}
