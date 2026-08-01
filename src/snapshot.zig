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
/// `exemptions_csv` (type 3), `variations_csv` (type 4); `companies_csv` empty.
/// Prod 197 fills `companies_csv` as forms, `persons_csv` as practitioners,
/// `disqualifications_csv` as free text; other slots empty. Counts mirror those
/// CSV row counts; trailer_count is the total raw data-record count.
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
        .liquidation => parseLiquidation(allocator, input),
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
                    .disqualifications, .liquidation => unreachable,
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

fn emitLiqForm(
    allocator: std.mem.Allocator,
    form: *const parse.LiqForm,
    forms: *std.ArrayList(u8),
    practitioners: *std.ArrayList(u8),
    free_texts: *std.ArrayList(u8),
    forms_count: *i32,
    practitioners_count: *i32,
    free_text_count: *i32,
    row_buf: *[parse.max_csv_row_bytes]u8,
) ParseError!void {
    if (!form.active) return;
    const n = parse.formatLiqFormRow(row_buf, form);
    try forms.appendSlice(allocator, row_buf[0..n]);
    forms_count.* += 1;

    var i: usize = 0;
    while (i < form.practitioner_count) : (i += 1) {
        const pn = parse.formatLiqPractitionerRow(row_buf, form, i);
        try practitioners.appendSlice(allocator, row_buf[0..pn]);
        practitioners_count.* += 1;
    }
    i = 0;
    while (i < form.free_text_count) : (i += 1) {
        const fn_ = parse.formatLiqFreeTextRow(row_buf, form, i);
        try free_texts.appendSlice(allocator, row_buf[0..fn_]);
        free_text_count.* += 1;
    }
}

fn parseLiquidation(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
    var forms = std.ArrayList(u8).empty;
    errdefer forms.deinit(allocator);
    var practitioners = std.ArrayList(u8).empty;
    errdefer practitioners.deinit(allocator);
    var free_texts = std.ArrayList(u8).empty;
    errdefer free_texts.deinit(allocator);

    try forms.appendSlice(allocator, parse.liq_forms_header);
    try practitioners.appendSlice(allocator, parse.liq_practitioners_header);
    try free_texts.appendSlice(allocator, parse.liq_free_text_header);

    var forms_count: i32 = 0;
    var practitioners_count: i32 = 0;
    var free_text_count: i32 = 0;
    var data_records: i32 = 0;
    var trailer_count: ?i32 = null;
    var form: parse.LiqForm = .{};
    var row_buf: [parse.max_csv_row_bytes]u8 = undefined;

    var rest = input;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line_raw = if (nl) |i| rest[0..i] else rest;
        rest = if (nl) |i| rest[i + 1 ..] else rest[rest.len..];

        const row = parse.stripCr(line_raw);
        if (row.len == 0 and rest.len == 0) break;

        switch (parse.classifyLiqLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != .liquidation) return error.UnsupportedFileType;
            },
            .trailer => {
                try emitLiqForm(
                    allocator,
                    &form,
                    &forms,
                    &practitioners,
                    &free_texts,
                    &forms_count,
                    &practitioners_count,
                    &free_text_count,
                    &row_buf,
                );
                form.reset();
                trailer_count = parse.parseTrailerCount(row);
                break;
            },
            .form => {
                try emitLiqForm(
                    allocator,
                    &form,
                    &forms,
                    &practitioners,
                    &free_texts,
                    &forms_count,
                    &practitioners_count,
                    &free_text_count,
                    &row_buf,
                );
                form.reset();
                form.applyRecord(row);
                data_records += 1;
            },
            .data => {
                form.applyRecord(row);
                data_records += 1;
            },
            .other => {},
        }
    }

    const tc = trailer_count orelse return error.MissingTrailer;
    if (tc != data_records) return error.TrailerMismatch;

    return .{
        .companies_csv = try forms.toOwnedSlice(allocator),
        .persons_csv = try practitioners.toOwnedSlice(allocator),
        .disqualifications_csv = try free_texts.toOwnedSlice(allocator),
        .exemptions_csv = try emptyOwned(allocator),
        .variations_csv = try emptyOwned(allocator),
        .companies = forms_count,
        .persons = practitioners_count,
        .disqualifications = free_text_count,
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
