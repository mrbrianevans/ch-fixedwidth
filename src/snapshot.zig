//! In-memory fixed-width file → CSV conversion (no filesystem I/O).
//! Used by the C ABI, WASM exports, and unit tests.
//!
//! Entry point `parseSnapshot` identifies the product from the header magic
//! and dispatches to the matching body parser.

const std = @import("std");
const parse = @import("parse.zig");

pub const ParseError = error{
    UnsupportedFileType,
    NotImplemented,
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

/// Parse a full fixed-width buffer into CSV outputs.
/// Caller owns the result and must call `deinit`.
///
/// Dispatches on the 8-byte header identifier:
/// - `DDDDSNAP` → officers snapshot (implemented)
/// - `DDDDUPDT` → officers update (implemented)
/// - `DISQUALS` → `error.NotImplemented`
/// - anything else → `error.UnsupportedFileType`
pub fn parseSnapshot(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
    const file_type = try parse.identifyFileTypeFromInput(input);
    return switch (file_type) {
        .officers_snapshot => parseOfficersAppointments(allocator, input, .officers_snapshot),
        .officers_update => parseOfficersAppointments(allocator, input, .officers_update),
        .disqualifications => error.NotImplemented,
    };
}

/// Shared company + person CSV path for Prod 195/216 snapshot and Prod 198 update.
/// Company records share a layout; person fixed fields differ by product.
fn parseOfficersAppointments(
    allocator: std.mem.Allocator,
    input: []const u8,
    file_type: parse.FileType,
) ParseError!ParseResult {
    var companies = std.ArrayList(u8).empty;
    errdefer companies.deinit(allocator);
    var persons = std.ArrayList(u8).empty;
    errdefer persons.deinit(allocator);

    try companies.appendSlice(allocator, parse.companies_header);
    try persons.appendSlice(allocator, file_type.personsCsvHeader());

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
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != file_type) return error.UnsupportedFileType;
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
                const n = switch (file_type) {
                    .officers_snapshot => parse.formatPersonRow(&row_buf, row),
                    .officers_update => parse.formatUpdatePersonRow(&row_buf, row),
                    .disqualifications => unreachable,
                };
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
