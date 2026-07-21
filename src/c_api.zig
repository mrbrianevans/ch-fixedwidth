//! C-compatible foreign function interface for in-memory snapshot parsing.
//! Also used as the export surface for freestanding WASM builds.

const std = @import("std");
const builtin = @import("builtin");
const snapshot = @import("snapshot.zig");

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

// Error codes for C callers (stable ABI).
pub const CH_OK: c_int = 0;
pub const CH_ERR_INVALID_ARG: c_int = 1;
pub const CH_ERR_UNSUPPORTED_HEADER: c_int = 2;
pub const CH_ERR_MISSING_TRAILER: c_int = 3;
pub const CH_ERR_TRAILER_MISMATCH: c_int = 4;
pub const CH_ERR_OUT_OF_MEMORY: c_int = 5;
pub const CH_ERR_INTERNAL: c_int = 6;

fn gpa() std.mem.Allocator {
    if (comptime builtin.cpu.arch.isWasm()) {
        return std.heap.wasm_allocator;
    }
    return std.heap.smp_allocator;
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
export fn ch_buffer_free(buf: ?*ChBuffer) void {
    if (buf) |b| freeBuffer(b);
}

/// Free both CSV buffers in a parse result.
export fn ch_parse_result_free(result: ?*ChParseResult) void {
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
/// Does not perform filesystem I/O.
export fn ch_parse_snapshot(
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
export fn ch_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const mem = gpa().alloc(u8, size) catch return null;
    return mem.ptr;
}

/// Free memory returned by `ch_alloc`.
export fn ch_free(ptr: ?[*]u8, size: usize) void {
    if (ptr) |p| {
        if (size > 0) gpa().free(p[0..size]);
    }
}
