//! Incremental fixed-width → CSV conversion for hosts that cannot hold the full
//! file (or full outputs) in memory.
//!
//! Design:
//! - Host feeds arbitrary input chunks (need not end on line boundaries).
//! - Parser retains only a partial-line carry buffer plus open CSV batches.
//! - Completed CSV is pulled in **batches** (default ~1000 rows or 256 KiB),
//!   not per line — avoids WASM↔host call overhead.
//! - Host should drain batches after each `feed` / `finish` so peak memory
//!   stays O(chunk + batch), not O(file).

const std = @import("std");
const parse = @import("parse.zig");

pub const ParseError = error{
    UnsupportedFileType,
    NotImplemented,
    MissingTrailer,
    TrailerMismatch,
    OutOfMemory,
    AlreadyFinished,
    FeedAfterTrailer,
};

pub const BatchKind = enum(i32) {
    companies = 0,
    persons = 1,
    disqualifications = 2,
    exemptions = 3,
    variations = 4,
};

pub const CsvBatch = struct {
    data: []u8,
    row_count: i32,
    kind: BatchKind,

    pub fn deinit(self: *CsvBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const StreamConfig = struct {
    /// Flush when this many data rows are buffered for a kind (0 → default).
    batch_rows: usize = 0,
    /// Flush when buffered CSV bytes for a kind reach this size (0 → default).
    batch_bytes: usize = 0,

    pub const default_batch_rows: usize = 1000;
    pub const default_batch_bytes: usize = 256 * 1024;

    pub fn resolved(self: StreamConfig) StreamConfig {
        return .{
            .batch_rows = if (self.batch_rows == 0) default_batch_rows else self.batch_rows,
            .batch_bytes = if (self.batch_bytes == 0) default_batch_bytes else self.batch_bytes,
        };
    }
};

const KindBuf = struct {
    buf: std.ArrayList(u8) = .empty,
    rows: usize = 0,
    header_written: bool = false,
    count: i32 = 0,
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    config: StreamConfig,

    carry: std.ArrayList(u8) = .empty,
    companies: KindBuf = .{},
    persons: KindBuf = .{},
    disqualifications: KindBuf = .{},
    exemptions: KindBuf = .{},
    variations: KindBuf = .{},

    ready: std.ArrayList(CsvBatch) = .empty,

    trailer_count: ?i32 = null,
    /// Prod 192 per-type trailer expectations (set when trailer seen).
    disqual_trailer: ?parse.DisqualTrailer = null,
    /// Prod 197: count of raw data records (every non-header/trailer line).
    liq_data_records: i32 = 0,
    liq_form: parse.LiqForm = .{},
    header_seen: bool = false,
    finished: bool = false,
    saw_trailer: bool = false,

    magic: [parse.header_identifier_len]u8 = undefined,
    magic_len: u8 = 0,
    file_type: ?parse.FileType = null,

    row_buf: [parse.max_csv_row_bytes]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, config: StreamConfig) Stream {
        return .{
            .allocator = allocator,
            .config = config.resolved(),
        };
    }

    pub fn deinit(self: *Stream) void {
        self.carry.deinit(self.allocator);
        self.companies.buf.deinit(self.allocator);
        self.persons.buf.deinit(self.allocator);
        self.disqualifications.buf.deinit(self.allocator);
        self.exemptions.buf.deinit(self.allocator);
        self.variations.buf.deinit(self.allocator);
        for (self.ready.items) |*b| b.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.* = undefined;
    }

    /// Feed the next chunk of input bytes. Drain with `nextBatch` afterward.
    pub fn feed(self: *Stream, chunk: []const u8) ParseError!void {
        if (self.finished) return error.AlreadyFinished;
        if (self.saw_trailer) {
            if (chunk.len == 0) return;
            for (chunk) |c| {
                if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
                    return error.FeedAfterTrailer;
                }
            }
            return;
        }

        try self.ingestMagic(chunk);

        var rest = chunk;

        if (self.carry.items.len > 0) {
            if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                try self.carry.appendSlice(self.allocator, rest[0..nl]);
                try self.handleLine(self.carry.items);
                self.carry.clearRetainingCapacity();
                rest = rest[nl + 1 ..];
            } else {
                try self.carry.appendSlice(self.allocator, rest);
                return;
            }
        }

        while (rest.len > 0) {
            if (self.saw_trailer) {
                for (rest) |c| {
                    if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
                        return error.FeedAfterTrailer;
                    }
                }
                return;
            }
            if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                try self.handleLine(rest[0..nl]);
                rest = rest[nl + 1 ..];
            } else {
                try self.carry.appendSlice(self.allocator, rest);
                return;
            }
        }
    }

    pub fn finish(self: *Stream) ParseError!void {
        if (self.finished) return error.AlreadyFinished;

        if (self.file_type == null) {
            return error.UnsupportedFileType;
        }

        if (!self.saw_trailer and self.carry.items.len > 0) {
            try self.handleLine(self.carry.items);
            self.carry.clearRetainingCapacity();
        } else {
            self.carry.clearRetainingCapacity();
        }

        const ft = self.file_type.?;
        switch (ft) {
            .officers_snapshot, .officers_update => {
                try self.ensureHeader(&self.companies, parse.companies_header);
                try self.ensureHeader(&self.persons, ft.personsCsvHeader());
                try self.flushKind(&self.companies, .companies, true);
                try self.flushKind(&self.persons, .persons, true);
            },
            .disqualifications => {
                try self.ensureHeader(&self.persons, parse.disqual_persons_header);
                try self.ensureHeader(&self.disqualifications, parse.disqualifications_header);
                try self.ensureHeader(&self.exemptions, parse.exemptions_header);
                try self.ensureHeader(&self.variations, parse.variations_header);
                try self.flushKind(&self.persons, .persons, true);
                try self.flushKind(&self.disqualifications, .disqualifications, true);
                try self.flushKind(&self.exemptions, .exemptions, true);
                try self.flushKind(&self.variations, .variations, true);
            },
            .liquidation => {
                try self.ensureHeader(&self.companies, parse.liq_forms_header);
                try self.ensureHeader(&self.persons, parse.liq_practitioners_header);
                try self.ensureHeader(&self.disqualifications, parse.liq_free_text_header);
                try self.flushKind(&self.companies, .companies, true);
                try self.flushKind(&self.persons, .persons, true);
                try self.flushKind(&self.disqualifications, .disqualifications, true);
            },
        }

        self.finished = true;

        const tc = self.trailer_count orelse return error.MissingTrailer;
        switch (ft) {
            .officers_snapshot, .officers_update => {
                if (tc != self.companies.count + self.persons.count) return error.TrailerMismatch;
            },
            .disqualifications => {
                const tr = self.disqual_trailer orelse return error.MissingTrailer;
                if (tr.type1 != self.persons.count or
                    tr.type2 != self.disqualifications.count or
                    tr.type3 != self.exemptions.count or
                    tr.type4 != self.variations.count or
                    tr.total != tc)
                {
                    return error.TrailerMismatch;
                }
                if (tc != self.persons.count + self.disqualifications.count +
                    self.exemptions.count + self.variations.count)
                {
                    return error.TrailerMismatch;
                }
            },
            .liquidation => {
                if (tc != self.liq_data_records) return error.TrailerMismatch;
            },
        }
    }

    fn ingestMagic(self: *Stream, data: []const u8) ParseError!void {
        const need = parse.header_identifier_len;
        if (self.magic_len >= need) return;

        const take = @min(need - self.magic_len, data.len);
        if (take == 0) return;
        @memcpy(self.magic[self.magic_len..][0..take], data[0..take]);
        self.magic_len += @intCast(take);

        if (self.magic_len < need) return;

        const file_type = parse.identifyFileType(self.magic[0..need]) catch {
            return error.UnsupportedFileType;
        };
        try parse.requireImplemented(file_type);
        self.file_type = file_type;
    }

    pub fn nextBatch(self: *Stream) ?CsvBatch {
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    fn handleLine(self: *Stream, line_raw: []const u8) ParseError!void {
        const row = parse.stripCr(line_raw);
        if (row.len == 0) return;

        const file_type = self.file_type orelse return error.UnsupportedFileType;
        switch (file_type) {
            .officers_snapshot, .officers_update => try self.handleOfficersLine(row, file_type),
            .disqualifications => try self.handleDisqualLine(row),
            .liquidation => try self.handleLiqLine(row),
        }
    }

    fn handleOfficersLine(self: *Stream, row: []const u8, file_type: parse.FileType) ParseError!void {
        switch (parse.classifyLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != file_type) return error.UnsupportedFileType;
                self.header_seen = true;
                try self.ensureHeader(&self.companies, parse.companies_header);
                try self.ensureHeader(&self.persons, file_type.personsCsvHeader());
            },
            .trailer => {
                self.trailer_count = parse.parseTrailerCount(row);
                self.saw_trailer = true;
            },
            .company => {
                try self.ensureHeader(&self.companies, parse.companies_header);
                const n = parse.formatCompanyRow(&self.row_buf, row);
                try self.companies.buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.companies.rows += 1;
                self.companies.count += 1;
                try self.flushKind(&self.companies, .companies, false);
            },
            .person => {
                try self.ensureHeader(&self.persons, file_type.personsCsvHeader());
                const n = switch (file_type) {
                    .officers_snapshot => parse.formatPersonRow(&self.row_buf, row),
                    .officers_update => parse.formatUpdatePersonRow(&self.row_buf, row),
                    .disqualifications, .liquidation => unreachable,
                };
                try self.persons.buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.persons.rows += 1;
                self.persons.count += 1;
                try self.flushKind(&self.persons, .persons, false);
            },
            .other => {},
        }
    }

    fn emitLiqFormToBuffers(self: *Stream) ParseError!void {
        if (!self.liq_form.active) return;
        try self.ensureHeader(&self.companies, parse.liq_forms_header);
        try self.ensureHeader(&self.persons, parse.liq_practitioners_header);
        try self.ensureHeader(&self.disqualifications, parse.liq_free_text_header);

        const n = parse.formatLiqFormRow(&self.row_buf, &self.liq_form);
        try self.companies.buf.appendSlice(self.allocator, self.row_buf[0..n]);
        self.companies.rows += 1;
        self.companies.count += 1;
        try self.flushKind(&self.companies, .companies, false);

        var i: usize = 0;
        while (i < self.liq_form.practitioner_count) : (i += 1) {
            const pn = parse.formatLiqPractitionerRow(&self.row_buf, &self.liq_form, i);
            try self.persons.buf.appendSlice(self.allocator, self.row_buf[0..pn]);
            self.persons.rows += 1;
            self.persons.count += 1;
            try self.flushKind(&self.persons, .persons, false);
        }
        i = 0;
        while (i < self.liq_form.free_text_count) : (i += 1) {
            const fn_ = parse.formatLiqFreeTextRow(&self.row_buf, &self.liq_form, i);
            try self.disqualifications.buf.appendSlice(self.allocator, self.row_buf[0..fn_]);
            self.disqualifications.rows += 1;
            self.disqualifications.count += 1;
            try self.flushKind(&self.disqualifications, .disqualifications, false);
        }
        self.liq_form.reset();
    }

    fn handleLiqLine(self: *Stream, row: []const u8) ParseError!void {
        switch (parse.classifyLiqLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != .liquidation) return error.UnsupportedFileType;
                self.header_seen = true;
                try self.ensureHeader(&self.companies, parse.liq_forms_header);
                try self.ensureHeader(&self.persons, parse.liq_practitioners_header);
                try self.ensureHeader(&self.disqualifications, parse.liq_free_text_header);
            },
            .trailer => {
                try self.emitLiqFormToBuffers();
                self.trailer_count = parse.parseTrailerCount(row);
                self.saw_trailer = true;
            },
            .form => {
                try self.emitLiqFormToBuffers();
                self.liq_form.applyRecord(row);
                self.liq_data_records += 1;
            },
            .data => {
                self.liq_form.applyRecord(row);
                self.liq_data_records += 1;
            },
            .other => {},
        }
    }

    fn handleDisqualLine(self: *Stream, row: []const u8) ParseError!void {
        switch (parse.classifyDisqualLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != .disqualifications) return error.UnsupportedFileType;
                self.header_seen = true;
                try self.ensureHeader(&self.persons, parse.disqual_persons_header);
                try self.ensureHeader(&self.disqualifications, parse.disqualifications_header);
                try self.ensureHeader(&self.exemptions, parse.exemptions_header);
                try self.ensureHeader(&self.variations, parse.variations_header);
            },
            .trailer => {
                const tr = parse.parseDisqualTrailer(row) catch return error.MissingTrailer;
                self.disqual_trailer = tr;
                self.trailer_count = tr.total;
                self.saw_trailer = true;
            },
            .person => {
                try self.ensureHeader(&self.persons, parse.disqual_persons_header);
                const n = parse.formatDisqualPersonRow(&self.row_buf, row);
                try self.persons.buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.persons.rows += 1;
                self.persons.count += 1;
                try self.flushKind(&self.persons, .persons, false);
            },
            .disqualification => {
                try self.ensureHeader(&self.disqualifications, parse.disqualifications_header);
                const n = parse.formatDisqualificationRow(&self.row_buf, row);
                try self.disqualifications.buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.disqualifications.rows += 1;
                self.disqualifications.count += 1;
                try self.flushKind(&self.disqualifications, .disqualifications, false);
            },
            .exemption => {
                try self.ensureHeader(&self.exemptions, parse.exemptions_header);
                const n = parse.formatExemptionRow(&self.row_buf, row);
                try self.exemptions.buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.exemptions.rows += 1;
                self.exemptions.count += 1;
                try self.flushKind(&self.exemptions, .exemptions, false);
            },
            .variation => {
                try self.ensureHeader(&self.variations, parse.variations_header);
                const n = parse.formatVariationRow(&self.row_buf, row);
                try self.variations.buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.variations.rows += 1;
                self.variations.count += 1;
                try self.flushKind(&self.variations, .variations, false);
            },
            .other => {},
        }
    }

    fn ensureHeader(self: *Stream, kind: *KindBuf, header: []const u8) ParseError!void {
        if (kind.header_written) return;
        try kind.buf.appendSlice(self.allocator, header);
        kind.header_written = true;
    }

    fn shouldFlush(self: *const Stream, rows: usize, bytes: usize, force: bool) bool {
        if (force) return bytes > 0;
        if (rows >= self.config.batch_rows) return true;
        if (bytes >= self.config.batch_bytes) return true;
        return false;
    }

    fn flushKind(self: *Stream, kind: *KindBuf, batch_kind: BatchKind, force: bool) ParseError!void {
        if (!self.shouldFlush(kind.rows, kind.buf.items.len, force)) return;
        const data = try kind.buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(data);
        const rows: i32 = @intCast(kind.rows);
        kind.rows = 0;
        try self.ready.append(self.allocator, .{
            .data = data,
            .row_count = rows,
            .kind = batch_kind,
        });
    }
};
