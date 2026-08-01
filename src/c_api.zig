//! C-compatible foreign function interface for multi-product parsing.
//! Also used as the export surface for freestanding WASM builds.
//!
//! Two modes:
//! - One-shot: `ch_parse` (full document in / full named CSVs out)
//! - Streaming: `ch_stream_*` (chunked input, batched CSV pull by OutputKind)

const std = @import("std");
const builtin = @import("builtin");
const document = @import("document.zig");
const stream_mod = @import("stream.zig");

/// Opaque heap buffer returned to C/WASM callers.
pub const ChBuffer = extern struct {
    data: ?[*]u8 = null,
    len: usize = 0,
};

/// Product id; matches `parse.FileType` / `CH_FILE_*`. `-1` = unknown.
pub const CH_FILE_UNKNOWN: i32 = -1;
pub const CH_FILE_OFFICERS_SNAPSHOT: i32 = 0;
pub const CH_FILE_OFFICERS_UPDATE: i32 = 1;
pub const CH_FILE_DISQUALIFICATIONS: i32 = 2;
pub const CH_FILE_LIQUIDATION: i32 = 3;

/// Output kind; matches `parse.OutputKind` / `CH_OUTPUT_*`.
pub const CH_OUTPUT_COMPANIES: i32 = 0;
pub const CH_OUTPUT_PERSONS: i32 = 1;
pub const CH_OUTPUT_DISQUALIFICATIONS: i32 = 2;
pub const CH_OUTPUT_EXEMPTIONS: i32 = 3;
pub const CH_OUTPUT_VARIATIONS: i32 = 4;
pub const CH_OUTPUT_FORMS: i32 = 5;
pub const CH_OUTPUT_PRACTITIONERS: i32 = 6;
pub const CH_OUTPUT_FREE_TEXT: i32 = 7;

/// One-shot parse result. Unused product outputs are empty buffers / zero counts.
/// Layout: counts first (fixed), then CSV buffers (pointer-sized).
pub const ChParseResult = extern struct {
    file_type: i32 = CH_FILE_UNKNOWN,
    trailer_count: i32 = 0,
    companies: i32 = 0,
    persons: i32 = 0,
    disqualifications: i32 = 0,
    exemptions: i32 = 0,
    variations: i32 = 0,
    forms: i32 = 0,
    practitioners: i32 = 0,
    free_text: i32 = 0,
    companies_csv: ChBuffer = .{},
    persons_csv: ChBuffer = .{},
    disqualifications_csv: ChBuffer = .{},
    exemptions_csv: ChBuffer = .{},
    variations_csv: ChBuffer = .{},
    forms_csv: ChBuffer = .{},
    practitioners_csv: ChBuffer = .{},
    free_text_csv: ChBuffer = .{},
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
    /// `CH_OUTPUT_*` / `parse.OutputKind`.
    kind: i32 = 0,
};

/// Streaming row counts and product id after header is known.
pub const ChStreamStats = extern struct {
    file_type: i32 = CH_FILE_UNKNOWN,
    trailer_count: i32 = 0,
    companies: i32 = 0,
    persons: i32 = 0,
    disqualifications: i32 = 0,
    exemptions: i32 = 0,
    variations: i32 = 0,
    forms: i32 = 0,
    practitioners: i32 = 0,
    free_text: i32 = 0,
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
        gpa().free(ptr[0..buf.len]);
        buf.data = null;
        buf.len = 0;
    }
}

fn bufferFromSlice(s: []u8) ChBuffer {
    return .{ .data = s.ptr, .len = s.len };
}

/// Free a buffer previously filled by `ch_parse`.
pub export fn ch_buffer_free(buf: ?*ChBuffer) void {
    if (buf) |b| freeBuffer(b);
}

/// Free all CSV buffers in a parse result.
pub export fn ch_parse_result_free(result: ?*ChParseResult) void {
    if (result) |r| {
        freeBuffer(&r.companies_csv);
        freeBuffer(&r.persons_csv);
        freeBuffer(&r.disqualifications_csv);
        freeBuffer(&r.exemptions_csv);
        freeBuffer(&r.variations_csv);
        freeBuffer(&r.forms_csv);
        freeBuffer(&r.practitioners_csv);
        freeBuffer(&r.free_text_csv);
        r.* = .{};
    }
}

/// Parse an in-memory Companies House fixed-width document into named CSV outputs.
///
/// On success (`CH_OK`), free with `ch_parse_result_free`.
/// Does not perform filesystem I/O. Prefer `ch_stream_*` for large files.
pub export fn ch_parse(
    input: ?[*]const u8,
    input_len: usize,
    out: ?*ChParseResult,
) c_int {
    if (input == null or out == null) return CH_ERR_INVALID_ARG;
    if (input_len == 0) return CH_ERR_INVALID_ARG;

    const slice = input.?[0..input_len];
    const result = out.?;
    result.* = .{};

    const parsed = document.parseDocument(gpa(), slice) catch |err| {
        return switch (err) {
            error.UnsupportedFileType => CH_ERR_UNSUPPORTED_HEADER,
            error.NotImplemented => CH_ERR_NOT_IMPLEMENTED,
            error.MissingTrailer => CH_ERR_MISSING_TRAILER,
            error.TrailerMismatch => CH_ERR_TRAILER_MISMATCH,
            error.OutOfMemory => CH_ERR_OUT_OF_MEMORY,
        };
    };

    result.file_type = @intFromEnum(parsed.file_type);
    result.trailer_count = parsed.trailer_count;
    result.companies = parsed.companies;
    result.persons = parsed.persons;
    result.disqualifications = parsed.disqualifications;
    result.exemptions = parsed.exemptions;
    result.variations = parsed.variations;
    result.forms = parsed.forms;
    result.practitioners = parsed.practitioners;
    result.free_text = parsed.free_text;
    result.companies_csv = bufferFromSlice(parsed.companies_csv);
    result.persons_csv = bufferFromSlice(parsed.persons_csv);
    result.disqualifications_csv = bufferFromSlice(parsed.disqualifications_csv);
    result.exemptions_csv = bufferFromSlice(parsed.exemptions_csv);
    result.variations_csv = bufferFromSlice(parsed.variations_csv);
    result.forms_csv = bufferFromSlice(parsed.forms_csv);
    result.practitioners_csv = bufferFromSlice(parsed.practitioners_csv);
    result.free_text_csv = bufferFromSlice(parsed.free_text_csv);
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
/// Returns 1 if a batch was written, 0 if none pending, or a positive `CH_ERR_*`.
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

/// Fill `out` with cumulative row counts. `file_type` is `CH_FILE_UNKNOWN` until
/// the 8-byte header magic is seen. `trailer_count` is 0 until a trailer is seen.
pub export fn ch_stream_stats(s: ?*const stream_mod.Stream, out: ?*ChStreamStats) void {
    if (s == null or out == null) return;
    const stream = s.?;
    out.?.* = .{
        .file_type = if (stream.file_type) |ft| @intFromEnum(ft) else CH_FILE_UNKNOWN,
        .trailer_count = stream.trailer_count orelse 0,
        .companies = stream.countOf(.companies),
        .persons = stream.countOf(.persons),
        .disqualifications = stream.countOf(.disqualifications),
        .exemptions = stream.countOf(.exemptions),
        .variations = stream.countOf(.variations),
        .forms = stream.countOf(.forms),
        .practitioners = stream.countOf(.practitioners),
        .free_text = stream.countOf(.free_text),
    };
}
