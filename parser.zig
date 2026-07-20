//! Companies House Product 195/216 snapshot parser (Zig).
//! Converts fixed-width + chevron-separated appointment data to CSV.
//! Field layout matches parser.go / process_company_appointments_data.py.
//!
//! Positions are Unicode character offsets (Python text mode). Most rows are
//! pure ASCII, so the hot path uses byte indexing; multi-byte rows fall back
//! to UTF-8 character walking so field boundaries still match the reference.
//!
//! Parallel: the input is scanned for line-aligned chunk boundaries, then
//! worker threads each stream a range and write part CSVs that are concatenated.
//!
//! Usage: ./parser input_file output_folder

const std = @import("std");
const Io = std.Io;
const unicode = std.unicode;
const Thread = std.Thread;

const snapshot_header_identifier = "DDDDSNAP";
const trailer_record_identifier = "99999999";
const company_record_type: u8 = '1';
const person_record_type: u8 = '2';

const read_buffer_size = 8 * 1024 * 1024;
const write_buffer_size = 8 * 1024 * 1024;
const max_csv_row_bytes = 64 * 1024;
const max_workers = 32;

const companies_header =
    "Company Number,Company Status,Number of Officers,Company Name\n";
const persons_header =
    "Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country\n";

inline fn fastAtoi(b: []const u8) i32 {
    var n: i32 = 0;
    for (b) |c| {
        if (c >= '0' and c <= '9') {
            n = n * 10 + @as(i32, @intCast(c - '0'));
        }
    }
    return n;
}

/// Vectorized ASCII check: false if any byte has the high bit set.
fn isAscii(b: []const u8) bool {
    var i: usize = 0;
    while (i + 16 <= b.len) : (i += 16) {
        const chunk: u128 = @bitCast(b[i..][0..16].*);
        if (chunk & 0x8080_8080_8080_8080_8080_8080_8080_8080 != 0) return false;
    }
    while (i + 8 <= b.len) : (i += 8) {
        const chunk: u64 = @bitCast(b[i..][0..8].*);
        if (chunk & 0x8080_8080_8080_8080 != 0) return false;
    }
    while (i < b.len) : (i += 1) {
        if (b[i] >= 0x80) return false;
    }
    return true;
}

inline fn clamp(b: []const u8, start: usize, end: usize) []const u8 {
    const s = @min(start, b.len);
    const e = @min(end, b.len);
    if (s >= e) return b[0..0];
    return b[s..e];
}

inline fn trimRightSpaces(s: []const u8) []const u8 {
    var i = s.len;
    while (i > 0 and s[i - 1] == ' ') : (i -= 1) {}
    return s[0..i];
}

/// Byte slice covering Unicode characters [start, end) in UTF-8 string s.
fn sliceChars(s: []const u8, start: usize, end: usize) []const u8 {
    if (start >= end) return s[0..0];
    var char_i: usize = 0;
    var byte_start: ?usize = null;
    var i: usize = 0;
    while (i < s.len) {
        const len = unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (char_i == start) byte_start = i;
        char_i += 1;
        i += len;
        if (char_i == end) {
            const bs = byte_start orelse return s[0..0];
            return s[bs..i];
        }
    }
    if (byte_start) |bs| return s[bs..];
    return s[0..0];
}

fn csvNeedsQuote(s: []const u8) bool {
    for (s) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') return true;
    }
    return false;
}

/// Append a field that may need CSV quoting.
fn appendField(dest: []u8, pos: usize, s: []const u8) usize {
    if (!csvNeedsQuote(s)) {
        @memcpy(dest[pos..][0..s.len], s);
        return pos + s.len;
    }
    var p = pos;
    dest[p] = '"';
    p += 1;
    for (s) |c| {
        if (c == '"') {
            dest[p] = '"';
            dest[p + 1] = '"';
            p += 2;
        } else {
            dest[p] = c;
            p += 1;
        }
    }
    dest[p] = '"';
    return p + 1;
}

fn appendInt(dest: []u8, pos: usize, n: i32) usize {
    if (n == 0) {
        dest[pos] = '0';
        return pos + 1;
    }
    var v: u32 = if (n < 0) @intCast(-n) else @intCast(n);
    var tmp: [12]u8 = undefined;
    var i: usize = tmp.len;
    while (v > 0) {
        i -= 1;
        tmp[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    if (n < 0) {
        i -= 1;
        tmp[i] = '-';
    }
    const digits = tmp[i..];
    @memcpy(dest[pos..][0..digits.len], digits);
    return pos + digits.len;
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
        return self.w().writableSliceGreedy(max_csv_row_bytes);
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
    var dest = try out.beginRow();
    var p: usize = 0;

    if (isAscii(row)) {
        const name_length: usize = @intCast(fastAtoi(clamp(row, 36, 40)));
        var name = clamp(row, 40, 40 + name_length -| 1);
        if (name.len > 0 and name[name.len - 1] == ' ') {
            name = trimRightSpaces(name);
        }
        p = appendField(dest, p, clamp(row, 0, 8));
        dest[p] = ',';
        p += 1;
        p = appendField(dest, p, clamp(row, 9, 10));
        dest[p] = ',';
        p += 1;
        p = appendInt(dest, p, fastAtoi(clamp(row, 32, 36)));
        dest[p] = ',';
        p += 1;
        p = appendField(dest, p, name);
        dest[p] = '\n';
        p += 1;
    } else {
        const name_length: usize = @intCast(fastAtoi(sliceChars(row, 36, 40)));
        var name = sliceChars(row, 40, 40 + name_length -| 1);
        if (name.len > 0 and name[name.len - 1] == ' ') {
            name = trimRightSpaces(name);
        }
        p = appendField(dest, p, sliceChars(row, 0, 8));
        dest[p] = ',';
        p += 1;
        p = appendField(dest, p, sliceChars(row, 9, 10));
        dest[p] = ',';
        p += 1;
        p = appendInt(dest, p, fastAtoi(sliceChars(row, 32, 36)));
        dest[p] = ',';
        p += 1;
        p = appendField(dest, p, name);
        dest[p] = '\n';
        p += 1;
    }

    out.endRow(p);
}

fn splitChevron(s: []const u8, dst: *[14][]const u8) void {
    for (dst) |*d| d.* = s[0..0];
    if (s.len == 0) return;
    var start: usize = 0;
    var idx: usize = 0;
    var i: usize = 0;
    while (i < s.len and idx < dst.len) : (i += 1) {
        if (s[i] == '<') {
            dst[idx] = s[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    if (idx < dst.len) {
        dst[idx] = s[start..];
    }
}

fn writePersonRow(out: *CsvOut, row: []const u8) !void {
    var fixed: [10][]const u8 = undefined;
    var var_parts: [14][]const u8 = undefined;

    if (isAscii(row)) {
        fixed[0] = clamp(row, 0, 8);
        fixed[1] = clamp(row, 9, 10);
        fixed[2] = clamp(row, 10, 12);
        fixed[3] = clamp(row, 12, 24);
        fixed[4] = clamp(row, 24, 25);
        fixed[5] = clamp(row, 32, 40);
        fixed[6] = clamp(row, 40, 48);
        fixed[7] = clamp(row, 48, 56);
        fixed[8] = clamp(row, 56, 64);
        fixed[9] = clamp(row, 64, 72);
        const var_len: usize = @intCast(fastAtoi(clamp(row, 72, 76)));
        splitChevron(clamp(row, 76, 76 + var_len), &var_parts);
    } else {
        fixed[0] = sliceChars(row, 0, 8);
        fixed[1] = sliceChars(row, 9, 10);
        fixed[2] = sliceChars(row, 10, 12);
        fixed[3] = sliceChars(row, 12, 24);
        fixed[4] = sliceChars(row, 24, 25);
        fixed[5] = sliceChars(row, 32, 40);
        fixed[6] = sliceChars(row, 40, 48);
        fixed[7] = sliceChars(row, 48, 56);
        fixed[8] = sliceChars(row, 56, 64);
        fixed[9] = sliceChars(row, 64, 72);
        const var_len: usize = @intCast(fastAtoi(sliceChars(row, 72, 76)));
        splitChevron(sliceChars(row, 76, 76 + var_len), &var_parts);
    }

    var dest = try out.beginRow();
    var p: usize = 0;

    for (fixed, 0..) |f, i| {
        if (i > 0) {
            dest[p] = ',';
            p += 1;
        }
        p = appendField(dest, p, f);
    }
    for (var_parts) |part| {
        dest[p] = ',';
        p += 1;
        p = appendField(dest, p, part);
    }
    dest[p] = '\n';
    p += 1;

    out.endRow(p);
}

fn processHeaderRow(row: []const u8) !void {
    if (row.len < 20 or !std.mem.eql(u8, row[0..8], snapshot_header_identifier)) {
        const prefix = if (row.len > 8) row[0..8] else row;
        std.debug.print("Error: unsupported file type from header: '{s}'\n", .{prefix});
        return error.UnsupportedFileType;
    }
    std.debug.print("Processing snapshot file with run number {s} from date {s}\n", .{ row[8..12], row[12..20] });
}

fn baseInputName(input_path: []const u8) []const u8 {
    const base = std.fs.path.basename(input_path);
    const ext = std.fs.path.extension(base);
    if (ext.len == 0) return base;
    return base[0 .. base.len - ext.len];
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
    // Seek to start_off
    try file_reader.seekTo(ctx.start_off);
    const reader = &file_reader.interface;

    var companies_out = try CsvOut.create(
        ctx.io,
        ctx.companies_path,
        if (ctx.write_headers) companies_header else null,
        ctx.companies_buf,
    );
    defer companies_out.close();

    var persons_out = try CsvOut.create(
        ctx.io,
        ctx.persons_path,
        if (ctx.write_headers) persons_header else null,
        ctx.persons_buf,
    );
    defer persons_out.close();

    var first = true;
    while (true) {
        // Stop if we've reached our byte range (after processing lines that started before end_off).
        const line_start = file_reader.logicalPos();
        if (line_start >= ctx.end_off and !first) break;

        const maybe_line = try reader.takeDelimiter('\n');
        var row = maybe_line orelse break;

        if (row.len > 0 and row[row.len - 1] == '\r') {
            row = row[0 .. row.len - 1];
        }

        if (first and ctx.handle_header) {
            try processHeaderRow(row);
            first = false;
            continue;
        }
        first = false;

        // Lines that began at or after end_off belong to the next worker.
        if (line_start >= ctx.end_off) break;

        if (row.len >= 8 and std.mem.eql(u8, row[0..8], trailer_record_identifier)) {
            result.trailer_count = fastAtoi(clamp(row, 8, 16));
            break;
        }

        if (row.len <= 8) continue;

        switch (row[8]) {
            company_record_type => {
                try writeCompanyRow(&companies_out, row);
                result.companies += 1;
            },
            person_record_type => {
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
    // Start a bit before target to find a newline (unless target is 0).
    const seek_to = if (target > 0) target -| 1 else 0;
    try reader.seekTo(seek_to);

    // Read until we pass a newline at or after (target-1), returning the next line start.
    while (reader.logicalPos() < file_size) {
        const pos_before = reader.logicalPos();
        const maybe = try reader.interface.takeDelimiter('\n');
        if (maybe == null) return file_size;
        // Line starting at pos_before ends at logicalPos() (after delimiter).
        // If this line started before target, the next line starts at logicalPos().
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

    // Probe buffer for line-boundary search
    const probe_buf = try arena.alloc(u8, 1024 * 1024);

    // Compute line-aligned split points
    var starts: [max_workers + 1]u64 = undefined;
    starts[0] = 0;
    starts[workers] = file_size;
    var w_i: usize = 1;
    while (w_i < workers) : (w_i += 1) {
        const target = (file_size * w_i) / workers;
        starts[w_i] = try findLineStartAfter(io, input_path, target, file_size, probe_buf);
    }

    // Collapse empty ranges (duplicate starts)
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

    // Run first worker on main thread if only one, else spawn
    if (n_ranges == 1) {
        workerMain(&ctxs[0]);
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

    // Concatenate part files into final outputs
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

    // Best-effort cleanup of part files
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

fn processSingle(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
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
    const read_buf = try arena.alloc(u8, read_buffer_size);

    var companies_out = CsvOut.create(io, companies_filename, companies_header, companies_buf) catch |err| {
        std.debug.print("Error opening companies file: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer companies_out.close();

    var persons_out = CsvOut.create(io, persons_filename, persons_header, persons_buf) catch |err| {
        std.debug.print("Error opening persons file: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer persons_out.close();

    const input_file = Io.Dir.cwd().openFile(io, input_path, .{}) catch |err| {
        std.debug.print("Error opening input file: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer input_file.close(io);

    var file_reader = Io.File.Reader.init(input_file, io, read_buf);
    const reader = &file_reader.interface;

    var companies_processed: i32 = 0;
    var persons_processed: i32 = 0;
    var row_num: usize = 0;

    while (true) {
        const maybe_line = reader.takeDelimiter('\n') catch |err| {
            std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
            return 1;
        };
        var row = maybe_line orelse break;

        if (row.len > 0 and row[row.len - 1] == '\r') {
            row = row[0 .. row.len - 1];
        }

        if (row_num == 0) {
            processHeaderRow(row) catch return 1;
            row_num += 1;
            continue;
        }

        if (row.len >= 8 and std.mem.eql(u8, row[0..8], trailer_record_identifier)) {
            const record_count = fastAtoi(clamp(row, 8, 16));
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
            company_record_type => {
                writeCompanyRow(&companies_out, row) catch |err| {
                    std.debug.print("Error writing company row: {s}\n", .{@errorName(err)});
                    return 1;
                };
                companies_processed += 1;
            },
            person_record_type => {
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

fn processCompanyAppointmentsData(
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

    // Parallel workers: use most cores but leave some headroom; single-thread for tiny files.
    const cpu_count = Thread.getCpuCount() catch 1;
    const n_workers = @max(1, @min(cpu_count, max_workers));

    if (n_workers <= 1) {
        return processSingle(io, arena, input_path, output_folder, base_name);
    }
    return processParallel(io, arena, input_path, output_folder, base_name, n_workers);
}

pub fn main(init: std.process.Init) void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = init.minimal.args.toSlice(arena) catch {
        std.debug.print("Error reading arguments\n", .{});
        std.process.exit(1);
    };

    if (args.len < 3) {
        std.debug.print("Usage: ./parser input_file output_folder\n", .{});
        std.process.exit(1);
    }

    const code = processCompanyAppointmentsData(io, arena, args[1], args[2]) catch |err| {
        std.debug.print("Fatal error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
