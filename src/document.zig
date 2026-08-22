//! In-memory fixed-width document → named CSV outputs (no filesystem I/O).
//! Used by the C ABI, WASM exports, and unit tests.
//!
//! `parseDocument` is a thin one-shot wrapper around `stream.Stream`: feed the
//! full buffer, finish, and concatenate batches by `OutputKind`. Product body
//! logic lives only in the stream parser.

const std = @import("std");
const parse = @import("parse.zig");
const stream_mod = @import("stream.zig");

pub const ParseError = error{
    UnsupportedFileType,
    NotImplemented,
    MissingTrailer,
    TrailerMismatch,
    OutOfMemory,
    RowTooLarge,
    RecordLimitExceeded,
    UnknownRecord,
    FieldOverflow,
    FeedAfterTrailer,
};

/// In-memory CSV outputs for a parsed bulk file.
///
/// Kind-indexed: `csvs[kind.index()]` / `counts[kind.index()]`. Unused kinds
/// have empty CSV slices and zero row counts.
pub const ParseResult = struct {
    file_type: parse.FileType,
    trailer_count: i32,
    warning_count: i32 = 0,
    last_warning: [256]u8 = [_]u8{0} ** 256,

    csvs: [parse.OutputKind.all.len][]u8,
    counts: [parse.OutputKind.all.len]i32,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.csvs) |slice| allocator.free(slice);
        self.* = undefined;
    }

    pub fn csv(self: *const ParseResult, kind: parse.OutputKind) []const u8 {
        return self.csvs[kind.index()];
    }

    pub fn rowCount(self: *const ParseResult, kind: parse.OutputKind) i32 {
        return self.counts[kind.index()];
    }

    pub fn lastWarningSlice(self: *const ParseResult) []const u8 {
        return std.mem.sliceTo(&self.last_warning, 0);
    }
};

fn mapStreamErr(err: stream_mod.ParseError) ParseError {
    return switch (err) {
        error.UnsupportedFileType => error.UnsupportedFileType,
        error.NotImplemented => error.NotImplemented,
        error.MissingTrailer => error.MissingTrailer,
        error.TrailerMismatch => error.TrailerMismatch,
        error.OutOfMemory => error.OutOfMemory,
        error.RowTooLarge => error.RowTooLarge,
        error.RecordLimitExceeded => error.RecordLimitExceeded,
        error.UnknownRecord => error.UnknownRecord,
        error.FieldOverflow => error.FieldOverflow,
        error.FeedAfterTrailer => error.FeedAfterTrailer,
        error.AlreadyFinished => error.UnsupportedFileType,
    };
}

/// Parse a full fixed-width buffer into named CSV outputs.
/// Caller owns the result and must call `deinit`.
pub fn parseDocument(allocator: std.mem.Allocator, input: []const u8) ParseError!ParseResult {
    // Large batches: one-shot prefers fewer partial flushes while concatenating.
    var s = stream_mod.Stream.init(allocator, .{
        .batch_rows = std.math.maxInt(usize),
        .batch_bytes = std.math.maxInt(usize),
    });
    defer s.deinit();

    s.feed(input) catch |err| return mapStreamErr(err);
    s.finish() catch |err| return mapStreamErr(err);

    const file_type = s.file_type orelse return error.UnsupportedFileType;
    const trailer_count = s.trailer_count orelse return error.MissingTrailer;

    var acc: [parse.OutputKind.all.len]std.ArrayList(u8) = undefined;
    for (&acc) |*list| list.* = .empty;
    errdefer {
        for (&acc) |*list| list.deinit(allocator);
    }

    while (s.nextBatch()) |batch| {
        var b = batch;
        defer b.deinit(allocator);
        try acc[b.kind.index()].appendSlice(allocator, b.data);
    }

    var slices: [parse.OutputKind.all.len][]u8 = undefined;
    var n_owned: usize = 0;
    errdefer {
        for (slices[0..n_owned]) |slice| allocator.free(slice);
    }

    for (&acc, 0..) |*list, i| {
        slices[i] = try list.toOwnedSlice(allocator);
        n_owned = i + 1;
        // list is empty after toOwnedSlice; clear so errdefer on acc is a no-op free.
        list.* = .empty;
    }

    var counts: [parse.OutputKind.all.len]i32 = undefined;
    for (parse.OutputKind.all) |kind| {
        counts[kind.index()] = s.countOf(kind);
    }

    // Ownership of slices moves into the result; cancel slice errdefer.
    n_owned = 0;

    var last_warning: [256]u8 = [_]u8{0} ** 256;
    last_warning = s.last_warning;

    return .{
        .file_type = file_type,
        .trailer_count = trailer_count,
        .warning_count = s.warning_count,
        .last_warning = last_warning,
        .csvs = slices,
        .counts = counts,
    };
}
