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
};

/// In-memory CSV outputs for a parsed bulk file.
///
/// Unused kinds have empty CSV slices and zero row counts. Products map as:
/// - Officers (195/216/198): companies + persons
/// - Disqualifications (192): persons + disqualifications + exemptions + variations
/// - Liquidation (197): forms + practitioners + free_text
pub const ParseResult = struct {
    file_type: parse.FileType,
    trailer_count: i32,

    companies_csv: []u8,
    persons_csv: []u8,
    disqualifications_csv: []u8,
    exemptions_csv: []u8,
    variations_csv: []u8,
    forms_csv: []u8,
    practitioners_csv: []u8,
    free_text_csv: []u8,

    companies: i32,
    persons: i32,
    disqualifications: i32,
    exemptions: i32,
    variations: i32,
    forms: i32,
    practitioners: i32,
    free_text: i32,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.companies_csv);
        allocator.free(self.persons_csv);
        allocator.free(self.disqualifications_csv);
        allocator.free(self.exemptions_csv);
        allocator.free(self.variations_csv);
        allocator.free(self.forms_csv);
        allocator.free(self.practitioners_csv);
        allocator.free(self.free_text_csv);
        self.* = undefined;
    }

    pub fn csv(self: *const ParseResult, kind: parse.OutputKind) []const u8 {
        return switch (kind) {
            .companies => self.companies_csv,
            .persons => self.persons_csv,
            .disqualifications => self.disqualifications_csv,
            .exemptions => self.exemptions_csv,
            .variations => self.variations_csv,
            .forms => self.forms_csv,
            .practitioners => self.practitioners_csv,
            .free_text => self.free_text_csv,
        };
    }

    pub fn rowCount(self: *const ParseResult, kind: parse.OutputKind) i32 {
        return switch (kind) {
            .companies => self.companies,
            .persons => self.persons,
            .disqualifications => self.disqualifications,
            .exemptions => self.exemptions,
            .variations => self.variations,
            .forms => self.forms,
            .practitioners => self.practitioners,
            .free_text => self.free_text,
        };
    }
};

fn mapStreamErr(err: stream_mod.ParseError) ParseError {
    return switch (err) {
        error.UnsupportedFileType => error.UnsupportedFileType,
        error.NotImplemented => error.NotImplemented,
        error.MissingTrailer => error.MissingTrailer,
        error.TrailerMismatch => error.TrailerMismatch,
        error.OutOfMemory => error.OutOfMemory,
        // One-shot never leaves the stream mid-finish in these states.
        error.AlreadyFinished, error.FeedAfterTrailer => error.UnsupportedFileType,
    };
}

fn kindIndex(kind: parse.OutputKind) usize {
    return @intCast(@intFromEnum(kind));
}

fn csvOf(slices: *const [parse.OutputKind.all.len][]u8, kind: parse.OutputKind) []u8 {
    return slices[kindIndex(kind)];
}

fn countOf(counts: *const [parse.OutputKind.all.len]i32, kind: parse.OutputKind) i32 {
    return counts[kindIndex(kind)];
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
        const idx: usize = @intCast(@intFromEnum(b.kind));
        try acc[idx].appendSlice(allocator, b.data);
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
        counts[kindIndex(kind)] = s.countOf(kind);
    }

    // Ownership of slices moves into the result; cancel slice errdefer.
    n_owned = 0;

    return .{
        .file_type = file_type,
        .trailer_count = trailer_count,
        .companies_csv = csvOf(&slices, .companies),
        .persons_csv = csvOf(&slices, .persons),
        .disqualifications_csv = csvOf(&slices, .disqualifications),
        .exemptions_csv = csvOf(&slices, .exemptions),
        .variations_csv = csvOf(&slices, .variations),
        .forms_csv = csvOf(&slices, .forms),
        .practitioners_csv = csvOf(&slices, .practitioners),
        .free_text_csv = csvOf(&slices, .free_text),
        .companies = countOf(&counts, .companies),
        .persons = countOf(&counts, .persons),
        .disqualifications = countOf(&counts, .disqualifications),
        .exemptions = countOf(&counts, .exemptions),
        .variations = countOf(&counts, .variations),
        .forms = countOf(&counts, .forms),
        .practitioners = countOf(&counts, .practitioners),
        .free_text = countOf(&counts, .free_text),
    };
}
