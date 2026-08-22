//! C-compatible foreign function interface for multi-product parsing.
//! Also used as the export surface for freestanding WASM builds.
//!
//! Two modes:
//! - One-shot: `ch_parse` (full document in / full named CSVs out)
//! - Streaming: `ch_stream_*` (chunked input, batched CSV pull by OutputKind)

const std = @import("std");
const builtin = @import("builtin");
const document = @import("document.zig");
const parse = @import("parse.zig");
const version_mod = @import("version.zig");
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

/// Max product numbers stored per format entry (snapshot has two: 195, 216).
pub const CH_MAX_PRODUCT_CODES: usize = 4;

/// One supported file format (static strings; do not free).
/// Layout is stable for C and wasm32 hosts.
pub const ChSupportedFormat = extern struct {
    /// `CH_FILE_*` product id.
    file_type: i32 = CH_FILE_UNKNOWN,
    /// Number of valid entries in `product_codes` (1..CH_MAX_PRODUCT_CODES).
    product_code_count: u32 = 0,
    /// Companies House product numbers; only the first `product_code_count` are set.
    product_codes: [CH_MAX_PRODUCT_CODES]u16 = .{0} ** CH_MAX_PRODUCT_CODES,
    /// NUL-terminated 8-byte header magic (static).
    header_identifier: [*:0]const u8 = "",
    /// NUL-terminated short description (static).
    description: [*:0]const u8 = "",
};

/// Library identity + supported formats (static strings/table; do not free).
/// wasm32 layout: 3×ptr + usize = 16 bytes.
pub const ChLibraryInfo = extern struct {
    /// NUL-terminated semver (e.g. `"0.1.0"`).
    version: [*:0]const u8 = "",
    /// NUL-terminated short git SHA at build time, or `"unknown"`.
    git_commit: [*:0]const u8 = "",
    /// Pointer to static `ChSupportedFormat` array of length `format_count`.
    formats: ?[*]const ChSupportedFormat = null,
    format_count: usize = 0,
};

/// Output kind; matches `parse.OutputKind` / `CH_OUTPUT_*`. Append-only.
pub const CH_OUTPUT_COMPANIES: i32 = 0;
pub const CH_OUTPUT_PERSONS: i32 = 1;
pub const CH_OUTPUT_DISQUALIFICATIONS: i32 = 2;
pub const CH_OUTPUT_EXEMPTIONS: i32 = 3;
pub const CH_OUTPUT_VARIATIONS: i32 = 4;
pub const CH_OUTPUT_FORMS: i32 = 5;
pub const CH_OUTPUT_PRACTITIONERS: i32 = 6;
pub const CH_OUTPUT_FREE_TEXT: i32 = 7;

/// Kind-indexed table capacity. Matches `CH_MAX_OUTPUT_KINDS`.
pub const CH_MAX_OUTPUT_KINDS: usize = 16;
pub const CH_WARNING_MESSAGE_MAX: usize = 256;

comptime {
    if (parse.OutputKind.all.len > CH_MAX_OUTPUT_KINDS) {
        @compileError("OutputKind catalogue exceeds CH_MAX_OUTPUT_KINDS");
    }
}

fn copyWarning(dest: *[CH_WARNING_MESSAGE_MAX]u8, src: []const u8) void {
    dest.* = [_]u8{0} ** CH_WARNING_MESSAGE_MAX;
    const n = @min(src.len, CH_WARNING_MESSAGE_MAX - 1);
    if (n > 0) @memcpy(dest.*[0..n], src[0..n]);
}

fn warningSlice(buf: *const [CH_WARNING_MESSAGE_MAX]u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

/// One-shot parse result. Kind-indexed counts/csv; unused slots empty.
pub const ChParseResult = extern struct {
    file_type: i32 = CH_FILE_UNKNOWN,
    trailer_count: i32 = 0,
    warning_count: i32 = 0,
    reserved: i32 = 0,
    counts: [CH_MAX_OUTPUT_KINDS]i32 = [_]i32{0} ** CH_MAX_OUTPUT_KINDS,
    csv: [CH_MAX_OUTPUT_KINDS]ChBuffer = [_]ChBuffer{.{}} ** CH_MAX_OUTPUT_KINDS,
    last_warning: [CH_WARNING_MESSAGE_MAX]u8 = [_]u8{0} ** CH_WARNING_MESSAGE_MAX,
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

/// Streaming row counts, warnings, and product id after header is known.
pub const ChStreamStats = extern struct {
    file_type: i32 = CH_FILE_UNKNOWN,
    trailer_count: i32 = 0,
    warning_count: i32 = 0,
    reserved: i32 = 0,
    counts: [CH_MAX_OUTPUT_KINDS]i32 = [_]i32{0} ** CH_MAX_OUTPUT_KINDS,
    last_warning: [CH_WARNING_MESSAGE_MAX]u8 = [_]u8{0} ** CH_WARNING_MESSAGE_MAX,
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
/// Formatted CSV row exceeds the internal row buffer.
pub const CH_ERR_ROW_TOO_LARGE: c_int = 9;
/// Prod 197 form group exceeded max practitioners or free-text lines.
pub const CH_ERR_RECORD_LIMIT: c_int = 10;

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
        error.RowTooLarge => CH_ERR_ROW_TOO_LARGE,
        error.RecordLimitExceeded => CH_ERR_RECORD_LIMIT,
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

fn toCSupportedFormat(fmt: parse.SupportedFormat) ChSupportedFormat {
    // Header ids and descriptions are string literals (NUL-terminated in the binary).
    const header_z: [*:0]const u8 = @ptrCast(fmt.header_identifier.ptr);
    const desc_z: [*:0]const u8 = @ptrCast(fmt.description.ptr);
    var out: ChSupportedFormat = .{
        .file_type = @intFromEnum(fmt.file_type),
        .product_code_count = 0,
        .product_codes = .{0} ** CH_MAX_PRODUCT_CODES,
        .header_identifier = header_z,
        .description = desc_z,
    };
    const n = @min(fmt.product_codes.len, CH_MAX_PRODUCT_CODES);
    out.product_code_count = @intCast(n);
    for (fmt.product_codes[0..n], 0..) |code, i| {
        out.product_codes[i] = code;
    }
    return out;
}

/// Static table built once for the C/WASM ABI (process lifetime).
const c_supported_formats_table = blk: {
    @setEvalBranchQuota(1000);
    var table: [parse.supported_formats.len]ChSupportedFormat = undefined;
    for (parse.supported_formats, 0..) |fmt, i| {
        table[i] = toCSupportedFormat(fmt);
    }
    break :blk table;
};

/// Return a pointer to a static array of supported file formats.
/// Sets `*out_count` to the number of entries when `out_count` is non-null.
/// The pointer is valid for the process lifetime; do not free.
pub export fn ch_supported_formats(out_count: ?*usize) [*]const ChSupportedFormat {
    if (out_count) |c| c.* = c_supported_formats_table.len;
    return &c_supported_formats_table;
}

const c_library_info: ChLibraryInfo = .{
    // Injected build_options strings are string literals (NUL-terminated).
    .version = @ptrCast(version_mod.version.ptr),
    .git_commit = @ptrCast(version_mod.git_commit.ptr),
    .formats = &c_supported_formats_table,
    .format_count = c_supported_formats_table.len,
};

/// Return a pointer to static library metadata (semver, git commit, formats).
/// Valid for the process lifetime; do not free.
pub export fn ch_library_info() *const ChLibraryInfo {
    return &c_library_info;
}

/// Free all CSV buffers in a parse result.
pub export fn ch_parse_result_free(result: ?*ChParseResult) void {
    if (result) |r| {
        for (&r.csv) |*buf| freeBuffer(buf);
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
            error.RowTooLarge => CH_ERR_ROW_TOO_LARGE,
            error.RecordLimitExceeded => CH_ERR_RECORD_LIMIT,
        };
    };

    result.file_type = @intFromEnum(parsed.file_type);
    result.trailer_count = parsed.trailer_count;
    result.warning_count = parsed.warning_count;
    result.reserved = 0;
    copyWarning(&result.last_warning, parsed.lastWarningSlice());
    for (parse.OutputKind.all) |kind| {
        const i = kind.index();
        result.counts[i] = parsed.rowCount(kind);
        result.csv[i] = bufferFromSlice(parsed.csvs[i]);
    }
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
    var stats: ChStreamStats = .{
        .file_type = if (stream.file_type) |ft| @intFromEnum(ft) else CH_FILE_UNKNOWN,
        .trailer_count = stream.trailer_count orelse 0,
        .warning_count = stream.warning_count,
        .reserved = 0,
    };
    copyWarning(&stats.last_warning, warningSlice(&stream.last_warning));
    for (parse.OutputKind.all) |kind| {
        stats.counts[kind.index()] = stream.countOf(kind);
    }
    out.?.* = stats;
}
