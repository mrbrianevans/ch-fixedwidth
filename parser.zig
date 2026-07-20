//! Companies House Product 195/216 snapshot parser (Zig).
//! Converts fixed-width + chevron-separated appointment data to CSV.
//! Field layout matches parser.go / process_company_appointments_data.py.
//!
//! Positions are Unicode character offsets (Python text mode). Most rows are
//! pure ASCII, so the hot path uses byte indexing; multi-byte rows fall back
//! to UTF-8 character walking so field boundaries still match the reference.
//!
//! Usage: ./parser input_file output_folder

const std = @import("std");
const Io = std.Io;
const unicode = std.unicode;

const snapshot_header_identifier = "DDDDSNAP";
const trailer_record_identifier = "99999999";
const company_record_type: u8 = '1';
const person_record_type: u8 = '2';

const read_buffer_size = 16 * 1024 * 1024;
const write_buffer_size = 16 * 1024 * 1024;

const companies_header =
    "Company Number,Company Status,Number of Officers,Company Name\n";
const persons_header =
    "Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country\n";

fn fastAtoi(b: []const u8) i32 {
    var n: i32 = 0;
    for (b) |c| {
        if (c >= '0' and c <= '9') {
            n = n * 10 + @as(i32, @intCast(c - '0'));
        }
    }
    return n;
}

fn isAscii(b: []const u8) bool {
    for (b) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

fn clamp(b: []const u8, start: usize, end: usize) []const u8 {
    const s = @min(start, b.len);
    const e = @min(end, b.len);
    if (s >= e) return b[0..0];
    return b[s..e];
}

fn trimRightSpaces(s: []const u8) []const u8 {
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

const CsvOut = struct {
    file: Io.File,
    io: Io,
    writer: Io.File.Writer,
    buffer: []u8,

    fn create(io: Io, path: []const u8, header: []const u8, buffer: []u8) !CsvOut {
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        var self: CsvOut = .{
            .file = file,
            .io = io,
            .writer = .init(file, io, buffer),
            .buffer = buffer,
        };
        try self.writer.interface.writeAll(header);
        return self;
    }

    fn w(self: *CsvOut) *Io.Writer {
        return &self.writer.interface;
    }

    fn writeField(self: *CsvOut, s: []const u8) !void {
        const out = self.w();
        if (!csvNeedsQuote(s)) {
            try out.writeAll(s);
            return;
        }
        try out.writeByte('"');
        for (s) |c| {
            if (c == '"') {
                try out.writeAll("\"\"");
            } else {
                try out.writeByte(c);
            }
        }
        try out.writeByte('"');
    }

    fn comma(self: *CsvOut) !void {
        try self.w().writeByte(',');
    }

    fn newline(self: *CsvOut) !void {
        try self.w().writeByte('\n');
    }

    fn writeInt(self: *CsvOut, n: i32) !void {
        try self.w().print("{d}", .{n});
    }

    fn close(self: *CsvOut) void {
        self.w().flush() catch {};
        self.file.close(self.io);
    }
};

fn writeCompanyRow(out: *CsvOut, row: []const u8) !void {
    if (isAscii(row)) {
        const name_length: usize = @intCast(fastAtoi(clamp(row, 36, 40)));
        var name = clamp(row, 40, 40 + name_length -| 1);
        if (name.len > 0 and name[name.len - 1] == ' ') {
            name = trimRightSpaces(name);
        }
        try out.writeField(clamp(row, 0, 8));
        try out.comma();
        try out.writeField(clamp(row, 9, 10));
        try out.comma();
        try out.writeInt(fastAtoi(clamp(row, 32, 36)));
        try out.comma();
        try out.writeField(name);
        try out.newline();
        return;
    }

    const name_length: usize = @intCast(fastAtoi(sliceChars(row, 36, 40)));
    var name = sliceChars(row, 40, 40 + name_length -| 1);
    if (name.len > 0 and name[name.len - 1] == ' ') {
        name = trimRightSpaces(name);
    }
    try out.writeField(sliceChars(row, 0, 8));
    try out.comma();
    try out.writeField(sliceChars(row, 9, 10));
    try out.comma();
    try out.writeInt(fastAtoi(sliceChars(row, 32, 36)));
    try out.comma();
    try out.writeField(name);
    try out.newline();
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

    for (fixed, 0..) |f, i| {
        if (i > 0) try out.comma();
        try out.writeField(f);
    }
    for (var_parts) |p| {
        try out.comma();
        try out.writeField(p);
    }
    try out.newline();
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

fn processCompanyAppointmentsData(
    io: Io,
    arena: std.mem.Allocator,
    input_path: []const u8,
    output_folder: []const u8,
) !u8 {
    const base_name = baseInputName(input_path);
    const companies_filename = try std.fs.path.join(arena, &.{ output_folder, try std.fmt.allocPrint(arena, "companies_data_{s}.csv", .{base_name}) });
    const persons_filename = try std.fs.path.join(arena, &.{ output_folder, try std.fmt.allocPrint(arena, "persons_data_{s}.csv", .{base_name}) });

    std.debug.print("Saving companies data to {s}\n", .{companies_filename});
    std.debug.print("Saving persons data to {s}\n", .{persons_filename});

    Io.Dir.cwd().createDirPath(io, output_folder) catch |err| {
        std.debug.print("Error creating output directory: {s}\n", .{@errorName(err)});
        return 1;
    };

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

        // Trailing CR from CRLF files.
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

    const input_filename = args[1];
    const output_folder = args[2];

    const code = processCompanyAppointmentsData(io, arena, input_filename, output_folder) catch |err| {
        std.debug.print("Fatal error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
