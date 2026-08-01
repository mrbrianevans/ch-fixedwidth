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

/// In-memory CSV outputs for a parsed bulk file.
///
/// Officers products fill `companies_csv` + `persons_csv`.
/// Prod 192 fills `persons_csv` (type 1), `disqualifications_csv` (type 2),
/// `exemptions_csv` (type 3), `variations_csv` (type 4); `companies_csv` is an
/// empty document (header-only companies layout is not used — empty string).
pub const ParseResult = struct {
    companies_csv: []u8,
    persons_csv: []u8,
    disqualifications_csv: []u8,
    exemptions_csv: []u8,
    variations_csv: []u8,
    companies: i32,
    persons: i32,
    disqualifications: i32,
    exemptions: i32,
    variations: i32,
    trailer_count: i32,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.companies_csv);
        allocator.free(self.persons_csv);
        allocator.free(self.disqualifications_csv);
        allocator.free(self.exemptions_csv);
        allocator.free(self.variations_csv);
        self.* = undefined;
    }
};

fn emptyOwned(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8, "");
}

/// Parse a full fixed-width buffer into CSV outputs.
/// Caller owns the result and must call `deinit`.
pub fn parseSnapshot(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
    const file_type = try parse.identifyFileTypeFromInput(input);
    return switch (file_type) {
        .officers_snapshot => parseOfficersAppointments(allocator, input, .officers_snapshot),
        .officers_update => parseOfficersAppointments(allocator, input, .officers_update),
        .disqualifications => parseDisqualifications(allocator, input),
    };
}

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
        .disqualifications_csv = try emptyOwned(allocator),
        .exemptions_csv = try emptyOwned(allocator),
        .variations_csv = try emptyOwned(allocator),
        .companies = companies_count,
        .persons = persons_count,
        .disqualifications = 0,
        .exemptions = 0,
        .variations = 0,
        .trailer_count = tc,
    };
}

fn parseDisqualifications(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
    var persons = std.ArrayList(u8).empty;
    errdefer persons.deinit(allocator);
    var disquals = std.ArrayList(u8).empty;
    errdefer disquals.deinit(allocator);
    var exemptions = std.ArrayList(u8).empty;
    errdefer exemptions.deinit(allocator);
    var variations = std.ArrayList(u8).empty;
    errdefer variations.deinit(allocator);

    try persons.appendSlice(allocator, parse.disqual_persons_header);
    try disquals.appendSlice(allocator, parse.disqualifications_header);
    try exemptions.appendSlice(allocator, parse.exemptions_header);
    try variations.appendSlice(allocator, parse.variations_header);

    var n1: i32 = 0;
    var n2: i32 = 0;
    var n3: i32 = 0;
    var n4: i32 = 0;
    var trailer: ?parse.DisqualTrailer = null;
    var row_buf: [parse.max_csv_row_bytes]u8 = undefined;

    var rest = input;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line_raw = if (nl) |i| rest[0..i] else rest;
        rest = if (nl) |i| rest[i + 1 ..] else rest[rest.len..];

        const row = parse.stripCr(line_raw);
        if (row.len == 0 and rest.len == 0) break;

        switch (parse.classifyDisqualLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != .disqualifications) return error.UnsupportedFileType;
            },
            .trailer => {
                trailer = parse.parseDisqualTrailer(row) catch return error.MissingTrailer;
                break;
            },
            .person => {
                const n = parse.formatDisqualPersonRow(&row_buf, row);
                try persons.appendSlice(allocator, row_buf[0..n]);
                n1 += 1;
            },
            .disqualification => {
                const n = parse.formatDisqualificationRow(&row_buf, row);
                try disquals.appendSlice(allocator, row_buf[0..n]);
                n2 += 1;
            },
            .exemption => {
                const n = parse.formatExemptionRow(&row_buf, row);
                try exemptions.appendSlice(allocator, row_buf[0..n]);
                n3 += 1;
            },
            .variation => {
                const n = parse.formatVariationRow(&row_buf, row);
                try variations.appendSlice(allocator, row_buf[0..n]);
                n4 += 1;
            },
            .other => {},
        }
    }

    const tr = trailer orelse return error.MissingTrailer;
    if (tr.type1 != n1 or tr.type2 != n2 or tr.type3 != n3 or tr.type4 != n4) {
        return error.TrailerMismatch;
    }
    if (tr.total != n1 + n2 + n3 + n4) return error.TrailerMismatch;

    return .{
        .companies_csv = try emptyOwned(allocator),
        .persons_csv = try persons.toOwnedSlice(allocator),
        .disqualifications_csv = try disquals.toOwnedSlice(allocator),
        .exemptions_csv = try exemptions.toOwnedSlice(allocator),
        .variations_csv = try variations.toOwnedSlice(allocator),
        .companies = 0,
        .persons = n1,
        .disqualifications = n2,
        .exemptions = n3,
        .variations = n4,
        .trailer_count = tr.total,
    };
}
