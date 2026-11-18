//! File-based conversion: streaming I/O, optional multithreading.
//! Uses pure formatters from `parse.zig` for record → CSV.
//! Native CLI also supports streaming HTTP(S) download of remote `.dat` URLs,
//! stdin (`-`), and a directory of local `.dat` files.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Thread = std.Thread;
const http = std.http;
const parse = @import("parse.zig");
const stream_mod = @import("stream.zig");
const pipeline = @import("pipeline.zig");

// 1 MiB read / write buffers. Larger buffers gave no throughput gain in benchmarks,
// but every one is resident memory: seek-split officers conversion allocates one
// read + two write buffers per worker (up to `max_workers`), and the streaming
// path one per output CSV. 1 MiB also keeps wasm32-wasi within linear memory and
// clear of host WASI edge cases with multi-MB vectored I/O.
const read_buffer_size: usize = 1 * 1024 * 1024;
const write_buffer_size: usize = 1 * 1024 * 1024;
const max_workers = 32;
/// Upper bound on input bytes handed to `Stream.feed` before draining batches.
/// Keeps pending CSV batches small regardless of the reader's buffer size.
const stream_feed_slice: usize = 1 * 1024 * 1024;

/// General-purpose allocator for allocations that are freed during a run
/// (Stream carry / CSV batches, per-file scratch arenas). Unlike the
/// process-long `std.process.Init` arena, frees here release memory, so peak
/// RSS stays bounded on long-running or multi-file conversions.
fn heapAllocator() std.mem.Allocator {
    if (comptime builtin.cpu.arch.isWasm()) {
        return std.heap.wasm_allocator;
    }
    return std.heap.smp_allocator;
}

const CsvOut = struct {
    file: Io.File,
    io: Io,
    writer: Io.File.Writer,

    fn create(io: Io, path: []const u8, header: ?[]const u8, buffer: []u8) !CsvOut {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        var self: CsvOut = .{
            .file = file,
            .io = io,
            .writer = .initStreaming(file, io, buffer),
        };
        if (header) |h| try self.writer.interface.writeAll(h);
        return self;
    }

    fn w(self: *CsvOut) *Io.Writer {
        return &self.writer.interface;
    }

    fn beginRow(self: *CsvOut) ![]u8 {
        return self.w().writableSliceGreedy(parse.max_csv_row_bytes);
    }

    fn endRow(self: *CsvOut, written: usize) void {
        self.w().advance(written);
    }

    fn close(self: *CsvOut) void {
        self.w().flush() catch {};
        self.file.close(self.io);
    }
};

/// Identify the product from the header row and ensure a body parser exists.
/// Returns the parsed header on success so callers can branch if needed.
fn processHeaderRow(row: []const u8) !parse.HeaderInfo {
    const info = parse.parseHeader(row) catch {
        const prefix = if (row.len >= parse.header_identifier_len)
            row[0..parse.header_identifier_len]
        else
            row;
        std.debug.print("Error: unsupported file type from header: '{s}'\n", .{prefix});
        return error.UnsupportedFileType;
    };
    parse.requireImplemented(info.file_type) catch {
        std.debug.print(
            "Error: {s} files (header '{s}') are not supported yet\n",
            .{ info.file_type.displayName(), info.file_type.identifier() },
        );
        return error.NotImplemented;
    };
    std.debug.print("Processing {s} with run number {s} from date {s}\n", .{
        info.file_type.displayName(),
        info.run_number,
        info.production_date,
    });
    return info;
}

/// True when `s` is an HTTP(S) URL (case-insensitive scheme).
pub fn isRemoteUrl(s: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, "http://") or
        std.ascii.startsWithIgnoreCase(s, "https://");
}

/// True when the CLI should read the input from stdin (`-`).
pub fn isStdinInput(s: []const u8) bool {
    return std.mem.eql(u8, s, "-");
}

/// True when `name` has a `.dat` extension (ASCII case-insensitive).
pub fn hasDatExtension(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".dat");
}

/// True when `path` ends with a path separator (`/` or `\`).
pub fn pathEndsWithSep(path: []const u8) bool {
    if (path.len == 0) return false;
    const c = path[path.len - 1];
    return c == '/' or c == '\\';
}

/// Heuristic path kind before filesystem confirmation.
/// `.dat` → file; trailing separator or no `.dat` extension → directory.
pub fn looksLikeDirectoryInput(path: []const u8) bool {
    if (path.len == 0) return false;
    if (pathEndsWithSep(path)) return true;
    return !hasDatExtension(std.fs.path.basename(path));
}

pub const LocalInputKind = enum { file, directory };

/// Resolve whether a local path is a single file or a directory.
/// Filesystem `stat` is authoritative when the path exists; on failure the
/// path-shape heuristic is used only to shape error messages elsewhere.
pub fn resolveLocalInputKind(io: Io, path: []const u8) !LocalInputKind {
    const st = try Io.Dir.cwd().statFile(io, path, .{});
    return switch (st.kind) {
        .directory => .directory,
        else => .file,
    };
}

fn stripExtension(base: []const u8) []const u8 {
    const ext = std.fs.path.extension(base);
    if (ext.len == 0) return base;
    return base[0 .. base.len - ext.len];
}

/// Basename without extension for local paths, remote URLs, or stdin (`-` → `stdin`).
/// For URLs, uses the last path segment (query/fragment ignored).
pub fn baseInputName(input_path: []const u8) []const u8 {
    if (isStdinInput(input_path)) return "stdin";
    if (isRemoteUrl(input_path)) {
        const uri = std.Uri.parse(input_path) catch {
            return "download";
        };
        const path_raw = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        // Drop query-like junk if parse left it in path (defensive).
        const path_no_q = if (std.mem.indexOfScalar(u8, path_raw, '?')) |q|
            path_raw[0..q]
        else
            path_raw;
        var base = std.fs.path.basename(path_no_q);
        if (base.len == 0 or std.mem.eql(u8, base, "/") or std.mem.eql(u8, base, "\\")) {
            return "download";
        }
        // Percent-encoded basename is fine for filesystem names on modern OSes;
        // still strip a trailing slash if present.
        if (base[base.len - 1] == '/') base = base[0 .. base.len - 1];
        if (base.len == 0) return "download";
        return stripExtension(base);
    }
    return stripExtension(std.fs.path.basename(input_path));
}

fn processParallel(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
    base_name: []const u8,
    n_workers: usize,
) !u8 {
    return processParallelChunked(io, arena, input_path, output_folder, base_name, n_workers, pipeline.default_chunk_len);
}

/// Officers conversion of a local file on `n_workers` threads through the
/// ordered chunk pipeline (`pipeline.zig`): rows are written straight to the
/// final CSVs in input order, with no part files to concatenate.
fn processParallelChunked(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
    base_name: []const u8,
    n_workers: usize,
    chunk_len: usize,
) !u8 {
    const workers = @max(1, @min(n_workers, max_workers));

    const read_buf = try arena.alloc(u8, read_buffer_size);

    // Identify product from the header so the right person formatter and CSV
    // header are used. The pipeline re-reads the header line (and skips it).
    const header_info = blk: {
        const f = try Io.Dir.cwd().openFile(io, input_path, .{});
        defer f.close(io);
        var fr = Io.File.Reader.init(f, io, read_buf);
        const maybe = try fr.interface.takeDelimiter('\n');
        const row = parse.stripCr(maybe orelse {
            std.debug.print("ERROR: empty input\n", .{});
            return 1;
        });
        break :blk processHeaderRow(row) catch return 1;
    };

    const input_file = try Io.Dir.cwd().openFile(io, input_path, .{});
    defer input_file.close(io);
    var file_reader = Io.File.Reader.init(input_file, io, read_buf);
    return convertOfficersParallel(io, arena, &file_reader.interface, header_info.file_type, output_folder, base_name, workers, chunk_len);
}

/// Run the ordered chunk pipeline over `reader` (positioned at the header
/// line) into `companies_data_<base>.csv` / `persons_data_<base>.csv`.
fn convertOfficersParallel(
    io: Io,
    arena: std.mem.Allocator,
    reader: *Io.Reader,
    file_type: parse.FileType,
    output_folder: []const u8,
    base_name: []const u8,
    workers: usize,
    chunk_len: usize,
) !u8 {
    const companies_filename = try std.fs.path.join(arena, &.{
        output_folder,
        try std.fmt.allocPrint(arena, "companies_data_{s}.csv", .{base_name}),
    });
    const persons_filename = try std.fs.path.join(arena, &.{
        output_folder,
        try std.fmt.allocPrint(arena, "persons_data_{s}.csv", .{base_name}),
    });
    std.debug.print("Saving companies data to {s}\n", .{companies_filename});
    std.debug.print("Saving persons data to {s}\n", .{persons_filename});

    var companies_out = try CsvOut.create(io, companies_filename, parse.companies_header, try arena.alloc(u8, write_buffer_size));
    defer companies_out.close();
    var persons_out = try CsvOut.create(io, persons_filename, file_type.personsCsvHeader(), try arena.alloc(u8, write_buffer_size));
    defer persons_out.close();

    const result = try pipeline.run(io, heapAllocator(), reader, file_type, companies_out.w(), persons_out.w(), .{
        .workers = workers,
        .chunk_len = chunk_len,
    });

    if (result.err) |err| {
        const detail = result.detail();
        if (detail.len > 0) {
            std.debug.print("Error parsing input: {s} at {s}\n", .{ @errorName(err), detail });
        } else {
            std.debug.print("Error parsing input: {s}\n", .{@errorName(err)});
        }
        return 1;
    }

    const total = result.companies + result.persons;
    if (result.trailer_count) |tc| {
        if (tc != total) {
            std.debug.print("ERROR: Processed {d} records out of {d}\n", .{ total, tc });
            return 1;
        }
    } else {
        std.debug.print("ERROR: No trailer record found.\n", .{});
        return 1;
    }

    std.debug.print("Processed {d} records: {d} companies, {d} persons.\n", .{ total, result.companies, result.persons });
    return 0;
}

/// Write every ready stream CSV batch to the matching output file (created lazily)
/// and free it. Batch bytes already include the CSV header when it is the first
/// flush for that kind. `arena` is used only for the one-off output paths and
/// write buffers (bounded by the number of output kinds).
fn drainStreamBatches(
    io: Io,
    arena: std.mem.Allocator,
    s: *stream_mod.Stream,
    output_folder: []const u8,
    base_name: []const u8,
    outs: *[parse.OutputKind.all.len]?CsvOut,
    write_bufs: *[parse.OutputKind.all.len]?[]u8,
) !u8 {
    while (s.nextBatch()) |batch| {
        var b = batch;
        defer b.deinit(s.allocator);
        const idx = b.kind.index();
        if (outs[idx] == null) {
            const filename = try std.fs.path.join(arena, &.{
                output_folder,
                try std.fmt.allocPrint(arena, "{s}_{s}.csv", .{ b.kind.fileStem(), base_name }),
            });
            std.debug.print("Saving {s} data to {s}\n", .{ b.kind.displayName(), filename });
            const buf = try arena.alloc(u8, write_buffer_size);
            write_bufs[idx] = buf;
            // Header is already inside the stream batch — do not write a second one.
            outs[idx] = CsvOut.create(io, filename, null, buf) catch |err| {
                std.debug.print("Error opening {s} file: {s}\n", .{ b.kind.displayName(), @errorName(err) });
                return 1;
            };
        }
        outs[idx].?.w().writeAll(b.data) catch |err| {
            std.debug.print("Error writing {s} rows: {s}\n", .{ b.kind.displayName(), @errorName(err) });
            return 1;
        };
    }
    return 0;
}

fn printStreamSummary(s: *const stream_mod.Stream) void {
    const ft = s.file_type orelse return;
    const tc = s.trailer_count orelse return;
    switch (ft) {
        .officers_snapshot, .officers_update => {
            const co = s.countOf(.companies);
            const pe = s.countOf(.persons);
            std.debug.print("Processed {d} records: {d} companies, {d} persons.\n", .{ tc, co, pe });
        },
        .disqualifications => {
            const n1 = s.countOf(.persons);
            const n2 = s.countOf(.disqualifications);
            const n3 = s.countOf(.exemptions);
            const n4 = s.countOf(.variations);
            std.debug.print(
                "Processed {d} records: {d} persons, {d} disqualifications, {d} exemptions, {d} variations.\n",
                .{ tc, n1, n2, n3, n4 },
            );
        },
        .liquidation => {
            std.debug.print(
                "Processed {d} records: {d} forms, {d} practitioners, {d} free text.\n",
                .{
                    tc,
                    s.countOf(.forms),
                    s.countOf(.practitioners),
                    s.countOf(.free_text),
                },
            );
        },
    }
}

fn printStreamError(context: []const u8, err: anyerror, s: *const stream_mod.Stream) void {
    const detail = s.errorDetailSlice();
    if (detail.len > 0) {
        std.debug.print("{s}: {s} at {s}\n", .{ context, @errorName(err), detail });
    } else {
        std.debug.print("{s}: {s}\n", .{ context, @errorName(err) });
    }
}

fn printStreamWarning(_: ?*anyopaque, message: []const u8) void {
    std.debug.print("warning: {s}\n", .{message});
}

/// Stream input from `reader` into product-specific CSVs under `output_folder`.
/// Uses the shared `stream.Stream` body parser (same as one-shot / WASM).
/// Caller must ensure `output_folder` exists. Same output layout as a local file run.
///
/// Memory stays O(reader buffer + output write buffers + one feed slice of CSV),
/// independent of input size: `arena` only receives fixed per-run allocations,
/// while the Stream (whose CSV batches are allocated and freed continuously)
/// runs on a freeing heap allocator and is torn down before returning.
pub fn processFromReader(
    io: Io,
    arena: std.mem.Allocator,
    reader: *Io.Reader,
    output_folder: []const u8,
    base_name: []const u8,
) !u8 {
    return processFromReaderWithAllocator(io, arena, heapAllocator(), reader, output_folder, base_name);
}

/// `processFromReader` with an explicit Stream allocator (tests pass a
/// leak-checking, memory-limited allocator). `stream_gpa` must actually release
/// memory on `free` — never pass an arena here, or every drained batch stays
/// resident and peak memory grows with the whole file.
fn processFromReaderWithAllocator(
    io: Io,
    arena: std.mem.Allocator,
    stream_gpa: std.mem.Allocator,
    reader: *Io.Reader,
    output_folder: []const u8,
    base_name: []const u8,
) !u8 {
    // Read header first for CLI product logging; body parsing is entirely in Stream.
    const first_line = reader.takeDelimiter('\n') catch |err| {
        std.debug.print("Error reading input: {s}\n", .{@errorName(err)});
        return 1;
    };
    const header_row = parse.stripCr(first_line orelse {
        std.debug.print("ERROR: empty input\n", .{});
        return 1;
    });
    _ = processHeaderRow(header_row) catch return 1;

    var s = stream_mod.Stream.init(stream_gpa, .{
        .batch_rows = 0, // defaults
        .batch_bytes = stream_feed_slice,
    });
    defer s.deinit();
    s.setWarnHandler(printStreamWarning, null);

    var outs: [parse.OutputKind.all.len]?CsvOut = .{null} ** parse.OutputKind.all.len;
    var write_bufs: [parse.OutputKind.all.len]?[]u8 = .{null} ** parse.OutputKind.all.len;
    defer {
        for (&outs) |*maybe| {
            if (maybe.*) |*out| out.close();
        }
    }

    // Re-feed the header line (with newline) so Stream sees the full document.
    {
        var header_chunk: [parse.max_csv_row_bytes + 1]u8 = undefined;
        if (header_row.len > parse.max_csv_row_bytes) {
            std.debug.print("ERROR: header line too long\n", .{});
            return 1;
        }
        @memcpy(header_chunk[0..header_row.len], header_row);
        header_chunk[header_row.len] = '\n';
        s.feed(header_chunk[0 .. header_row.len + 1]) catch |err| {
            std.debug.print("Error parsing header: {s}\n", .{@errorName(err)});
            return 1;
        };
        if ((try drainStreamBatches(io, arena, &s, output_folder, base_name, &outs, &write_bufs)) != 0)
            return 1;
    }

    // Feed the remainder straight from the reader's own buffer (no extra copy),
    // in bounded slices so pending batches never exceed ~one slice of CSV.
    // Stream handles partial lines across slices.
    while (true) {
        const buffered = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => {
                std.debug.print("Error reading input: {s}\n", .{@errorName(err)});
                return 1;
            },
        };
        const chunk = buffered[0..@min(buffered.len, stream_feed_slice)];
        s.feed(chunk) catch |err| {
            printStreamError("Error parsing input", err, &s);
            return 1;
        };
        reader.toss(chunk.len);
        if ((try drainStreamBatches(io, arena, &s, output_folder, base_name, &outs, &write_bufs)) != 0)
            return 1;
    }

    s.finish() catch |err| {
        switch (err) {
            error.MissingTrailer => std.debug.print("ERROR: No trailer record found.\n", .{}),
            error.TrailerMismatch => std.debug.print("ERROR: Trailer record count does not match rows parsed\n", .{}),
            else => printStreamError("Error finishing parse", err, &s),
        }
        return 1;
    };
    if ((try drainStreamBatches(io, arena, &s, output_folder, base_name, &outs, &write_bufs)) != 0)
        return 1;

    printStreamSummary(&s);
    return 0;
}

fn processSingle(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
    base_name: []const u8,
) !u8 {
    const read_buf = try arena.alloc(u8, read_buffer_size);

    const input_file = Io.Dir.cwd().openFile(io, input_path, .{}) catch |err| {
        std.debug.print("Error opening input file: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer input_file.close(io);

    // Streaming mode: positional pread is unreliable under some WASI hosts (Bun)
    // once total bytes read exceed the buffer size.
    var file_reader = Io.File.Reader.initStreaming(input_file, io, read_buf);
    return processFromReader(io, arena, &file_reader.interface, output_folder, base_name);
}

fn resolveWorkerCount(requested: ?usize) usize {
    if (requested) |n| {
        return @max(1, @min(n, max_workers));
    }
    const cpu_count = Thread.getCpuCount() catch 1;
    return @max(1, @min(cpu_count, max_workers));
}

/// Convert one local fixed-width file (assumes `output_folder` already exists).
/// On multi-core native builds, officers products split the file across workers.
/// Prod 192 / 197 always use the sequential path (multi-CSV / form-group state).
/// `worker_count` of `null` uses CPU count (capped at `max_workers`).
fn processOneLocalFile(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
    worker_count: ?usize,
) !u8 {
    const base_name = baseInputName(input_path);

    if (comptime builtin.single_threaded) {
        return processSingle(io, arena, input_path, output_folder, base_name);
    }

    // Probe product so multi-CSV / form-group products skip officers parallel split.
    const probe_buf = try arena.alloc(u8, 64 * 1024);
    const probed = blk: {
        const f = Io.Dir.cwd().openFile(io, input_path, .{}) catch break :blk null;
        defer f.close(io);
        var fr = Io.File.Reader.init(f, io, probe_buf);
        const maybe = fr.interface.takeDelimiter('\n') catch break :blk null;
        const row = parse.stripCr(maybe orelse break :blk null);
        break :blk parse.parseHeader(row) catch null;
    };
    if (probed) |h| {
        if (h.file_type == .disqualifications or h.file_type == .liquidation) {
            return processSingle(io, arena, input_path, output_folder, base_name);
        }
    }

    const n_workers = resolveWorkerCount(worker_count);

    if (n_workers <= 1) {
        return processSingle(io, arena, input_path, output_folder, base_name);
    }
    return processParallel(io, arena, input_path, output_folder, base_name, n_workers);
}

/// Convert one local fixed-width file on disk into product-specific CSVs under
/// `output_folder`. Returns a process exit code (0 = success).
///
/// Prefer `processInput` when the argument may be a path, directory, URL, or stdin.
/// `worker_count` of `null` uses CPU count (capped at `max_workers`).
pub fn processLocalFile(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
    worker_count: ?usize,
) !u8 {
    Io.Dir.cwd().createDirPath(io, output_folder) catch |err| {
        std.debug.print("Error creating output directory: {s}\n", .{@errorName(err)});
        return 1;
    };
    return processOneLocalFile(io, arena, input_path, output_folder, worker_count);
}

/// List non-directory entries under `dir_path` whose names end with `.dat`
/// (case-insensitive). Paths are joined with `dir_path` and sorted.
pub fn listDatFilesInDir(
    io: Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Error opening input directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| {
        std.debug.print("Error reading input directory '{s}': {s}\n", .{ dir_path, @errorName(err) });
        return err;
    }) |entry| {
        if (entry.kind == .directory) continue;
        if (!hasDatExtension(entry.name)) continue;
        const full = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        try list.append(arena, full);
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    return try list.toOwnedSlice(arena);
}

/// Convert every `.dat` file in `dir_path` into product-specific CSVs under
/// `output_folder` (officers → companies/persons; 192 / 197 → their kind sets).
///
/// Files are processed **one at a time**. On multi-core native builds each officers
/// file uses the same within-file seek split as a single-file CLI argument (option B).
/// See `docs/DDR-directory-parallelism.md`.
/// `worker_count` of `null` uses CPU count (capped at `max_workers`).
pub fn processDirectory(
    io: Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    output_folder: []const u8,
    worker_count: ?usize,
) !u8 {
    Io.Dir.cwd().createDirPath(io, output_folder) catch |err| {
        std.debug.print("Error creating output directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    const files = listDatFilesInDir(io, arena, dir_path) catch return 1;
    if (files.len == 0) {
        std.debug.print("Error: no .dat files found in directory '{s}'\n", .{dir_path});
        return 1;
    }

    std.debug.print("Found {d} .dat file(s) in {s}\n", .{ files.len, dir_path });

    var any_failed = false;
    for (files) |file_path| {
        std.debug.print("Processing {s}\n", .{file_path});
        // Per-file scratch arena: read/write buffers and paths for one file are
        // released before the next, so a long directory run does not keep
        // N files' worth of multi-MiB buffers resident.
        var file_arena_state = std.heap.ArenaAllocator.init(heapAllocator());
        defer file_arena_state.deinit();
        // One file at a time with full within-file multi-threading (same as lone file input).
        const code = processOneLocalFile(io, file_arena_state.allocator(), file_path, output_folder, worker_count) catch |err| {
            std.debug.print("Fatal error processing {s}: {s}\n", .{ file_path, @errorName(err) });
            any_failed = true;
            continue;
        };
        if (code != 0) any_failed = true;
    }
    return if (any_failed) 1 else 0;
}

const http_retry_max_attempts: u8 = 5;
const http_retry_base_ms: u64 = 200;
const http_retry_max_ms: u64 = 10_000;
const http_retry_after_cap_s: u64 = 60;

fn isRetryableHttpStatus(status: http.Status) bool {
    return status == .too_many_requests or status.class() == .server_error;
}

/// Transport failures that are worth another GET. Protocol/config errors are not.
fn isRetryableTransportError(err: anyerror) bool {
    return switch (err) {
        error.Canceled,
        error.OutOfMemory,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.CertificateBundleLoadFailure,
        error.HttpHeadersInvalid,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpHeadersOversize,
        => false,
        else => true,
    };
}

fn backoffMilliseconds(failed_attempt: u8) u64 {
    const shift: u6 = @intCast(@min(failed_attempt, 16));
    const scaled = http_retry_base_ms * (@as(u64, 1) << shift);
    return @min(scaled, http_retry_max_ms);
}

/// Integer `Retry-After` delay in seconds, capped. HTTP-date values are ignored.
fn parseRetryAfterSeconds(head: http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
        const trimmed = std.mem.trim(u8, header.value, " \t");
        const seconds = std.fmt.parseInt(u64, trimmed, 10) catch return null;
        return @min(seconds, http_retry_after_cap_s);
    }
    return null;
}

fn retryWaitMilliseconds(failed_attempt: u8, retry_after_s: ?u64) u64 {
    if (retry_after_s) |seconds| {
        return seconds * std.time.ms_per_s;
    }
    return backoffMilliseconds(failed_attempt);
}

fn sleepHttpRetry(io: Io, wait_ms: u64, reason: []const u8, failed_attempt: u8) !void {
    const next_attempt = failed_attempt + 2; // 1-based attempt we will make after sleeping
    std.debug.print(
        "Retrying download in {d} ms ({s}; attempt {d}/{d})\n",
        .{ wait_ms, reason, next_attempt, http_retry_max_attempts },
    );
    if (wait_ms == 0) return;
    const ms: i64 = std.math.cast(i64, wait_ms) orelse std.math.maxInt(i64);
    try Io.sleep(io, .fromMilliseconds(ms), .real);
}

fn maybeRetryTransport(
    io: Io,
    err: anyerror,
    phase: []const u8,
    attempt: u8,
    url: []const u8,
) !bool {
    if (!isRetryableTransportError(err) or attempt + 1 >= http_retry_max_attempts) {
        std.debug.print("Error {s} for '{s}': {s}\n", .{ phase, url, @errorName(err) });
        return false;
    }
    var reason_buf: [64]u8 = undefined;
    const reason = std.fmt.bufPrint(&reason_buf, "{s}: {s}", .{ phase, @errorName(err) }) catch @errorName(err);
    try sleepHttpRetry(io, backoffMilliseconds(attempt), reason, attempt);
    return true;
}

/// Stream-download `url` over HTTP(S) and convert to CSV under `output_folder`.
/// Uses a single sequential pipeline (no parallel seeks). Output matches a local-file run
/// with the same basename.
///
/// The GET is retried with exponential backoff on 429, 5xx, and transport
/// failures (connect / send / headers). Mid-body stream errors are not retried.
pub fn processFromRemoteUrl(
    io: Io,
    arena: std.mem.Allocator,
    url: []const u8,
    output_folder: []const u8,
) !u8 {
    Io.Dir.cwd().createDirPath(io, output_folder) catch |err| {
        std.debug.print("Error creating output directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    const uri = std.Uri.parse(url) catch |err| {
        std.debug.print("Error: invalid URL '{s}': {s}\n", .{ url, @errorName(err) });
        return 1;
    };

    const base_name = baseInputName(url);
    std.debug.print("Downloading and streaming {s}\n", .{url});

    // Client allocations must outlive the request; page allocator is thread-safe.
    var client: http.Client = .{
        .allocator = std.heap.page_allocator,
        .io = io,
    };
    defer client.deinit();

    var req: http.Client.Request = undefined;
    var req_live = false;
    defer if (req_live) req.deinit();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response: http.Client.Response = undefined;

    var attempt: u8 = 0;
    while (attempt < http_retry_max_attempts) {
        if (req_live) {
            req.deinit();
            req_live = false;
        }

        req = client.request(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = "ch-fixedwidth-parser" },
            },
            .keep_alive = false,
        }) catch |err| {
            if (!try maybeRetryTransport(io, err, "connecting", attempt, url)) return 1;
            attempt += 1;
            continue;
        };
        req_live = true;
        req.accept_encoding = remote_accept_encoding;

        req.sendBodiless() catch |err| {
            if (!try maybeRetryTransport(io, err, "sending HTTP request", attempt, url)) return 1;
            attempt += 1;
            continue;
        };

        response = req.receiveHead(&redirect_buf) catch |err| {
            if (!try maybeRetryTransport(io, err, "receiving HTTP headers", attempt, url)) return 1;
            attempt += 1;
            continue;
        };

        if (response.head.status.class() == .success) break;

        const status = response.head.status;
        const status_int = @intFromEnum(status);
        if (!isRetryableHttpStatus(status) or attempt + 1 >= http_retry_max_attempts) {
            std.debug.print(
                "Error: HTTP {d} {s} for {s}\n",
                .{ status_int, status.phrase() orelse "", url },
            );
            return 1;
        }

        var reason_buf: [32]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "HTTP {d}", .{status_int}) catch "HTTP error";
        const wait_ms = retryWaitMilliseconds(attempt, parseRetryAfterSeconds(response.head));
        try sleepHttpRetry(io, wait_ms, reason, attempt);
        attempt += 1;
    } else {
        return 1;
    }

    const encoding = response.head.content_encoding;
    if (encoding != .identity) {
        std.debug.print("Response is {s}-compressed; decompressing while streaming\n", .{@tagName(encoding)});
    }
    // Raw (transfer-decoded, still content-encoded) body bytes.
    const transfer_buf = try arena.alloc(u8, transferBufferLen(encoding));
    return processRemoteBody(io, arena, response.reader(transfer_buf), encoding, output_folder, base_name);
}

/// Convert a remote response body with the given `Content-Encoding`.
/// Identity bodies go straight to the parser; compressed bodies are wrapped in
/// the matching std decompressor, whose buffer then feeds the parser.
fn processRemoteBody(
    io: Io,
    arena: std.mem.Allocator,
    body: *Io.Reader,
    encoding: http.ContentEncoding,
    output_folder: []const u8,
    base_name: []const u8,
) !u8 {
    if (encoding == .compress) {
        // Never requested, so `receiveHead` rejects it; guard anyway.
        std.debug.print("Error: unsupported Content-Encoding: compress\n", .{});
        return 1;
    }
    const decompress_buf = try arena.alloc(u8, decompressBufferLen(encoding));
    var decompress: http.Decompress = undefined;
    const reader = http.Decompress.init(&decompress, body, decompress_buf, encoding);
    const code = try processFromReader(io, arena, reader, output_folder, base_name);
    // A decode failure surfaces from the reader as a bare `ReadFailed`; name it.
    const decode_err: ?anyerror = switch (decompress) {
        .zstd => |*d| d.err,
        .flate => |*d| d.err,
        .none => null,
    };
    // `ReadFailed` here is the transport failing underneath the decoder.
    if (decode_err) |err| if (err != error.ReadFailed) {
        std.debug.print("Error decompressing {s} body: {s}\n", .{ @tagName(encoding), @errorName(err) });
    };
    return code;
}

/// Content codings the CLI asks for on remote GETs. zstd first: Companies
/// Catalogue (Cloudflare) serves zstd straight from the stored object, about
/// 5.5x fewer bytes than identity and without on-the-fly re-compression (gzip
/// is re-compressed at the edge and is markedly slower). `std.http.Client`
/// emits these in enum order with zstd first, and `receiveHead` rejects any
/// coding not listed here.
const remote_accept_encoding = blk: {
    var flags = http.Client.Request.default_accept_encoding;
    flags[@intFromEnum(http.ContentEncoding.zstd)] = true;
    break :blk flags;
};

/// Body transfer buffer for `encoding`. Identity bodies are parsed straight
/// from it, so it is large; compressed bodies only pass compressed bytes to the
/// decompressor through it.
fn transferBufferLen(encoding: http.ContentEncoding) usize {
    return if (encoding == .identity) read_buffer_size else 64 * 1024;
}

/// Decompressor buffer length for `encoding` (0 for identity). zstd needs the
/// default 8 MiB window plus one 128 KiB block (Cloudflare's frames declare a
/// 2 MiB window; a frame over 8 MiB fails to decode). flate needs at least its
/// 64 KiB window; 1 MiB lets the parser see larger reads per feed.
fn decompressBufferLen(encoding: http.ContentEncoding) usize {
    return switch (encoding) {
        .identity, .compress => 0,
        .zstd => std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
        .deflate, .gzip => @max(std.compress.flate.max_window_len, 1024 * 1024),
    };
}

/// Stream-read a fixed-width file from process stdin and convert to CSV under `output_folder`.
/// Same sequential `processFromReader` path as single-stream local and remote URL input.
/// Output basenames use `stdin` (e.g. `companies_data_stdin.csv`).
pub fn processFromStdin(
    io: Io,
    arena: std.mem.Allocator,
    output_folder: []const u8,
    worker_count: ?usize,
) !u8 {
    Io.Dir.cwd().createDirPath(io, output_folder) catch |err| {
        std.debug.print("Error creating output directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    const base_name = baseInputName("-");
    std.debug.print("Reading from stdin\n", .{});

    const read_buf = try arena.alloc(u8, read_buffer_size);
    // Do not close stdin — process owns the standard handles.
    const stdin_file = Io.File.stdin();
    var file_reader = Io.File.Reader.initStreaming(stdin_file, io, read_buf);
    return processFromStreamReader(io, arena, &file_reader.interface, output_folder, base_name, worker_count);
}

/// Convert a non-seekable stream. Officers products (195 / 216 / 198) run on
/// the multi-threaded chunk pipeline when more than one worker is available;
/// 192 / 197 and single-worker runs use the sequential `processFromReader`.
fn processFromStreamReader(
    io: Io,
    arena: std.mem.Allocator,
    reader: *Io.Reader,
    output_folder: []const u8,
    base_name: []const u8,
    worker_count: ?usize,
) !u8 {
    const workers = resolveWorkerCount(worker_count);
    if (comptime builtin.single_threaded) {
        return processFromReader(io, arena, reader, output_folder, base_name);
    }
    if (workers > 1) {
        // Peek (do not consume) the header: the pipeline reads it again.
        if (reader.peekDelimiterInclusive('\n')) |line| {
            const row = parse.stripCr(line[0 .. line.len - 1]);
            const info = parse.parseHeader(row) catch null;
            if (info) |h| if (h.file_type == .officers_snapshot or h.file_type == .officers_update) {
                _ = processHeaderRow(row) catch return 1;
                return convertOfficersParallel(io, arena, reader, h.file_type, output_folder, base_name, workers, pipeline.default_chunk_len);
            };
        } else |_| {
            // No complete header line (empty input, read error, oversized
            // line): the sequential path reports it as before.
        }
    }
    return processFromReader(io, arena, reader, output_folder, base_name);
}

/// Convert a local file path, directory of `.dat` files, HTTP(S) URL, or stdin (`-`)
/// into CSV files under `output_folder`. Returns a process exit code (0 = success).
///
/// `worker_count` applies to officers products from local files and stdin
/// (chunk pipeline). Remote URLs and products 192 / 197 stay sequential.
/// `null` uses CPU count (capped at `max_workers`).
pub fn processInput(
    io: Io,
    arena: std.mem.Allocator,
    input: []const u8,
    output_folder: []const u8,
    worker_count: ?usize,
) !u8 {
    if (isStdinInput(input)) {
        return processFromStdin(io, arena, output_folder, worker_count);
    }
    if (isRemoteUrl(input)) {
        return processFromRemoteUrl(io, arena, input, output_folder);
    }

    const kind = resolveLocalInputKind(io, input) catch |err| {
        // Path missing or unreadable — prefer a clear message; fall back to open-as-file errors.
        if (looksLikeDirectoryInput(input)) {
            std.debug.print("Error accessing input directory '{s}': {s}\n", .{ input, @errorName(err) });
            return 1;
        }
        std.debug.print("Error accessing input '{s}': {s}\n", .{ input, @errorName(err) });
        return 1;
    };

    return switch (kind) {
        .directory => processDirectory(io, arena, input, output_folder, worker_count),
        .file => processLocalFile(io, arena, input, output_folder, worker_count),
    };
}

test "resolveWorkerCount clamps and defaults" {
    try std.testing.expectEqual(@as(usize, 1), resolveWorkerCount(1));
    try std.testing.expectEqual(@as(usize, 1), resolveWorkerCount(0));
    try std.testing.expectEqual(@as(usize, max_workers), resolveWorkerCount(max_workers + 8));
    try std.testing.expectEqual(@as(usize, 4), resolveWorkerCount(4));
    const auto = resolveWorkerCount(null);
    try std.testing.expect(auto >= 1);
    try std.testing.expect(auto <= max_workers);
}

test "isRetryableHttpStatus covers 429 and 5xx only" {
    try std.testing.expect(isRetryableHttpStatus(.too_many_requests));
    try std.testing.expect(isRetryableHttpStatus(.internal_server_error));
    try std.testing.expect(isRetryableHttpStatus(.bad_gateway));
    try std.testing.expect(isRetryableHttpStatus(.service_unavailable));
    try std.testing.expect(isRetryableHttpStatus(.gateway_timeout));
    try std.testing.expect(!isRetryableHttpStatus(.ok));
    try std.testing.expect(!isRetryableHttpStatus(.not_found));
    try std.testing.expect(!isRetryableHttpStatus(.forbidden));
    try std.testing.expect(!isRetryableHttpStatus(.moved_permanently));
}

test "isRetryableTransportError retries connection failures" {
    try std.testing.expect(isRetryableTransportError(error.ConnectionRefused));
    try std.testing.expect(isRetryableTransportError(error.NetworkUnreachable));
    try std.testing.expect(isRetryableTransportError(error.ReadFailed));
    try std.testing.expect(isRetryableTransportError(error.WriteFailed));
    try std.testing.expect(isRetryableTransportError(error.UnknownHostName));
    try std.testing.expect(!isRetryableTransportError(error.Canceled));
    try std.testing.expect(!isRetryableTransportError(error.UnsupportedUriScheme));
    try std.testing.expect(!isRetryableTransportError(error.HttpHeadersInvalid));
    try std.testing.expect(!isRetryableTransportError(error.TooManyHttpRedirects));
}

test "backoffMilliseconds doubles from 200 ms and caps" {
    try std.testing.expectEqual(@as(u64, 200), backoffMilliseconds(0));
    try std.testing.expectEqual(@as(u64, 400), backoffMilliseconds(1));
    try std.testing.expectEqual(@as(u64, 800), backoffMilliseconds(2));
    try std.testing.expectEqual(@as(u64, 1600), backoffMilliseconds(3));
    try std.testing.expectEqual(http_retry_max_ms, backoffMilliseconds(16));
}

test "parseRetryAfterSeconds reads delay-seconds and caps" {
    const with_retry = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\n\r\n";
    const head = try http.Client.Response.Head.parse(with_retry);
    try std.testing.expectEqual(@as(?u64, 7), parseRetryAfterSeconds(head));

    const mixed_case = "HTTP/1.1 503 Service Unavailable\r\nretry-after: 12\r\n\r\n";
    const head2 = try http.Client.Response.Head.parse(mixed_case);
    try std.testing.expectEqual(@as(?u64, 12), parseRetryAfterSeconds(head2));

    const huge = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 99999\r\n\r\n";
    const head3 = try http.Client.Response.Head.parse(huge);
    try std.testing.expectEqual(@as(?u64, http_retry_after_cap_s), parseRetryAfterSeconds(head3));

    const http_date = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: Wed, 21 Oct 2015 07:28:00 GMT\r\n\r\n";
    const head4 = try http.Client.Response.Head.parse(http_date);
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds(head4));

    const none = "HTTP/1.1 503 Service Unavailable\r\n\r\n";
    const head5 = try http.Client.Response.Head.parse(none);
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds(head5));
}

test "retryWaitMilliseconds prefers Retry-After over exponential" {
    try std.testing.expectEqual(@as(u64, 7000), retryWaitMilliseconds(0, 7));
    try std.testing.expectEqual(@as(u64, 200), retryWaitMilliseconds(0, null));
}

test "isRemoteUrl detects http and https" {
    try std.testing.expect(isRemoteUrl("http://example.com/a.dat"));
    try std.testing.expect(isRemoteUrl("https://example.com/a.dat"));
    try std.testing.expect(isRemoteUrl("HTTP://EXAMPLE.COM/a.dat"));
    try std.testing.expect(isRemoteUrl("HTTPS://EXAMPLE.COM/a.dat"));
    try std.testing.expect(!isRemoteUrl("file:///tmp/a.dat"));
    try std.testing.expect(!isRemoteUrl("Prod216_4257_ew_6.dat"));
    try std.testing.expect(!isRemoteUrl("./http://not-a-url.dat"));
    try std.testing.expect(!isRemoteUrl(""));
    try std.testing.expect(!isRemoteUrl("-"));
}

test "isStdinInput only matches dash" {
    try std.testing.expect(isStdinInput("-"));
    try std.testing.expect(!isStdinInput(""));
    try std.testing.expect(!isStdinInput("--"));
    try std.testing.expect(!isStdinInput("-.dat"));
    try std.testing.expect(!isStdinInput("./-"));
    try std.testing.expect(!isStdinInput("stdin"));
    try std.testing.expect(!isStdinInput("http://example.com/-"));
}

test "hasDatExtension and looksLikeDirectoryInput heuristics" {
    try std.testing.expect(hasDatExtension("file.dat"));
    try std.testing.expect(hasDatExtension("file.DAT"));
    try std.testing.expect(hasDatExtension("path/to/file.Dat"));
    try std.testing.expect(!hasDatExtension("file.csv"));
    try std.testing.expect(!hasDatExtension("file.dat.bak"));
    try std.testing.expect(!hasDatExtension("dat"));
    try std.testing.expect(!hasDatExtension(""));

    try std.testing.expect(pathEndsWithSep("dir/"));
    try std.testing.expect(pathEndsWithSep("dir\\"));
    try std.testing.expect(!pathEndsWithSep("dir"));
    try std.testing.expect(!pathEndsWithSep("file.dat"));

    try std.testing.expect(!looksLikeDirectoryInput("file.dat"));
    try std.testing.expect(!looksLikeDirectoryInput("path/to/file.DAT"));
    try std.testing.expect(looksLikeDirectoryInput("snapshots/"));
    try std.testing.expect(looksLikeDirectoryInput("snapshots\\"));
    try std.testing.expect(looksLikeDirectoryInput("snapshots"));
    try std.testing.expect(looksLikeDirectoryInput("path/to/dir"));
}

test "baseInputName for local paths, URLs, and stdin" {
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("src/testdata/mini_snapshot.dat"));
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("mini_snapshot.dat"));
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("http://localhost:8765/mini_snapshot.dat"));
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("https://cdn.example.com/path/to/mini_snapshot.dat?token=abc"));
    try std.testing.expectEqualStrings("download", baseInputName("http://localhost:8765/"));
    try std.testing.expectEqualStrings("stdin", baseInputName("-"));
}

const mini_snapshot_fixture = @embedFile("testdata/mini_snapshot.dat");
const expected_companies_fixture = @embedFile("testdata/expected_companies.csv");
const expected_persons_fixture = @embedFile("testdata/expected_persons.csv");
const split_snapshot_fixture = @embedFile("testdata/mini_snapshot_split.dat");
const expected_split_companies_fixture = @embedFile("testdata/expected_split_companies.csv");
const expected_split_persons_fixture = @embedFile("testdata/expected_split_persons.csv");

fn readFileAlloc(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    var read_buf: [64 * 1024]u8 = undefined;
    var file_reader = Io.File.Reader.initStreaming(file, io, &read_buf);
    try file_reader.interface.readSliceAll(buf);
    return buf;
}

test "processFromReader streams fixture like stdin and remote" {
    // Same sequential pipeline used by processFromStdin / processFromRemoteUrl /
    // processSingle: an Io.Reader of snapshot bytes → CSV under output_folder.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var reader = Io.Reader.fixed(mini_snapshot_fixture);
    const code = try processFromReader(io, arena, &reader, out_rel, "stdin");
    try std.testing.expectEqual(@as(u8, 0), code);

    const companies_path = try std.fmt.allocPrint(arena, "{s}/companies_data_stdin.csv", .{out_rel});
    const persons_path = try std.fmt.allocPrint(arena, "{s}/persons_data_stdin.csv", .{out_rel});

    const companies = try readFileAlloc(io, arena, companies_path);
    const persons = try readFileAlloc(io, arena, persons_path);
    try std.testing.expectEqualStrings(expected_companies_fixture, companies);
    try std.testing.expectEqualStrings(expected_persons_fixture, persons);
}

/// Build an officers snapshot of at least `min_bytes` by repeating the mini
/// fixture body, with a matching trailer count.
fn buildLargeSnapshot(allocator: std.mem.Allocator, min_bytes: usize) ![]u8 {
    var lines = std.mem.tokenizeScalar(u8, mini_snapshot_fixture, '\n');
    const header = lines.next().?;
    const body_start = @intFromPtr(lines.peek().?.ptr) - @intFromPtr(mini_snapshot_fixture.ptr);
    var body_lines: usize = 0;
    var body_end: usize = body_start;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "99999999")) break;
        body_lines += 1;
        body_end = @intFromPtr(line.ptr) - @intFromPtr(mini_snapshot_fixture.ptr) + line.len + 1;
    }
    const body = mini_snapshot_fixture[body_start..body_end];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, header);
    try out.append(allocator, '\n');
    var records: usize = 0;
    while (out.items.len < min_bytes) {
        try out.appendSlice(allocator, body);
        records += body_lines;
    }
    try out.print(allocator, "99999999{d:0>8}\n", .{records});
    return out.toOwnedSlice(allocator);
}

test "processFromReader stream memory stays bounded independent of input size" {
    // Regression for streaming URL/stdin memory growing with the whole file:
    // every drained CSV batch must be released, so the Stream's live heap stays
    // near one feed slice even when the input is many times larger.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input_bytes: usize = 12 * stream_feed_slice;
    const stream_limit: usize = 4 * stream_feed_slice;

    const input = try buildLargeSnapshot(std.testing.allocator, input_bytes);
    defer std.testing.allocator.free(input);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var gpa_state: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    gpa_state.requested_memory_limit = stream_limit;
    {
        var reader = Io.Reader.fixed(input);
        const code = try processFromReaderWithAllocator(io, arena, gpa_state.allocator(), &reader, out_rel, "big");
        try std.testing.expectEqual(@as(u8, 0), code);
        // Everything the Stream allocated has been returned.
        try std.testing.expectEqual(@as(usize, 0), gpa_state.total_requested_bytes);
    }
    try std.testing.expectEqual(std.heap.Check.ok, gpa_state.deinit());

    // Output is complete: header + one row per company record.
    const companies_path = try std.fmt.allocPrint(arena, "{s}/companies_data_big.csv", .{out_rel});
    const companies = try readFileAlloc(io, arena, companies_path);
    const expected_rows = std.mem.count(u8, expected_companies_fixture, "\n") - 1;
    const got_rows = std.mem.count(u8, companies, "\n") - 1;
    try std.testing.expect(got_rows > expected_rows * 1000);
    try std.testing.expectEqual(@as(usize, 0), got_rows % expected_rows);
}

test "parallel and sequential officers paths produce identical CSV" {
    // processSingle uses stream.Stream; processParallel uses seek-split workers.
    // Both must byte-match on the officers snapshot fixture (and expected CSVs).
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "mini.dat", .data = mini_snapshot_fixture });
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const input_path = try std.fmt.allocPrint(arena, "{s}/mini.dat", .{base});
    const out_seq = try std.fmt.allocPrint(arena, "{s}/out_seq", .{base});
    const out_par = try std.fmt.allocPrint(arena, "{s}/out_par", .{base});
    try Io.Dir.cwd().createDirPath(io, out_seq);
    try Io.Dir.cwd().createDirPath(io, out_par);

    const code_seq = try processSingle(io, arena, input_path, out_seq, "mini");
    try std.testing.expectEqual(@as(u8, 0), code_seq);

    // Use multiple workers so the split/concat path runs (still correct with 1 range).
    const code_par = try processParallel(io, arena, input_path, out_par, "mini", 4);
    try std.testing.expectEqual(@as(u8, 0), code_par);

    const seq_c = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_mini.csv", .{out_seq}));
    const seq_p = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/persons_data_mini.csv", .{out_seq}));
    const par_c = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_mini.csv", .{out_par}));
    const par_p = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/persons_data_mini.csv", .{out_par}));

    try std.testing.expectEqualStrings(seq_c, par_c);
    try std.testing.expectEqualStrings(seq_p, par_p);
    try std.testing.expectEqualStrings(expected_companies_fixture, seq_c);
    try std.testing.expectEqualStrings(expected_persons_fixture, seq_p);
}

test "parallel split never starts a worker inside a re-joined record" {
    // Records broken by embedded CRLF / LF must stay with the worker that reads
    // their first line, whatever the worker count (split points vary with it).
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "split.dat", .data = split_snapshot_fixture });
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const input_path = try std.fmt.allocPrint(arena, "{s}/split.dat", .{base});

    // Every chunk size from 1 byte up to the whole file: chunk boundaries
    // land everywhere, including inside split records, and must never cut one.
    var chunk_len: usize = 1;
    while (chunk_len <= split_snapshot_fixture.len) : (chunk_len += 1) {
        const out_chunk = try std.fmt.allocPrint(arena, "{s}/out_chunk_{d}", .{ base, chunk_len });
        try Io.Dir.cwd().createDirPath(io, out_chunk);
        try std.testing.expectEqual(@as(u8, 0), try processParallelChunked(io, arena, input_path, out_chunk, "split", 3, chunk_len));
        try std.testing.expectEqualStrings(
            expected_split_companies_fixture,
            try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_split.csv", .{out_chunk})),
        );
        try std.testing.expectEqualStrings(
            expected_split_persons_fixture,
            try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/persons_data_split.csv", .{out_chunk})),
        );
    }

    const out_seq = try std.fmt.allocPrint(arena, "{s}/out_seq", .{base});
    try Io.Dir.cwd().createDirPath(io, out_seq);
    try std.testing.expectEqual(@as(u8, 0), try processSingle(io, arena, input_path, out_seq, "split"));
    try std.testing.expectEqualStrings(
        expected_split_companies_fixture,
        try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_split.csv", .{out_seq})),
    );
    try std.testing.expectEqualStrings(
        expected_split_persons_fixture,
        try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/persons_data_split.csv", .{out_seq})),
    );

    var workers: usize = 2;
    while (workers <= 16) : (workers += 1) {
        const out_par = try std.fmt.allocPrint(arena, "{s}/out_par_{d}", .{ base, workers });
        try Io.Dir.cwd().createDirPath(io, out_par);
        try std.testing.expectEqual(@as(u8, 0), try processParallel(io, arena, input_path, out_par, "split", workers));
        try std.testing.expectEqualStrings(
            expected_split_companies_fixture,
            try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_split.csv", .{out_par})),
        );
        try std.testing.expectEqualStrings(
            expected_split_persons_fixture,
            try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/persons_data_split.csv", .{out_par})),
        );
    }
}

const mini_snapshot_gzip_fixture = @embedFile("testdata/mini_snapshot.dat.gz");

/// Wrap `data` in a zstd frame made of raw (stored) blocks of `block_len`
/// bytes. `window_descriptor` is the frame header's window byte (0x58 = 2 MiB,
/// what Cloudflare's frames declare). Std has no zstd compressor; stored blocks
/// still exercise frame parsing, the window check, and buffer sizing.
fn buildStoredZstdFrame(allocator: std.mem.Allocator, data: []const u8, block_len: usize, window_descriptor: u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0x28, 0xB5, 0x2F, 0xFD }); // magic
    try out.append(allocator, 0x00); // no content size, not single-segment, no checksum
    try out.append(allocator, window_descriptor);
    var off: usize = 0;
    while (true) {
        const n = @min(block_len, data.len - off);
        const last: u24 = @intFromBool(off + n == data.len);
        const header: u24 = (@as(u24, @intCast(n)) << 3) | last; // block type 0 = raw
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u24, header))[0..3].*);
        try out.appendSlice(allocator, data[off..][0..n]);
        off += n;
        if (last == 1) break;
    }
    return out.toOwnedSlice(allocator);
}

fn expectRemoteBodyConverts(encoding: http.ContentEncoding, body_bytes: []const u8) !void {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    try Io.Dir.cwd().createDirPath(io, out_rel);

    var body = Io.Reader.fixed(body_bytes);
    try std.testing.expectEqual(@as(u8, 0), try processRemoteBody(io, arena, &body, encoding, out_rel, "remote"));

    const companies = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_remote.csv", .{out_rel}));
    const persons = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/persons_data_remote.csv", .{out_rel}));
    try std.testing.expectEqualStrings(expected_companies_fixture, companies);
    try std.testing.expectEqualStrings(expected_persons_fixture, persons);
}

test "remote GET asks for zstd, gzip and deflate as well as identity" {
    try std.testing.expect(remote_accept_encoding[@intFromEnum(http.ContentEncoding.zstd)]);
    try std.testing.expect(remote_accept_encoding[@intFromEnum(http.ContentEncoding.gzip)]);
    try std.testing.expect(remote_accept_encoding[@intFromEnum(http.ContentEncoding.deflate)]);
    try std.testing.expect(remote_accept_encoding[@intFromEnum(http.ContentEncoding.identity)]);
    try std.testing.expect(!remote_accept_encoding[@intFromEnum(http.ContentEncoding.compress)]);
}

test "processRemoteBody converts identity, zstd and gzip bodies alike" {
    try expectRemoteBodyConverts(.identity, mini_snapshot_fixture);

    // Several small blocks so lines straddle block boundaries.
    const zst = try buildStoredZstdFrame(std.testing.allocator, mini_snapshot_fixture, 97, 0x58);
    defer std.testing.allocator.free(zst);
    try expectRemoteBodyConverts(.zstd, zst);

    // `gzip -n -9 mini_snapshot.dat`
    try expectRemoteBodyConverts(.gzip, mini_snapshot_gzip_fixture);
}

test "processRemoteBody fails cleanly on a zstd window over 8 MiB" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    try Io.Dir.cwd().createDirPath(io, out_rel);

    // Window descriptor 0x70: 2^24 = 16 MiB, above the decoder's 8 MiB window.
    const zst = try buildStoredZstdFrame(std.testing.allocator, mini_snapshot_fixture, 4096, 0x70);
    defer std.testing.allocator.free(zst);
    var body = Io.Reader.fixed(zst);
    try std.testing.expectEqual(@as(u8, 1), try processRemoteBody(io, arena, &body, .zstd, out_rel, "remote"));
}

const mini_update_fixture = @embedFile("testdata/mini_update.dat");
const expected_update_companies_fixture = @embedFile("testdata/expected_update_companies.csv");
const expected_update_persons_fixture = @embedFile("testdata/expected_update_persons.csv");

/// Run the chunked parallel path on `input` and return (exit code, companies, persons).
fn runChunked(arena: std.mem.Allocator, input: []const u8, workers: usize, chunk_len: usize) !struct { u8, []u8, []u8 } {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.dat", .data = input });
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const input_path = try std.fmt.allocPrint(arena, "{s}/in.dat", .{base});
    const out = try std.fmt.allocPrint(arena, "{s}/out", .{base});
    try Io.Dir.cwd().createDirPath(io, out);
    const code = try processParallelChunked(io, arena, input_path, out, "in", workers, chunk_len);
    const c = readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_in.csv", .{out})) catch try arena.dupe(u8, "");
    const p = readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/persons_data_in.csv", .{out})) catch try arena.dupe(u8, "");
    return .{ code, c, p };
}

test "chunked parallel path matches expected CSV for every chunk size and worker count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ mini_snapshot_fixture, expected_companies_fixture, expected_persons_fixture },
        .{ mini_update_fixture, expected_update_companies_fixture, expected_update_persons_fixture },
    };
    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 8 }) |workers| {
            var chunk_len: usize = 1;
            while (chunk_len <= case[0].len + 1) : (chunk_len += 7) {
                const code, const companies, const persons = try runChunked(arena, case[0], workers, chunk_len);
                try std.testing.expectEqual(@as(u8, 0), code);
                try std.testing.expectEqualStrings(case[1], companies);
                try std.testing.expectEqualStrings(case[2], persons);
            }
        }
    }
}

test "chunked parallel path rejects data after the trailer, even in a later chunk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const trailer = std.mem.indexOf(u8, mini_snapshot_fixture, "99999999").?;
    // Body, trailer, then a repeat of the body after the trailer.
    const input = try std.mem.concat(arena, u8, &.{
        mini_snapshot_fixture,
        mini_snapshot_fixture[std.mem.indexOfScalar(u8, mini_snapshot_fixture, '\n').? + 1 .. trailer],
    });
    for ([_]usize{ 64, 300, 1 << 20 }) |chunk_len| {
        const code, _, _ = try runChunked(arena, input, 3, chunk_len);
        try std.testing.expectEqual(@as(u8, 1), code);
    }
    // Trailing blank lines after the trailer are still fine.
    const blank_tail = try std.mem.concat(arena, u8, &.{ mini_snapshot_fixture, "   \n\t\n\n" });
    const code, _, _ = try runChunked(arena, blank_tail, 3, 64);
    try std.testing.expectEqual(@as(u8, 0), code);
}

test "chunked parallel path fails on unknown records, missing or wrong trailers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const trailer = std.mem.indexOf(u8, mini_snapshot_fixture, "99999999").?;

    const garbage = try std.mem.concat(arena, u8, &.{ mini_snapshot_fixture[0..trailer], "GARBAGE LINE\n", mini_snapshot_fixture[trailer..] });
    const no_trailer = mini_snapshot_fixture[0..trailer];
    const wrong_trailer = try std.mem.concat(arena, u8, &.{ mini_snapshot_fixture[0..trailer], "9999999900000099\n" });
    for ([_][]const u8{ garbage, no_trailer, wrong_trailer }) |input| {
        for ([_]usize{ 50, 1 << 20 }) |chunk_len| {
            const code, _, _ = try runChunked(arena, input, 2, chunk_len);
            try std.testing.expectEqual(@as(u8, 1), code);
        }
    }
}

fn runStream(arena: std.mem.Allocator, input: []const u8, workers: usize) !struct { u8, []const u8 } {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    try Io.Dir.cwd().createDirPath(io, out);
    var reader = Io.Reader.fixed(input);
    const code = try processFromStreamReader(io, arena, &reader, out, "stdin", workers);
    // Concatenate every output file (sorted by name) for comparison.
    var names: std.ArrayList([]const u8) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, out, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| try names.append(arena, try arena.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var all: std.ArrayList(u8) = .empty;
    for (names.items) |n| {
        try all.print(arena, "== {s}\n", .{n});
        try all.appendSlice(arena, try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ out, n })));
    }
    return .{ code, all.items };
}

test "stdin stream route: parallel officers output matches the sequential path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inputs = [_][]const u8{
        mini_snapshot_fixture,
        mini_update_fixture,
        split_snapshot_fixture,
        @embedFile("testdata/mini_disqual.dat"),
        @embedFile("testdata/mini_liquidation.dat"),
    };
    for (inputs) |input| {
        const seq_code, const seq = try runStream(arena, input, 1);
        try std.testing.expectEqual(@as(u8, 0), seq_code);
        for ([_]usize{ 2, 4, 8 }) |workers| {
            const par_code, const par = try runStream(arena, input, workers);
            try std.testing.expectEqual(seq_code, par_code);
            try std.testing.expectEqualStrings(seq, par);
        }
    }
}

test "stdin stream route: failures exit 1 on both paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const trailer = std.mem.indexOf(u8, mini_snapshot_fixture, "99999999").?;
    const bad = [_][]const u8{
        "",
        "DDDDSNAP425720260706",
        "NOTAHEADER\n",
        mini_snapshot_fixture[0..trailer],
        try std.mem.concat(arena, u8, &.{ mini_snapshot_fixture[0..trailer], "GARBAGE\n", mini_snapshot_fixture[trailer..] }),
    };
    for (bad) |input| {
        for ([_]usize{ 1, 4 }) |workers| {
            const code, _ = try runStream(arena, input, workers);
            try std.testing.expectEqual(@as(u8, 1), code);
        }
    }
}

test "resolveLocalInputKind distinguishes file and directory" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "one.dat", .data = mini_snapshot_fixture });
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const file_path = try std.fmt.allocPrint(arena, "{s}/one.dat", .{base});
    const dir_path = base;
    const dir_with_sep = try std.fmt.allocPrint(arena, "{s}/", .{base});

    try std.testing.expectEqual(LocalInputKind.file, try resolveLocalInputKind(io, file_path));
    try std.testing.expectEqual(LocalInputKind.directory, try resolveLocalInputKind(io, dir_path));
    try std.testing.expectEqual(LocalInputKind.directory, try resolveLocalInputKind(io, dir_with_sep));
}

test "listDatFilesInDir finds only .dat files sorted" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "b_second.dat", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a_first.dat", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "skip.csv", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "readme.txt", .data = "y" });

    const dir_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const files = try listDatFilesInDir(io, arena, dir_path);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(std.mem.endsWith(u8, files[0], "a_first.dat"));
    try std.testing.expect(std.mem.endsWith(u8, files[1], "b_second.dat"));
}

test "processDirectory converts each .dat to company and person CSVs" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "snap_a.dat", .data = mini_snapshot_fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "snap_b.dat", .data = mini_snapshot_fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignore me" });

    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const in_dir = base;
    const out_dir = try std.fmt.allocPrint(arena, "{s}/out", .{base});

    const code = try processDirectory(io, arena, in_dir, out_dir, null);
    try std.testing.expectEqual(@as(u8, 0), code);

    const names = [_][]const u8{ "snap_a", "snap_b" };
    for (names) |name| {
        const companies_path = try std.fmt.allocPrint(arena, "{s}/companies_data_{s}.csv", .{ out_dir, name });
        const persons_path = try std.fmt.allocPrint(arena, "{s}/persons_data_{s}.csv", .{ out_dir, name });
        const companies = try readFileAlloc(io, arena, companies_path);
        const persons = try readFileAlloc(io, arena, persons_path);
        try std.testing.expectEqualStrings(expected_companies_fixture, companies);
        try std.testing.expectEqualStrings(expected_persons_fixture, persons);
    }
}

test "processInput routes directory path to multi-file conversion" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "batch1.dat", .data = mini_snapshot_fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "batch2.dat", .data = mini_snapshot_fixture });

    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const out_dir = try std.fmt.allocPrint(arena, "{s}/csv", .{base});

    // Trailing separator is accepted and still resolves as a directory.
    const in_dir = try std.fmt.allocPrint(arena, "{s}/", .{base});
    const code = try processInput(io, arena, in_dir, out_dir, null);
    try std.testing.expectEqual(@as(u8, 0), code);

    const c1 = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_batch1.csv", .{out_dir}));
    const c2 = try readFileAlloc(io, arena, try std.fmt.allocPrint(arena, "{s}/companies_data_batch2.csv", .{out_dir}));
    try std.testing.expectEqualStrings(expected_companies_fixture, c1);
    try std.testing.expectEqualStrings(expected_companies_fixture, c2);
}

test "processDirectory returns error when no .dat files present" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "only.txt", .data = "nope" });
    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const out_dir = try std.fmt.allocPrint(arena, "{s}/out", .{base});

    const code = try processDirectory(io, arena, base, out_dir, null);
    try std.testing.expectEqual(@as(u8, 1), code);
}
