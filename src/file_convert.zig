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

// Smaller buffers under single-threaded (wasm32-wasi) to stay within linear memory
// and avoid host WASI edge cases with multi‑MB vectored I/O.
const read_buffer_size: usize = if (builtin.single_threaded) 1 * 1024 * 1024 else 8 * 1024 * 1024;
const write_buffer_size: usize = if (builtin.single_threaded) 1 * 1024 * 1024 else 8 * 1024 * 1024;
const max_workers = 32;

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

fn writeCompanyRow(out: *CsvOut, row: []const u8) !void {
    const dest = try out.beginRow();
    const p = parse.formatCompanyRow(dest, row);
    out.endRow(p);
}

fn writePersonRow(out: *CsvOut, file_type: parse.FileType, row: []const u8) !void {
    const dest = try out.beginRow();
    const p = switch (file_type) {
        .officers_snapshot => parse.formatPersonRow(dest, row),
        .officers_update => parse.formatUpdatePersonRow(dest, row),
        .disqualifications, .liquidation => return error.NotImplemented,
    };
    out.endRow(p);
}

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

const WorkerResult = struct {
    companies: i32 = 0,
    persons: i32 = 0,
    trailer_count: ?i32 = null,
    err_msg: ?[]const u8 = null,
};

const WorkerCtx = struct {
    io: Io,
    input_path: []const u8,
    companies_path: []const u8,
    persons_path: []const u8,
    file_type: parse.FileType,
    /// Inclusive start file offset (first byte of first line to process).
    start_off: u64,
    /// Exclusive end file offset (do not process lines starting at or after this).
    end_off: u64,
    /// If true, first line in range is the product header (already validated).
    handle_header: bool,
    /// If true, write CSV headers.
    write_headers: bool,
    /// Thread-local buffers (owned by parent, not freed by worker).
    read_buf: []u8,
    companies_buf: []u8,
    persons_buf: []u8,
    result: *WorkerResult,
};

fn workerMain(ctx: *WorkerCtx) void {
    ctx.result.* = runWorker(ctx) catch |err| .{
        .err_msg = @errorName(err),
    };
}

fn runWorker(ctx: *WorkerCtx) !WorkerResult {
    var result: WorkerResult = .{};

    const input_file = try Io.Dir.cwd().openFile(ctx.io, ctx.input_path, .{});
    defer input_file.close(ctx.io);

    var file_reader = Io.File.Reader.init(input_file, ctx.io, ctx.read_buf);
    try file_reader.seekTo(ctx.start_off);
    const reader = &file_reader.interface;

    var companies_out = try CsvOut.create(
        ctx.io,
        ctx.companies_path,
        if (ctx.write_headers) parse.companies_header else null,
        ctx.companies_buf,
    );
    defer companies_out.close();

    var persons_out = try CsvOut.create(
        ctx.io,
        ctx.persons_path,
        if (ctx.write_headers) ctx.file_type.personsCsvHeader() else null,
        ctx.persons_buf,
    );
    defer persons_out.close();

    var first = true;
    while (true) {
        const line_start = file_reader.logicalPos();
        if (line_start >= ctx.end_off and !first) break;

        const maybe_line = try reader.takeDelimiter('\n');
        const row = parse.stripCr(maybe_line orelse break);

        if (first and ctx.handle_header) {
            // Header already validated by the parent before workers spawn.
            first = false;
            continue;
        }
        first = false;

        if (line_start >= ctx.end_off) break;

        if (row.len >= 8 and std.mem.eql(u8, row[0..8], parse.trailer_record_identifier)) {
            result.trailer_count = parse.parseTrailerCount(row);
            break;
        }

        if (row.len <= 8) continue;

        // Officers snapshot / update body (record type at byte 8).
        switch (row[8]) {
            parse.company_record_type => {
                try writeCompanyRow(&companies_out, row);
                result.companies += 1;
            },
            parse.person_record_type => {
                try writePersonRow(&persons_out, ctx.file_type, row);
                result.persons += 1;
            },
            else => {},
        }
    }

    return result;
}

/// Find the file offset of the first byte of the line that contains or follows `target`.
fn findLineStartAfter(io: Io, path: []const u8, target: u64, file_size: u64, scratch: []u8) !u64 {
    if (target == 0) return 0;
    if (target >= file_size) return file_size;

    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var reader = Io.File.Reader.init(file, io, scratch);
    const seek_to = if (target > 0) target -| 1 else 0;
    try reader.seekTo(seek_to);

    while (reader.logicalPos() < file_size) {
        const pos_before = reader.logicalPos();
        const maybe = try reader.interface.takeDelimiter('\n');
        if (maybe == null) return file_size;
        if (pos_before < target) {
            const next = reader.logicalPos();
            if (next >= target) return next;
            continue;
        }
        return pos_before;
    }
    return file_size;
}

fn concatFiles(io: Io, dest_path: []const u8, parts: []const []const u8, write_buf: []u8, read_buf: []u8) !void {
    const dest = try Io.Dir.cwd().createFile(io, dest_path, .{});
    defer dest.close(io);
    var dest_writer = Io.File.Writer.initStreaming(dest, io, write_buf);
    const dw = &dest_writer.interface;
    defer dw.flush() catch {};

    for (parts) |part_path| {
        const src = try Io.Dir.cwd().openFile(io, part_path, .{});
        defer src.close(io);
        var src_reader = Io.File.Reader.init(src, io, read_buf);
        _ = try dw.sendFileAll(&src_reader, .unlimited);
    }
}

fn processParallel(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
    base_name: []const u8,
    n_workers: usize,
) !u8 {
    const input_file = try Io.Dir.cwd().openFile(io, input_path, .{});
    const file_size = (try input_file.stat(io)).size;
    input_file.close(io);

    const workers = @max(1, @min(n_workers, max_workers));

    const probe_buf = try arena.alloc(u8, 1024 * 1024);

    // Identify product from the header before splitting so every worker uses
    // the correct person formatter / CSV header.
    const header_info = blk: {
        const f = try Io.Dir.cwd().openFile(io, input_path, .{});
        defer f.close(io);
        var fr = Io.File.Reader.init(f, io, probe_buf);
        const maybe = try fr.interface.takeDelimiter('\n');
        const row = parse.stripCr(maybe orelse {
            std.debug.print("ERROR: empty input\n", .{});
            return 1;
        });
        break :blk processHeaderRow(row) catch return 1;
    };

    var starts: [max_workers + 1]u64 = undefined;
    starts[0] = 0;
    starts[workers] = file_size;
    var w_i: usize = 1;
    while (w_i < workers) : (w_i += 1) {
        const target = (file_size * w_i) / workers;
        starts[w_i] = try findLineStartAfter(io, input_path, target, file_size, probe_buf);
    }

    var ranges: [max_workers]struct { start: u64, end: u64 } = undefined;
    var n_ranges: usize = 0;
    {
        var i: usize = 0;
        while (i < workers) : (i += 1) {
            if (starts[i] >= starts[i + 1]) continue;
            ranges[n_ranges] = .{ .start = starts[i], .end = starts[i + 1] };
            n_ranges += 1;
        }
    }
    if (n_ranges == 0) {
        std.debug.print("ERROR: empty input\n", .{});
        return 1;
    }

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

    const parts_dir = try std.fs.path.join(arena, &.{ output_folder, ".zig_parts" });
    Io.Dir.cwd().createDirPath(io, parts_dir) catch |err| {
        std.debug.print("Error creating parts directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    var ctxs: [max_workers]WorkerCtx = undefined;
    var results: [max_workers]WorkerResult = undefined;
    var threads: [max_workers]Thread = undefined;

    var r: usize = 0;
    while (r < n_ranges) : (r += 1) {
        const co = try std.fmt.allocPrint(arena, "{s}/c_{d}.csv", .{ parts_dir, r });
        const pe = try std.fmt.allocPrint(arena, "{s}/p_{d}.csv", .{ parts_dir, r });
        ctxs[r] = .{
            .io = io,
            .input_path = input_path,
            .companies_path = co,
            .persons_path = pe,
            .file_type = header_info.file_type,
            .start_off = ranges[r].start,
            .end_off = ranges[r].end,
            .handle_header = (r == 0),
            .write_headers = (r == 0),
            .read_buf = try arena.alloc(u8, read_buffer_size),
            .companies_buf = try arena.alloc(u8, write_buffer_size),
            .persons_buf = try arena.alloc(u8, write_buffer_size),
            .result = &results[r],
        };
        results[r] = .{};
    }

    if (n_ranges == 1) {
        workerMain(&ctxs[0]);
    } else if (comptime builtin.single_threaded) {
        var t: usize = 0;
        while (t < n_ranges) : (t += 1) {
            workerMain(&ctxs[t]);
        }
    } else {
        var t: usize = 1;
        while (t < n_ranges) : (t += 1) {
            threads[t] = try Thread.spawn(.{}, workerMain, .{&ctxs[t]});
        }
        workerMain(&ctxs[0]);
        t = 1;
        while (t < n_ranges) : (t += 1) {
            threads[t].join();
        }
    }

    var companies_total: i32 = 0;
    var persons_total: i32 = 0;
    var trailer_count: ?i32 = null;
    r = 0;
    while (r < n_ranges) : (r += 1) {
        if (results[r].err_msg) |msg| {
            std.debug.print("Error in worker {d}: {s}\n", .{ r, msg });
            return 1;
        }
        companies_total += results[r].companies;
        persons_total += results[r].persons;
        if (results[r].trailer_count) |tc| trailer_count = tc;
    }

    var company_parts: [max_workers][]const u8 = undefined;
    var person_parts: [max_workers][]const u8 = undefined;
    r = 0;
    while (r < n_ranges) : (r += 1) {
        company_parts[r] = ctxs[r].companies_path;
        person_parts[r] = ctxs[r].persons_path;
    }

    const concat_write = try arena.alloc(u8, write_buffer_size);
    const concat_read = try arena.alloc(u8, read_buffer_size);
    try concatFiles(io, companies_filename, company_parts[0..n_ranges], concat_write, concat_read);
    try concatFiles(io, persons_filename, person_parts[0..n_ranges], concat_write, concat_read);

    r = 0;
    while (r < n_ranges) : (r += 1) {
        Io.Dir.cwd().deleteFile(io, ctxs[r].companies_path) catch {};
        Io.Dir.cwd().deleteFile(io, ctxs[r].persons_path) catch {};
    }
    Io.Dir.cwd().deleteDir(io, parts_dir) catch {};

    const total = companies_total + persons_total;
    if (trailer_count) |tc| {
        if (tc != total) {
            std.debug.print("ERROR: Processed {d} records out of {d}\n", .{ total, tc });
            return 1;
        }
    } else {
        std.debug.print("ERROR: No trailer record found.\n", .{});
        return 1;
    }

    std.debug.print("Processed {d} records: {d} companies, {d} persons.\n", .{ total, companies_total, persons_total });
    return 0;
}

/// Write one stream CSV batch to the matching output file (created lazily).
/// Batch bytes already include the CSV header when it is the first flush for that kind.
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
        const idx: usize = @intCast(@intFromEnum(b.kind));
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

/// Stream input from `reader` into product-specific CSVs under `output_folder`.
/// Uses the shared `stream.Stream` body parser (same as one-shot / WASM).
/// Caller must ensure `output_folder` exists. Same output layout as a local file run.
pub fn processFromReader(
    io: Io,
    arena: std.mem.Allocator,
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

    var s = stream_mod.Stream.init(arena, .{
        .batch_rows = 0, // defaults
        .batch_bytes = write_buffer_size,
    });
    // Arena-backed; no explicit deinit required for process lifetime.

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

    // Feed the remainder in large chunks (Stream handles partial lines).
    const feed_buf = try arena.alloc(u8, read_buffer_size);
    while (true) {
        const n = reader.readSliceShort(feed_buf) catch |err| {
            std.debug.print("Error reading input: {s}\n", .{@errorName(err)});
            return 1;
        };
        if (n == 0) break;
        s.feed(feed_buf[0..n]) catch |err| {
            std.debug.print("Error parsing input: {s}\n", .{@errorName(err)});
            return 1;
        };
        if ((try drainStreamBatches(io, arena, &s, output_folder, base_name, &outs, &write_bufs)) != 0)
            return 1;
    }

    s.finish() catch |err| {
        switch (err) {
            error.MissingTrailer => std.debug.print("ERROR: No trailer record found.\n", .{}),
            error.TrailerMismatch => std.debug.print("ERROR: Trailer record count does not match rows parsed\n", .{}),
            else => std.debug.print("Error finishing parse: {s}\n", .{@errorName(err)}),
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

/// Convert one local fixed-width file (assumes `output_folder` already exists).
/// On multi-core native builds, officers products split the file across workers.
/// Prod 192 / 197 always use the sequential path (multi-CSV / form-group state).
fn processOneLocalFile(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
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

    const cpu_count = Thread.getCpuCount() catch 1;
    const n_workers = @max(1, @min(cpu_count, max_workers));

    if (n_workers <= 1) {
        return processSingle(io, arena, input_path, output_folder, base_name);
    }
    return processParallel(io, arena, input_path, output_folder, base_name, n_workers);
}

/// Convert one local fixed-width file on disk into product-specific CSVs under
/// `output_folder`. Returns a process exit code (0 = success).
///
/// Prefer `processInput` when the argument may be a path, directory, URL, or stdin.
pub fn processLocalFile(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
) !u8 {
    Io.Dir.cwd().createDirPath(io, output_folder) catch |err| {
        std.debug.print("Error creating output directory: {s}\n", .{@errorName(err)});
        return 1;
    };
    return processOneLocalFile(io, arena, input_path, output_folder);
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

/// Convert every `.dat` file in `dir_path` into CSVs under `output_folder`.
/// Each input file yields `companies_data_<basename>.csv` and
/// `persons_data_<basename>.csv`.
///
/// Files are processed **one at a time**. On multi-core native builds each file
/// uses the same within-file seek split as a single-file CLI argument (option B).
/// See `docs/DDR-directory-parallelism.md`.
pub fn processDirectory(
    io: Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    output_folder: []const u8,
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
        // One file at a time with full within-file multi-threading (same as lone file input).
        const code = processOneLocalFile(io, arena, file_path, output_folder) catch |err| {
            std.debug.print("Fatal error processing {s}: {s}\n", .{ file_path, @errorName(err) });
            any_failed = true;
            continue;
        };
        if (code != 0) any_failed = true;
    }
    return if (any_failed) 1 else 0;
}

/// Stream-download `url` over HTTP(S) and convert to CSV under `output_folder`.
/// Uses a single sequential pipeline (no parallel seeks). Output matches a local-file run
/// with the same basename.
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

    // Prefer identity so large snapshots are not recompressed on the wire when avoidable.
    var req = client.request(.GET, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = "ch-fixedwidth-parser" },
        },
        .keep_alive = false,
    }) catch |err| {
        std.debug.print("Error connecting to URL: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        std.debug.print("Error sending HTTP request: {s}\n", .{@errorName(err)});
        return 1;
    };

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        std.debug.print("Error receiving HTTP headers: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (response.head.status.class() != .success) {
        std.debug.print(
            "Error: HTTP {d} {s} for {s}\n",
            .{
                @intFromEnum(response.head.status),
                response.head.status.phrase() orelse "",
                url,
            },
        );
        return 1;
    }

    // Transfer buffer doubles as the Io.Reader buffer for line-delimited parsing.
    const transfer_buf = try arena.alloc(u8, read_buffer_size);
    const body_reader = response.reader(transfer_buf);

    return processFromReader(io, arena, body_reader, output_folder, base_name);
}

/// Stream-read a fixed-width file from process stdin and convert to CSV under `output_folder`.
/// Same sequential `processFromReader` path as single-stream local and remote URL input.
/// Output basenames use `stdin` (e.g. `companies_data_stdin.csv`).
pub fn processFromStdin(
    io: Io,
    arena: std.mem.Allocator,
    output_folder: []const u8,
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
    return processFromReader(io, arena, &file_reader.interface, output_folder, base_name);
}

/// Convert a local file path, directory of `.dat` files, HTTP(S) URL, or stdin (`-`)
/// into CSV files under `output_folder`. Returns a process exit code (0 = success).
pub fn processInput(
    io: Io,
    arena: std.mem.Allocator,
    input: []const u8,
    output_folder: []const u8,
) !u8 {
    if (isStdinInput(input)) {
        return processFromStdin(io, arena, output_folder);
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
        .directory => processDirectory(io, arena, input, output_folder),
        .file => processLocalFile(io, arena, input, output_folder),
    };
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

    const code = try processDirectory(io, arena, in_dir, out_dir);
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
    const code = try processInput(io, arena, in_dir, out_dir);
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

    const code = try processDirectory(io, arena, base, out_dir);
    try std.testing.expectEqual(@as(u8, 1), code);
}
