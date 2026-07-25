//! Incremental snapshot → CSV conversion for hosts that cannot hold the full
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
    MissingTrailer,
    TrailerMismatch,
    OutOfMemory,
    AlreadyFinished,
    FeedAfterTrailer,
};

pub const BatchKind = enum(i32) {
    companies = 0,
    persons = 1,
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

pub const Stream = struct {
    allocator: std.mem.Allocator,
    config: StreamConfig,

    carry: std.ArrayList(u8) = .empty,
    companies_buf: std.ArrayList(u8) = .empty,
    persons_buf: std.ArrayList(u8) = .empty,
    companies_rows: usize = 0,
    persons_rows: usize = 0,
    companies_header_written: bool = false,
    persons_header_written: bool = false,

    ready: std.ArrayList(CsvBatch) = .empty,

    companies: i32 = 0,
    persons: i32 = 0,
    trailer_count: ?i32 = null,
    header_seen: bool = false,
    finished: bool = false,
    saw_trailer: bool = false,

    /// First bytes of the input stream; must form `DDDDSNAP` once 8 are seen.
    magic: [parse.snapshot_header_identifier.len]u8 = undefined,
    magic_len: u8 = 0,

    row_buf: [parse.max_csv_row_bytes]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, config: StreamConfig) Stream {
        return .{
            .allocator = allocator,
            .config = config.resolved(),
        };
    }

    pub fn deinit(self: *Stream) void {
        self.carry.deinit(self.allocator);
        self.companies_buf.deinit(self.allocator);
        self.persons_buf.deinit(self.allocator);
        for (self.ready.items) |*b| b.deinit(self.allocator);
        self.ready.deinit(self.allocator);
        self.* = undefined;
    }

    /// Feed the next chunk of snapshot bytes. Drain with `nextBatch` afterward.
    /// The overall input must begin with `DDDDSNAP` (checked once the first
    /// 8 bytes have arrived).
    pub fn feed(self: *Stream, chunk: []const u8) ParseError!void {
        if (self.finished) return error.AlreadyFinished;
        if (self.saw_trailer) {
            if (chunk.len == 0) return;
            // Allow trailing whitespace/newlines after trailer; reject real data.
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
                // Remainder of this chunk after trailer.
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

    /// Signal end of input: flush carry line, open batches, validate trailer.
    pub fn finish(self: *Stream) ParseError!void {
        if (self.finished) return error.AlreadyFinished;

        // Incomplete or missing snapshot signature.
        if (self.magic_len < parse.snapshot_header_identifier.len) {
            return error.UnsupportedFileType;
        }

        if (!self.saw_trailer and self.carry.items.len > 0) {
            try self.handleLine(self.carry.items);
            self.carry.clearRetainingCapacity();
        } else {
            self.carry.clearRetainingCapacity();
        }

        // Ensure empty outputs still get CSV headers (matches CLI behaviour).
        try self.ensureCompaniesHeader();
        try self.ensurePersonsHeader();
        try self.flushCompanies(true);
        try self.flushPersons(true);

        self.finished = true;

        const tc = self.trailer_count orelse return error.MissingTrailer;
        if (tc != self.companies + self.persons) return error.TrailerMismatch;
    }

    /// Collect the leading bytes of the stream and require `DDDDSNAP`.
    fn ingestMagic(self: *Stream, data: []const u8) ParseError!void {
        const need = parse.snapshot_header_identifier.len;
        if (self.magic_len >= need) return;

        const take = @min(need - self.magic_len, data.len);
        if (take == 0) return;
        @memcpy(self.magic[self.magic_len ..][0..take], data[0..take]);
        self.magic_len += @intCast(take);

        if (self.magic_len < need) return;
        if (!std.mem.eql(u8, self.magic[0..need], parse.snapshot_header_identifier)) {
            return error.UnsupportedFileType;
        }
    }

    /// Pop the next completed CSV batch (caller owns `data`). Null if none.
    pub fn nextBatch(self: *Stream) ?CsvBatch {
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    fn handleLine(self: *Stream, line_raw: []const u8) ParseError!void {
        const row = parse.stripCr(line_raw);
        if (row.len == 0) return;

        switch (parse.classifyLine(row)) {
            .header => {
                _ = parse.parseHeader(row) catch return error.UnsupportedFileType;
                self.header_seen = true;
                try self.ensureCompaniesHeader();
                try self.ensurePersonsHeader();
            },
            .trailer => {
                self.trailer_count = parse.parseTrailerCount(row);
                self.saw_trailer = true;
            },
            .company => {
                try self.ensureCompaniesHeader();
                const n = parse.formatCompanyRow(&self.row_buf, row);
                try self.companies_buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.companies_rows += 1;
                self.companies += 1;
                try self.flushCompanies(false);
            },
            .person => {
                try self.ensurePersonsHeader();
                const n = parse.formatPersonRow(&self.row_buf, row);
                try self.persons_buf.appendSlice(self.allocator, self.row_buf[0..n]);
                self.persons_rows += 1;
                self.persons += 1;
                try self.flushPersons(false);
            },
            .other => {},
        }
    }

    fn ensureCompaniesHeader(self: *Stream) ParseError!void {
        if (self.companies_header_written) return;
        try self.companies_buf.appendSlice(self.allocator, parse.companies_header);
        self.companies_header_written = true;
    }

    fn ensurePersonsHeader(self: *Stream) ParseError!void {
        if (self.persons_header_written) return;
        try self.persons_buf.appendSlice(self.allocator, parse.persons_header);
        self.persons_header_written = true;
    }

    fn shouldFlush(self: *const Stream, rows: usize, bytes: usize, force: bool) bool {
        if (force) return bytes > 0;
        if (rows >= self.config.batch_rows) return true;
        if (bytes >= self.config.batch_bytes) return true;
        return false;
    }

    fn flushCompanies(self: *Stream, force: bool) ParseError!void {
        if (!self.shouldFlush(self.companies_rows, self.companies_buf.items.len, force)) return;
        const data = try self.companies_buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(data);
        const rows: i32 = @intCast(self.companies_rows);
        self.companies_rows = 0;
        try self.ready.append(self.allocator, .{
            .data = data,
            .row_count = rows,
            .kind = .companies,
        });
    }

    fn flushPersons(self: *Stream, force: bool) ParseError!void {
        if (!self.shouldFlush(self.persons_rows, self.persons_buf.items.len, force)) return;
        const data = try self.persons_buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(data);
        const rows: i32 = @intCast(self.persons_rows);
        self.persons_rows = 0;
        try self.ready.append(self.allocator, .{
            .data = data,
            .row_count = rows,
            .kind = .persons,
        });
    }
};
