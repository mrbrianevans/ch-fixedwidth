//! C-compatible foreign function interface for snapshot parsing.
//! Also used as the export surface for freestanding WASM builds.
//!
//! Two modes:
//! - One-shot: `ch_parse_snapshot` (full document in / full CSVs out)
//! - Streaming: `ch_stream_*` (chunked input, batched CSV pull)

const std = @import("std");
const builtin = @import("builtin");
const snapshot = @import("snapshot.zig");
const stream_mod = @import("stream.zig");

/// Opaque heap buffer returned to C/WASM callers.
pub const ChBuffer = extern struct {
    data: ?[*]u8 = null,
    len: usize = 0,
};

pub const ChParseResult = extern struct {
    companies_csv: ChBuffer = .{},
    persons_csv: ChBuffer = .{},
    companies: i32 = 0,
    persons: i32 = 0,
    trailer_count: i32 = 0,
};

pub const ChStreamConfig = extern struct {
    /// 0 → default (1000 rows).
    batch_rows: usize = 0,
    /// 0 → default (256 KiB).
    batch_bytes: usize = 0,
};

pub const ChCsvBatch = extern struct {
    data: ?[*]u8 = null,
    len: usize = 0,
    row_count: i32 = 0,
    /// 0 = companies, 1 = persons
    kind: i32 = 0,
};

// Error codes for C callers (stable ABI).
pub const CH_OK: c_int = 0;
pub const CH_ERR_INVALID_ARG: c_int = 1;
pub const CH_ERR_UNSUPPORTED_HEADER: c_int = 2;
pub const CH_ERR_MISSING_TRAILER: c_int = 3;
pub const CH_ERR_TRAILER_MISMATCH: c_int = 4;
pub const CH_ERR_OUT_OF_MEMORY: c_int = 5;
pub const CH_ERR_INTERNAL: c_int = 6;
/// Stream already finished, or feed after trailer with non-whitespace data.
pub const CH_ERR_STREAM_STATE: c_int = 7;
/// Known product header, but no body parser is implemented yet.
pub const CH_ERR_NOT_IMPLEMENTED: c_int = 8;

fn gpa() std.mem.Allocator {
    if (comptime builtin.cpu.arch.isWasm()) {
        return std.heap.wasm_allocator;
    }
    return std.heap.smp_allocator;
}

fn mapStreamErr(err: stream_mod.ParseError) c_int {
    return switch (err) {
        error.UnsupportedFileType => CH_ERR_UNSUPPORTED_HEADER,
        error.NotImplemented => CH_ERR_NOT_IMPLEMENTED,
        error.MissingTrailer => CH_ERR_MISSING_TRAILER,
        error.TrailerMismatch => CH_ERR_TRAILER_MISMATCH,
        error.OutOfMemory => CH_ERR_OUT_OF_MEMORY,
        error.AlreadyFinished, error.FeedAfterTrailer => CH_ERR_STREAM_STATE,
    };
}

fn freeBuffer(buf: *ChBuffer) void {
    if (buf.data) |ptr| {
        if (buf.len > 0) {
            gpa().free(ptr[0..buf.len]);
        }
        buf.data = null;
        buf.len = 0;
    }
}

/// Free a buffer previously filled by `ch_parse_snapshot`.
pub export fn ch_buffer_free(buf: ?*ChBuffer) void {
    if (buf) |b| freeBuffer(b);
}

/// Free both CSV buffers in a parse result.
pub export fn ch_parse_result_free(result: ?*ChParseResult) void {
    if (result) |r| {
        freeBuffer(&r.companies_csv);
        freeBuffer(&r.persons_csv);
        r.companies = 0;
        r.persons = 0;
        r.trailer_count = 0;
    }
}

/// Parse an in-memory Companies House snapshot into two CSV documents.
///
/// On success (`CH_OK`), `out` owns two heap buffers; free with
/// `ch_parse_result_free` or `ch_buffer_free` on each field.
///
/// Does not perform filesystem I/O. For multi-hundred-MB files prefer `ch_stream_*`.
pub export fn ch_parse_snapshot(
    input: ?[*]const u8,
    input_len: usize,
    out: ?*ChParseResult,
) c_int {
    if (input == null or out == null) return CH_ERR_INVALID_ARG;
    if (input_len == 0) return CH_ERR_INVALID_ARG;

    const slice = input.?[0..input_len];
    const result = out.?;

    // Clear any previous contents without freeing caller memory we don't own.
    result.* = .{};

    const parsed = snapshot.parseSnapshot(gpa(), slice) catch |err| {
        return switch (err) {
            error.UnsupportedFileType => CH_ERR_UNSUPPORTED_HEADER,
            error.NotImplemented => CH_ERR_NOT_IMPLEMENTED,
            error.MissingTrailer => CH_ERR_MISSING_TRAILER,
            error.TrailerMismatch => CH_ERR_TRAILER_MISMATCH,
            error.OutOfMemory => CH_ERR_OUT_OF_MEMORY,
        };
    };

    result.companies_csv = .{
        .data = parsed.companies_csv.ptr,
        .len = parsed.companies_csv.len,
    };
    result.persons_csv = .{
        .data = parsed.persons_csv.ptr,
        .len = parsed.persons_csv.len,
    };
    result.companies = parsed.companies;
    result.persons = parsed.persons;
    result.trailer_count = parsed.trailer_count;
    return CH_OK;
}

/// Allocate `size` bytes for host-side use (e.g. WASM hosts copying input in).
pub export fn ch_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const mem = gpa().alloc(u8, size) catch return null;
    return mem.ptr;
}

/// Free memory returned by `ch_alloc`.
pub export fn ch_free(ptr: ?[*]u8, size: usize) void {
    if (ptr) |p| {
        if (size > 0) gpa().free(p[0..size]);
    }
}

// --- Streaming API -----------------------------------------------------------

/// Create a stream parser. `config` may be NULL (defaults: 1000 rows / 256 KiB).
/// Free with `ch_stream_destroy`.
pub export fn ch_stream_create(config: ?*const ChStreamConfig) ?*stream_mod.Stream {
    const cfg: stream_mod.StreamConfig = if (config) |c| .{
        .batch_rows = c.batch_rows,
        .batch_bytes = c.batch_bytes,
    } else .{};

    const s = gpa().create(stream_mod.Stream) catch return null;
    s.* = stream_mod.Stream.init(gpa(), cfg);
    return s;
}

/// Destroy a stream and any undrained batches / buffers.
pub export fn ch_stream_destroy(s: ?*stream_mod.Stream) void {
    if (s) |stream| {
        stream.deinit();
        gpa().destroy(stream);
    }
}

/// Feed the next input chunk (any size; need not end on a newline).
/// Drain with `ch_stream_next_batch` after each successful feed.
pub export fn ch_stream_feed(s: ?*stream_mod.Stream, data: ?[*]const u8, len: usize) c_int {
    if (s == null) return CH_ERR_INVALID_ARG;
    if (len > 0 and data == null) return CH_ERR_INVALID_ARG;
    const slice: []const u8 = if (len == 0) &.{} else data.?[0..len];
    s.?.feed(slice) catch |err| return mapStreamErr(err);
    return CH_OK;
}

/// End of input: flush open batches and validate trailer count.
pub export fn ch_stream_finish(s: ?*stream_mod.Stream) c_int {
    if (s == null) return CH_ERR_INVALID_ARG;
    s.?.finish() catch |err| return mapStreamErr(err);
    return CH_OK;
}

/// Pop one completed CSV batch into `out`.
/// Returns 1 if a batch was written, 0 if none pending, or a negative error code.
/// On 1, free with `ch_csv_batch_free`.
pub export fn ch_stream_next_batch(s: ?*stream_mod.Stream, out: ?*ChCsvBatch) c_int {
    if (s == null or out == null) return CH_ERR_INVALID_ARG;
    const batch = s.?.nextBatch() orelse {
        out.?.* = .{};
        return 0;
    };
    out.?.* = .{
        .data = batch.data.ptr,
        .len = batch.data.len,
        .row_count = batch.row_count,
        .kind = @intFromEnum(batch.kind),
    };
    return 1;
}

/// Free a batch returned by `ch_stream_next_batch`.
pub export fn ch_csv_batch_free(batch: ?*ChCsvBatch) void {
    if (batch) |b| {
        if (b.data) |ptr| {
            if (b.len > 0) gpa().free(ptr[0..b.len]);
        }
        b.* = .{};
    }
}

/// Row counts. `trailer_count` is 0 until a trailer line has been seen.
pub export fn ch_stream_stats(
    s: ?*const stream_mod.Stream,
    companies: ?*i32,
    persons: ?*i32,
    trailer_count: ?*i32,
) void {
    if (s == null) return;
    const stream = s.?;
    if (companies) |c| c.* = stream.companies;
    if (persons) |p| p.* = stream.persons;
    if (trailer_count) |t| t.* = stream.trailer_count orelse 0;
}
