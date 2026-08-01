//! File-based conversion: streaming I/O, optional multithreading.
//! Uses pure formatters from `parse.zig` for record → CSV.
//! Native CLI also supports streaming HTTP(S) download of remote `.dat` URLs.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Thread = std.Thread;
const http = std.http;
const parse = @import("parse.zig");

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

fn writePersonRow(out: *CsvOut, row: []const u8) !void {
    const dest = try out.beginRow();
    const p = parse.formatPersonRow(dest, row);
    out.endRow(p);
}

fn processHeaderRow(row: []const u8) !void {
    const info = parse.parseHeader(row) catch {
        const prefix = if (row.len > 8) row[0..8] else row;
        std.debug.print("Error: unsupported file type from header: '{s}'\n", .{prefix});
        return error.UnsupportedFileType;
    };
    std.debug.print("Processing snapshot file with run number {s} from date {s}\n", .{
        info.run_number,
        info.production_date,
    });
}

/// True when `s` is an HTTP(S) URL (case-insensitive scheme).
pub fn isRemoteUrl(s: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, "http://") or
        std.ascii.startsWithIgnoreCase(s, "https://");
}

/// True when the CLI should read the snapshot from stdin (`-`).
pub fn isStdinInput(s: []const u8) bool {
    return std.mem.eql(u8, s, "-");
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
    /// Inclusive start file offset (first byte of first line to process).
    start_off: u64,
    /// Exclusive end file offset (do not process lines starting at or after this).
    end_off: u64,
    /// If true, first line in range is the snapshot header.
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
        if (ctx.write_headers) parse.persons_header else null,
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
            try processHeaderRow(row);
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

        switch (row[8]) {
            parse.company_record_type => {
                try writeCompanyRow(&companies_out, row);
                result.companies += 1;
            },
            parse.person_record_type => {
                try writePersonRow(&persons_out, row);
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

/// Stream lines from `reader` into company/person CSVs under `output_folder`.
/// Caller must ensure `output_folder` exists. Same output layout as a local file run.
pub fn processFromReader(
    io: Io,
    arena: std.mem.Allocator,
    reader: *Io.Reader,
    output_folder: []const u8,
    base_name: []const u8,
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

    const companies_buf = try arena.alloc(u8, write_buffer_size);
    const persons_buf = try arena.alloc(u8, write_buffer_size);

    var companies_out = CsvOut.create(io, companies_filename, parse.companies_header, companies_buf) catch |err| {
        std.debug.print("Error opening companies file: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer companies_out.close();

    var persons_out = CsvOut.create(io, persons_filename, parse.persons_header, persons_buf) catch |err| {
        std.debug.print("Error opening persons file: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer persons_out.close();

    var companies_processed: i32 = 0;
    var persons_processed: i32 = 0;
    var row_num: usize = 0;

    while (true) {
        const maybe_line = reader.takeDelimiter('\n') catch |err| {
            std.debug.print("Error reading input: {s}\n", .{@errorName(err)});
            return 1;
        };
        const row = parse.stripCr(maybe_line orelse break);

        if (row_num == 0) {
            processHeaderRow(row) catch return 1;
            row_num += 1;
            continue;
        }

        if (row.len >= 8 and std.mem.eql(u8, row[0..8], parse.trailer_record_identifier)) {
            const record_count = parse.parseTrailerCount(row);
            const total = companies_processed + persons_processed;
            if (record_count != total) {
                std.debug.print("ERROR: Processed {d} records out of {d}\n", .{ total, record_count });
                return 1;
            }
            std.debug.print("Processed {d} records: {d} companies, {d} persons.\n", .{ total, companies_processed, persons_processed });
            return 0;
        }

        if (row.len <= 8) {
            row_num += 1;
            continue;
        }

        switch (row[8]) {
            parse.company_record_type => {
                writeCompanyRow(&companies_out, row) catch |err| {
                    std.debug.print("Error writing company row: {s}\n", .{@errorName(err)});
                    return 1;
                };
                companies_processed += 1;
            },
            parse.person_record_type => {
                writePersonRow(&persons_out, row) catch |err| {
                    std.debug.print("Error writing person row: {s}\n", .{@errorName(err)});
                    return 1;
                };
                persons_processed += 1;
            },
            else => {},
        }
        row_num += 1;
    }

    std.debug.print("ERROR: No trailer record found.\n", .{});
    return 1;
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

/// Convert one snapshot file on disk into CSV files under `output_folder`.
/// Returns a process exit code (0 = success).
///
/// Prefer `processInput` when the argument may be either a local path or HTTP(S) URL.
pub fn processCompanyAppointmentsData(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
) !u8 {
    Io.Dir.cwd().createDirPath(io, output_folder) catch |err| {
        std.debug.print("Error creating output directory: {s}\n", .{@errorName(err)});
        return 1;
    };

    const base_name = baseInputName(input_path);

    if (comptime builtin.single_threaded) {
        return processSingle(io, arena, input_path, output_folder, base_name);
    }

    const cpu_count = Thread.getCpuCount() catch 1;
    const n_workers = @max(1, @min(cpu_count, max_workers));

    if (n_workers <= 1) {
        return processSingle(io, arena, input_path, output_folder, base_name);
    }
    return processParallel(io, arena, input_path, output_folder, base_name, n_workers);
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

/// Stream-read a snapshot from process stdin and convert to CSV under `output_folder`.
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
    std.debug.print("Reading snapshot from stdin\n", .{});

    const read_buf = try arena.alloc(u8, read_buffer_size);
    // Do not close stdin — process owns the standard handles.
    const stdin_file = Io.File.stdin();
    var file_reader = Io.File.Reader.initStreaming(stdin_file, io, read_buf);
    return processFromReader(io, arena, &file_reader.interface, output_folder, base_name);
}

/// Convert a local path, HTTP(S) URL, or stdin (`-`) into CSV files under `output_folder`.
/// Returns a process exit code (0 = success).
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
    return processCompanyAppointmentsData(io, arena, input, output_folder);
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
}

test "baseInputName for local paths and URLs" {
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("src/testdata/mini_snapshot.dat"));
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("mini_snapshot.dat"));
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("http://localhost:8765/mini_snapshot.dat"));
    try std.testing.expectEqualStrings("mini_snapshot", baseInputName("https://cdn.example.com/path/to/mini_snapshot.dat?token=abc"));
    try std.testing.expectEqualStrings("download", baseInputName("http://localhost:8765/"));
}
