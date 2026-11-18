//! Ordered chunk pipeline for officers products (Prod 195 / 216 / 198).
//!
//! One reader thread cuts the input into chunks of about `chunk_len` bytes
//! that always end just before a record start, so a record split across lines
//! by an embedded line break (see `parse.RecordJoiner`) never straddles two
//! chunks. Worker threads format chunks into in-memory CSV. The calling thread
//! writes finished chunks to the final outputs strictly in input order.
//!
//! Chunks live in a ring of `workers + 2` slots, so memory stays bounded
//! (about two chunks' worth of input + CSV per slot) whatever the input size,
//! and output goes straight to the final files: there are no per-worker part
//! files to concatenate afterwards. The input is any `Io.Reader`, read once,
//! front to back, so the same pipeline serves seekable files and streams.

const std = @import("std");
const Io = std.Io;
const Thread = std.Thread;
const parse = @import("parse.zig");

/// Input bytes per chunk. Small enough that `workers + 2` slots stay cheap at
/// 32 workers, large enough that per-chunk hand-off cost is negligible.
pub const default_chunk_len: usize = 1024 * 1024;
/// A chunk grows past `chunk_len` only when no record start fits in it.
const max_chunk_len: usize = 64 * 1024 * 1024;

pub const Options = struct {
    workers: usize,
    chunk_len: usize = default_chunk_len,
};

pub const Result = struct {
    companies: i32 = 0,
    persons: i32 = 0,
    trailer_count: ?i32 = null,
    /// First error in input order (parse error, or input read failure).
    err: ?anyerror = null,
    detail_buf: [256]u8 = undefined,
    detail_len: usize = 0,

    /// Location of `err` (`byte offset N: "…"`), empty when unknown.
    pub fn detail(self: *const Result) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

const SlotState = enum { free, filled, done };

const Slot = struct {
    state: SlotState = .free,
    index: u64 = 0,
    /// Input offset of `input[0]`.
    base_offset: u64 = 0,
    input: std.ArrayList(u8) = .empty,
    companies: std.ArrayList(u8) = .empty,
    persons: std.ArrayList(u8) = .empty,
    n_companies: i32 = 0,
    n_persons: i32 = 0,
    trailer_count: ?i32 = null,
    /// Location of the first non-blank line (for data after a trailer that
    /// sits in an earlier chunk).
    first_content: ?u64 = null,
    first_content_detail: [256]u8 = undefined,
    first_content_len: usize = 0,
    err: ?anyerror = null,
    err_detail: [256]u8 = undefined,
    err_detail_len: usize = 0,

    fn resetOutputs(self: *Slot) void {
        self.companies.clearRetainingCapacity();
        self.persons.clearRetainingCapacity();
        self.n_companies = 0;
        self.n_persons = 0;
        self.trailer_count = null;
        self.first_content = null;
        self.first_content_len = 0;
        self.err = null;
        self.err_detail_len = 0;
    }

    fn deinit(self: *Slot, gpa: std.mem.Allocator) void {
        self.input.deinit(gpa);
        self.companies.deinit(gpa);
        self.persons.deinit(gpa);
    }

    fn fail(self: *Slot, err: anyerror, offset: u64, row: []const u8) anyerror {
        self.err_detail_len = parse.describeLineAt(&self.err_detail, "byte offset", offset, row).len;
        return err;
    }
};

const Pipeline = struct {
    io: Io,
    gpa: std.mem.Allocator,
    file_type: parse.FileType,
    chunk_len: usize,
    slots: []Slot,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Next chunk index a worker should take.
    next_work: u64 = 0,
    /// Number of chunks, known once the reader reaches end of input.
    total_chunks: ?u64 = null,
    /// Set on the first error; every thread stops at its next hand-off.
    failed: bool = false,
    reader_err: ?anyerror = null,

    fn slotFor(self: *Pipeline, index: u64) *Slot {
        return &self.slots[@intCast(index % self.slots.len)];
    }

    fn lock(self: *Pipeline) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Pipeline) void {
        self.mutex.unlock(self.io);
    }

    fn wait(self: *Pipeline) void {
        self.cond.waitUncancelable(self.io, &self.mutex);
    }

    fn wakeAll(self: *Pipeline) void {
        self.cond.broadcast(self.io);
    }

    fn abort(self: *Pipeline) void {
        self.lock();
        self.failed = true;
        self.wakeAll();
        self.unlock();
    }

    // --- Reader ---------------------------------------------------------------

    fn readerMain(self: *Pipeline, reader: *Io.Reader) void {
        self.readAll(reader) catch |err| {
            self.lock();
            self.reader_err = err;
            self.failed = true;
            self.wakeAll();
            self.unlock();
        };
    }

    fn readAll(self: *Pipeline, reader: *Io.Reader) !void {
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(self.gpa);
        var offset: u64 = 0;
        var index: u64 = 0;

        while (true) {
            const slot = self.slotFor(index);
            self.lock();
            while (slot.state != .free and !self.failed) self.wait();
            const stop = self.failed;
            self.unlock();
            if (stop) return;

            slot.input.clearRetainingCapacity();
            try slot.input.appendSlice(self.gpa, carry.items);
            carry.clearRetainingCapacity();

            var target = @max(self.chunk_len, slot.input.items.len);
            var eof = false;
            while (true) {
                if (slot.input.items.len < target) {
                    try slot.input.ensureTotalCapacity(self.gpa, target);
                    const dest = slot.input.unusedCapacitySlice()[0 .. target - slot.input.items.len];
                    const n = try reader.readSliceShort(dest);
                    slot.input.items.len += n;
                    if (n < dest.len) eof = true;
                }
                if (eof) break;
                if (chunkEnd(slot.input.items)) |end| {
                    try carry.appendSlice(self.gpa, slot.input.items[end..]);
                    slot.input.items.len = end;
                    break;
                }
                // No record start fits: grow the chunk (pathological input).
                if (target >= max_chunk_len) return error.RowTooLarge;
                target *= 2;
            }

            const empty = slot.input.items.len == 0;
            self.lock();
            if (!empty) {
                slot.index = index;
                slot.base_offset = offset;
                slot.resetOutputs();
                slot.state = .filled;
                offset += slot.input.items.len;
                index += 1;
            }
            if (eof) self.total_chunks = index;
            self.wakeAll();
            self.unlock();
            if (eof) return;
        }
    }

    // --- Workers --------------------------------------------------------------

    fn workerMain(self: *Pipeline) void {
        const joiner = self.gpa.create(parse.RecordJoiner) catch {
            self.abort();
            return;
        };
        defer self.gpa.destroy(joiner);

        while (true) {
            self.lock();
            const slot = while (true) {
                if (self.failed) break null;
                const j = self.next_work;
                if (self.total_chunks) |total| if (j >= total) break null;
                const s = self.slotFor(j);
                if (s.state == .filled and s.index == j) {
                    self.next_work += 1;
                    break s;
                }
                self.wait();
            };
            self.unlock();
            const s = slot orelse return;

            joiner.* = .{};
            self.formatChunk(s, joiner) catch |err| {
                s.err = err;
            };

            self.lock();
            s.state = .done;
            self.wakeAll();
            self.unlock();
        }
    }

    /// Format every line of one chunk. Mirrors the per-line rules of the
    /// sequential stream path for officers products.
    fn formatChunk(self: *Pipeline, slot: *Slot, joiner: *parse.RecordJoiner) !void {
        const buf = slot.input.items;
        var pos: usize = 0;
        while (pos < buf.len) {
            const nl = std.mem.indexOfScalarPos(u8, buf, pos, '\n');
            const line_raw = buf[pos .. nl orelse buf.len];
            const line_off = slot.base_offset + pos;
            pos = if (nl) |n| n + 1 else buf.len;

            const row = parse.stripCr(line_raw);
            if (row.len == 0) continue;

            if (slot.first_content == null and !isBlank(row)) {
                slot.first_content = line_off;
                slot.first_content_len = parse.describeLineAt(&slot.first_content_detail, "byte offset", line_off, row).len;
            }

            if (slot.trailer_count != null) {
                if (!isBlank(row)) return slot.fail(error.FeedAfterTrailer, line_off, row);
                continue;
            }

            const kind = parse.classifyLine(row);

            if (joiner.active) {
                if (kind == .other) {
                    const done = joiner.append(row, parse.lineBreakLen(line_raw)) catch |err| {
                        return slot.fail(switch (err) {
                            error.RowTooLarge => error.RowTooLarge,
                            error.JoinOverrun => error.UnknownRecord,
                        }, line_off, row);
                    };
                    if (done) {
                        try self.appendRecord(slot, joiner.kind, joiner.record());
                        joiner.reset();
                    }
                    continue;
                }
                try self.appendRecord(slot, joiner.kind, joiner.record());
                joiner.reset();
            }

            switch (kind) {
                .header => {
                    // Only the file's first line may be a header.
                    if (line_off != 0) return slot.fail(error.UnknownRecord, line_off, row);
                },
                .trailer => slot.trailer_count = parse.parseTrailerCount(row),
                .company, .person => {
                    const end = parse.officersDeclaredEnd(row, kind, self.file_type).?;
                    if (parse.isShortOf(row, end)) {
                        const field = parse.officersLengthField(kind, self.file_type).?;
                        joiner.begin(row, kind, field, end, parse.lineBreakLen(line_raw), line_off) catch |err| {
                            return slot.fail(err, line_off, row);
                        };
                    } else {
                        self.appendRecord(slot, kind, row) catch |err| return slot.fail(err, line_off, row);
                    }
                },
                .other => return slot.fail(error.UnknownRecord, line_off, row),
            }
        }
        // Chunks end before a record start, so a held record is complete (or
        // legitimately short) here.
        if (joiner.active) {
            const start = joiner.start_line;
            self.appendRecord(slot, joiner.kind, joiner.record()) catch |err| {
                return slot.fail(err, start, joiner.record());
            };
            joiner.reset();
        }
    }

    fn appendRecord(self: *Pipeline, slot: *Slot, kind: parse.LineKind, row: []const u8) !void {
        const list = switch (kind) {
            .company => &slot.companies,
            .person => &slot.persons,
            .header, .trailer, .other => unreachable,
        };
        try list.ensureUnusedCapacity(self.gpa, parse.max_csv_row_bytes);
        const dest = list.unusedCapacitySlice()[0..parse.max_csv_row_bytes];
        const n = switch (kind) {
            .company => try parse.formatCompanyRow(dest, row),
            .person => switch (self.file_type) {
                .officers_snapshot => try parse.formatPersonRow(dest, row),
                .officers_update => try parse.formatUpdatePersonRow(dest, row),
                .disqualifications, .liquidation => return error.NotImplemented,
            },
            .header, .trailer, .other => unreachable,
        };
        list.items.len += n;
        switch (kind) {
            .company => slot.n_companies += 1,
            .person => slot.n_persons += 1,
            .header, .trailer, .other => unreachable,
        }
    }

    // --- Writer (calling thread) ----------------------------------------------

    fn writeAll(self: *Pipeline, companies_out: *Io.Writer, persons_out: *Io.Writer, result: *Result) !void {
        var index: u64 = 0;
        var trailer_seen = false;
        while (true) {
            const slot = self.slotFor(index);
            self.lock();
            while (true) {
                if (slot.state == .done and slot.index == index) break;
                if (self.total_chunks) |total| if (index >= total) break;
                if (self.reader_err != null) break;
                self.wait();
            }
            const ready = slot.state == .done and slot.index == index;
            const reader_err = self.reader_err;
            self.unlock();

            if (!ready) {
                // End of input, or the reader failed before this chunk.
                if (reader_err) |err| result.err = err;
                return;
            }

            if (slot.err) |err| {
                result.err = err;
                @memcpy(result.detail_buf[0..slot.err_detail_len], slot.err_detail[0..slot.err_detail_len]);
                result.detail_len = slot.err_detail_len;
                return;
            }
            if (trailer_seen and slot.first_content != null) {
                result.err = error.FeedAfterTrailer;
                @memcpy(result.detail_buf[0..slot.first_content_len], slot.first_content_detail[0..slot.first_content_len]);
                result.detail_len = slot.first_content_len;
                return;
            }

            try companies_out.writeAll(slot.companies.items);
            try persons_out.writeAll(slot.persons.items);
            result.companies += slot.n_companies;
            result.persons += slot.n_persons;
            if (slot.trailer_count) |tc| {
                result.trailer_count = tc;
                trailer_seen = true;
            }

            self.lock();
            slot.state = .free;
            self.wakeAll();
            self.unlock();
            index += 1;
        }
    }
};

fn isBlank(row: []const u8) bool {
    for (row) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

/// Offset where a chunk of `buf` should end: the start of the last complete
/// line in `buf` that begins a record (header, trailer, company or person),
/// excluding offset 0. Null when there is none.
fn chunkEnd(buf: []const u8) ?usize {
    var end = std.mem.lastIndexOfScalar(u8, buf, '\n') orelse return null;
    while (true) {
        const start = if (std.mem.lastIndexOfScalar(u8, buf[0..end], '\n')) |p| p + 1 else 0;
        if (start == 0) return null;
        if (parse.classifyLine(parse.stripCr(buf[start..end])) != .other) return start;
        end = start - 1;
    }
}

/// Convert an officers product from `reader` (positioned at the start of the
/// file, header included) into company and person CSV rows, written in input
/// order to `companies_out` / `persons_out` (CSV headers are the caller's).
/// Parse errors are returned in `Result.err`; output write errors are returned.
pub fn run(
    io: Io,
    gpa: std.mem.Allocator,
    reader: *Io.Reader,
    file_type: parse.FileType,
    companies_out: *Io.Writer,
    persons_out: *Io.Writer,
    options: Options,
) !Result {
    std.debug.assert(file_type == .officers_snapshot or file_type == .officers_update);
    const workers = @max(1, options.workers);
    const slots = try gpa.alloc(Slot, workers + 2);
    defer gpa.free(slots);
    for (slots) |*s| s.* = .{};
    defer for (slots) |*s| s.deinit(gpa);

    var p: Pipeline = .{
        .io = io,
        .gpa = gpa,
        .file_type = file_type,
        .chunk_len = @max(1, options.chunk_len),
        .slots = slots,
    };

    var result: Result = .{};
    const threads = try gpa.alloc(Thread, workers);
    defer gpa.free(threads);
    var spawned: usize = 0;

    const reader_thread = try Thread.spawn(.{}, Pipeline.readerMain, .{ &p, reader });
    defer reader_thread.join();
    // Stop and join every thread before returning, on success or error.
    defer {
        p.abort();
        for (threads[0..spawned]) |t| t.join();
    }
    while (spawned < workers) : (spawned += 1) {
        threads[spawned] = try Thread.spawn(.{}, Pipeline.workerMain, .{&p});
    }

    try p.writeAll(companies_out, persons_out, &result);
    return result;
}

test "chunkEnd returns the last complete record-start line" {
    const t = std.testing;
    const a = "DDDDSNAP434220261102\n" ++
        "012345671D                      00020024EXAMPLE TRADING LIMITED<\n" ++
        "012345672102123480258001        20200101        AB1 2CD 197501          0003A<B\n" ++
        "continuation line\n" ++
        "partial line without newline";
    // Last complete line is a continuation, so the chunk ends before the person.
    try t.expectEqual(@as(?usize, std.mem.indexOf(u8, a, "012345672").?), chunkEnd(a));
    // Only the header precedes: nothing to split on except offset 0.
    try t.expectEqual(@as(?usize, null), chunkEnd("DDDDSNAP434220261102\nabc"));
    try t.expectEqual(@as(?usize, null), chunkEnd("no newline at all"));
}
