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
//! - Batch kinds are `parse.OutputKind` — product-specific names, never overloaded.
//! - Per-kind buffers are indexed by `OutputKind.index()` (array, not named fields).

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
    /// Formatted CSV row does not fit in `max_csv_row_bytes`.
    RowTooLarge,
    /// Prod 197 form group exceeded max practitioners or free-text lines.
    RecordLimitExceeded,
    /// Unknown record type byte / unclassified body line (non-197 products).
    UnknownRecord,
    /// A tagged field was longer than its slot capacity.
    FieldOverflow,
};

/// Streaming batch kind — same values as `parse.OutputKind` / C `CH_OUTPUT_*`.
pub const BatchKind = parse.OutputKind;

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
    /// One open CSV buffer per `OutputKind` (indexed by `kind.index()`).
    kinds: [parse.OutputKind.all.len]KindBuf = [_]KindBuf{.{}} ** parse.OutputKind.all.len,

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

    /// Non-fatal diagnostics (e.g. unknown Prod 197 tags). Hard errors still fail the run.
    warning_count: i32 = 0,
    last_warning: [256]u8 = [_]u8{0} ** 256,
    warn_fn: ?*const fn (ctx: ?*anyopaque, message: []const u8) void = null,
    warn_ctx: ?*anyopaque = null,

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
        for (&self.kinds) |*kb| kb.buf.deinit(self.allocator);
        for (self.ready.items) |*b| b.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn kindBuf(self: *Stream, kind: BatchKind) *KindBuf {
        return &self.kinds[kind.index()];
    }

    pub fn countOf(self: *const Stream, kind: BatchKind) i32 {
        return self.kinds[kind.index()].count;
    }

    /// Optional callback invoked for every warning (CLI prints to stderr).
    /// `warning_count` / `last_warning` are always updated.
    pub fn setWarnHandler(
        self: *Stream,
        func: ?*const fn (ctx: ?*anyopaque, message: []const u8) void,
        ctx: ?*anyopaque,
    ) void {
        self.warn_fn = func;
        self.warn_ctx = ctx;
    }

    pub fn lastWarningSlice(self: *const Stream) []const u8 {
        return std.mem.sliceTo(&self.last_warning, 0);
    }

    pub fn warn(self: *Stream, message: []const u8) void {
        self.warning_count += 1;
        self.last_warning = [_]u8{0} ** 256;
        const n = @min(message.len, self.last_warning.len - 1);
        if (n > 0) @memcpy(self.last_warning[0..n], message[0..n]);
        if (self.warn_fn) |f| f(self.warn_ctx, message);
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
        for (ft.outputKinds()) |kind| {
            try self.ensureHeader(kind, ft.csvHeader(kind));
            try self.flushKind(kind, true);
        }

        self.finished = true;

        const tc = self.trailer_count orelse return error.MissingTrailer;
        switch (ft) {
            .officers_snapshot, .officers_update => {
                if (tc != self.countOf(.companies) + self.countOf(.persons)) return error.TrailerMismatch;
            },
            .disqualifications => {
                const tr = self.disqual_trailer orelse return error.MissingTrailer;
                if (tr.type1 != self.countOf(.persons) or
                    tr.type2 != self.countOf(.disqualifications) or
                    tr.type3 != self.countOf(.exemptions) or
                    tr.type4 != self.countOf(.variations) or
                    tr.total != tc)
                {
                    return error.TrailerMismatch;
                }
                if (tc != self.countOf(.persons) + self.countOf(.disqualifications) +
                    self.countOf(.exemptions) + self.countOf(.variations))
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

    /// Ensure CSV header for `kind`, append one formatted row, bump counts, maybe flush.
    fn appendFormattedRow(
        self: *Stream,
        kind: BatchKind,
        header: []const u8,
        n: usize,
    ) ParseError!void {
        try self.ensureHeader(kind, header);
        const kb = self.kindBuf(kind);
        try kb.buf.appendSlice(self.allocator, self.row_buf[0..n]);
        kb.rows += 1;
        kb.count += 1;
        try self.flushKind(kind, false);
    }

    fn handleOfficersLine(self: *Stream, row: []const u8, file_type: parse.FileType) ParseError!void {
        switch (parse.classifyLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != file_type) return error.UnsupportedFileType;
                self.header_seen = true;
                try self.ensureHeader(.companies, parse.companies_header);
                try self.ensureHeader(.persons, file_type.personsCsvHeader());
            },
            .trailer => {
                self.trailer_count = parse.parseTrailerCount(row);
                self.saw_trailer = true;
            },
            .company => {
                const n = parse.formatCompanyRow(&self.row_buf, row) catch return error.RowTooLarge;
                try self.appendFormattedRow(.companies, parse.companies_header, n);
            },
            .person => {
                const n = switch (file_type) {
                    .officers_snapshot => parse.formatPersonRow(&self.row_buf, row),
                    .officers_update => parse.formatUpdatePersonRow(&self.row_buf, row),
                    .disqualifications, .liquidation => unreachable,
                } catch return error.RowTooLarge;
                try self.appendFormattedRow(.persons, file_type.personsCsvHeader(), n);
            },
            .other => return error.UnknownRecord,
        }
    }

    fn emitLiqFormToBuffers(self: *Stream) ParseError!void {
        if (!self.liq_form.active) return;
        try self.ensureHeader(.forms, parse.liq_forms_header);
        try self.ensureHeader(.practitioners, parse.liq_practitioners_header);
        try self.ensureHeader(.free_text, parse.liq_free_text_header);

        const n = parse.formatLiqFormRow(&self.row_buf, &self.liq_form) catch return error.RowTooLarge;
        try self.appendFormattedRow(.forms, parse.liq_forms_header, n);

        var i: usize = 0;
        while (i < self.liq_form.practitioner_count) : (i += 1) {
            const pn = parse.formatLiqPractitionerRow(&self.row_buf, &self.liq_form, i) catch return error.RowTooLarge;
            try self.appendFormattedRow(.practitioners, parse.liq_practitioners_header, pn);
        }
        i = 0;
        while (i < self.liq_form.free_text_count) : (i += 1) {
            const fn_ = parse.formatLiqFreeTextRow(&self.row_buf, &self.liq_form, i) catch return error.RowTooLarge;
            try self.appendFormattedRow(.free_text, parse.liq_free_text_header, fn_);
        }
        self.liq_form.reset();
    }

    fn applyLiqRecord(self: *Stream, row: []const u8) ParseError!void {
        const outcome = self.liq_form.applyRecord(row) catch |err| switch (err) {
            error.RecordLimitExceeded => return error.RecordLimitExceeded,
            error.FieldOverflow => return error.FieldOverflow,
        };
        if (outcome == .unknown_tag) self.warnLiqUnknown(row);
        self.liq_data_records += 1;
    }

    fn warnLiqUnknown(self: *Stream, row: []const u8) void {
        const tag = if (row.len >= 2) row[0..2] else row;
        const form = self.liq_form.formNumber();
        const company = self.liq_form.companyNumber();
        var buf: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "unknown tag {s} on form {s} company {s}", .{
            tag,
            if (form.len == 0) "-" else form,
            if (company.len == 0) "-" else company,
        }) catch "unknown tag";
        self.warn(msg);
    }

    fn handleLiqLine(self: *Stream, row: []const u8) ParseError!void {
        switch (parse.classifyLiqLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != .liquidation) return error.UnsupportedFileType;
                self.header_seen = true;
                try self.ensureHeader(.forms, parse.liq_forms_header);
                try self.ensureHeader(.practitioners, parse.liq_practitioners_header);
                try self.ensureHeader(.free_text, parse.liq_free_text_header);
            },
            .trailer => {
                try self.emitLiqFormToBuffers();
                self.trailer_count = parse.parseTrailerCount(row);
                self.saw_trailer = true;
            },
            .form => {
                try self.emitLiqFormToBuffers();
                try self.applyLiqRecord(row);
            },
            .data => {
                try self.applyLiqRecord(row);
            },
            .other => return error.UnknownRecord,
        }
    }

    fn handleDisqualLine(self: *Stream, row: []const u8) ParseError!void {
        switch (parse.classifyDisqualLine(row)) {
            .header => {
                const info = parse.parseHeader(row) catch return error.UnsupportedFileType;
                if (info.file_type != .disqualifications) return error.UnsupportedFileType;
                self.header_seen = true;
                try self.ensureHeader(.persons, parse.disqual_persons_header);
                try self.ensureHeader(.disqualifications, parse.disqualifications_header);
                try self.ensureHeader(.exemptions, parse.exemptions_header);
                try self.ensureHeader(.variations, parse.variations_header);
            },
            .trailer => {
                const tr = parse.parseDisqualTrailer(row) catch return error.MissingTrailer;
                self.disqual_trailer = tr;
                self.trailer_count = tr.total;
                self.saw_trailer = true;
            },
            .person => {
                const n = parse.formatDisqualPersonRow(&self.row_buf, row) catch return error.RowTooLarge;
                try self.appendFormattedRow(.persons, parse.disqual_persons_header, n);
            },
            .disqualification => {
                const n = parse.formatDisqualificationRow(&self.row_buf, row) catch return error.RowTooLarge;
                try self.appendFormattedRow(.disqualifications, parse.disqualifications_header, n);
            },
            .exemption => {
                const n = parse.formatExemptionRow(&self.row_buf, row) catch return error.RowTooLarge;
                try self.appendFormattedRow(.exemptions, parse.exemptions_header, n);
            },
            .variation => {
                const n = parse.formatVariationRow(&self.row_buf, row) catch return error.RowTooLarge;
                try self.appendFormattedRow(.variations, parse.variations_header, n);
            },
            .other => return error.UnknownRecord,
        }
    }

    fn ensureHeader(self: *Stream, kind: BatchKind, header: []const u8) ParseError!void {
        const kb = self.kindBuf(kind);
        if (kb.header_written) return;
        try kb.buf.appendSlice(self.allocator, header);
        kb.header_written = true;
    }

    fn shouldFlush(self: *const Stream, rows: usize, bytes: usize, force: bool) bool {
        if (force) return bytes > 0;
        if (rows >= self.config.batch_rows) return true;
        if (bytes >= self.config.batch_bytes) return true;
        return false;
    }

    fn flushKind(self: *Stream, kind: BatchKind, force: bool) ParseError!void {
        const kb = self.kindBuf(kind);
        if (!self.shouldFlush(kb.rows, kb.buf.items.len, force)) return;
        const data = try kb.buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(data);
        const rows: i32 = @intCast(kb.rows);
        kb.rows = 0;
        try self.ready.append(self.allocator, .{
            .data = data,
            .row_count = rows,
            .kind = kind,
        });
    }
};
