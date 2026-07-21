//! In-memory snapshot → CSV conversion (no filesystem I/O).
//! Used by the C ABI, WASM exports, and unit tests.

const std = @import("std");
const parse = @import("parse.zig");

pub const ParseError = error{
    UnsupportedFileType,
    MissingTrailer,
    TrailerMismatch,
    OutOfMemory,
};

pub const ParseResult = struct {
    companies_csv: []u8,
    persons_csv: []u8,
    companies: i32,
    persons: i32,
    trailer_count: i32,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.companies_csv);
        allocator.free(self.persons_csv);
        self.* = undefined;
    }
};

/// Parse a full snapshot buffer into companies and persons CSV (with headers).
/// Caller owns the result and must call `deinit`.
pub fn parseSnapshot(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
    var companies = std.ArrayList(u8).empty;
    errdefer companies.deinit(allocator);
    var persons = std.ArrayList(u8).empty;
    errdefer persons.deinit(allocator);

    try companies.appendSlice(allocator, parse.companies_header);
    try persons.appendSlice(allocator, parse.persons_header);

    var companies_count: i32 = 0;
    var persons_count: i32 = 0;
    var trailer_count: ?i32 = null;
    var row_buf: [parse.max_csv_row_bytes]u8 = undefined;

    var rest = input;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line_raw = if (nl) |i| rest[0..i] else rest;
        rest = if (nl) |i| rest[i + 1 ..] else rest[rest.len..];

        const row = parse.stripCr(line_raw);
        if (row.len == 0 and rest.len == 0) break;

        switch (parse.classifyLine(row)) {
            .header => {
                _ = parse.parseHeader(row) catch return error.UnsupportedFileType;
            },
            .trailer => {
                trailer_count = parse.parseTrailerCount(row);
                break;
            },
            .company => {
                const n = parse.formatCompanyRow(&row_buf, row);
                try companies.appendSlice(allocator, row_buf[0..n]);
                companies_count += 1;
            },
            .person => {
                const n = parse.formatPersonRow(&row_buf, row);
                try persons.appendSlice(allocator, row_buf[0..n]);
                persons_count += 1;
            },
            .other => {},
        }
    }

    const tc = trailer_count orelse return error.MissingTrailer;
    const total = companies_count + persons_count;
    if (tc != total) return error.TrailerMismatch;

    return .{
        .companies_csv = try companies.toOwnedSlice(allocator),
        .persons_csv = try persons.toOwnedSlice(allocator),
        .companies = companies_count,
        .persons = persons_count,
        .trailer_count = tc,
    };
}
