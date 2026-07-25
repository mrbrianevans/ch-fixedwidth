//! Pure snapshot record parsing and CSV formatting (no file I/O).
//! Field layout matches the historical Go/Python reference parsers.
//!
//! Positions are Unicode character offsets (Python text mode). Most rows are
//! pure ASCII, so the hot path uses byte indexing; multi-byte rows fall back
//! to UTF-8 character walking so field boundaries still match the reference.

const std = @import("std");
const unicode = std.unicode;

pub const snapshot_header_identifier = "DDDDSNAP";
pub const trailer_record_identifier = "99999999";
pub const company_record_type: u8 = '1';
pub const person_record_type: u8 = '2';

/// Maximum bytes written for a single CSV data row (including newline).
pub const max_csv_row_bytes = 64 * 1024;

pub const companies_header =
    "Company Number,Company Status,Number of Officers,Company Name\n";
pub const persons_header =
    "Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country\n";

pub const LineKind = enum {
    header,
    company,
    person,
    trailer,
    other,
};

pub const HeaderInfo = struct {
    run_number: []const u8,
    production_date: []const u8,
};

pub inline fn fastAtoi(b: []const u8) i32 {
    var n: i32 = 0;
    for (b) |c| {
        if (c >= '0' and c <= '9') {
            n = n * 10 + @as(i32, @intCast(c - '0'));
        }
    }
    return n;
}

/// Vectorized ASCII check: false if any byte has the high bit set.
pub fn isAscii(b: []const u8) bool {
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

pub inline fn clamp(b: []const u8, start: usize, end: usize) []const u8 {
    const s = @min(start, b.len);
    const e = @min(end, b.len);
    if (s >= e) return b[0..0];
    return b[s..e];
}

pub inline fn trimRightSpaces(s: []const u8) []const u8 {
    var i = s.len;
    while (i > 0 and s[i - 1] == ' ') : (i -= 1) {}
    return s[0..i];
}

/// Byte slice covering Unicode characters [start, end) in UTF-8 string s.
pub fn sliceChars(s: []const u8, start: usize, end: usize) []const u8 {
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
pub fn appendField(dest: []u8, pos: usize, s: []const u8) usize {
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

pub fn appendInt(dest: []u8, pos: usize, n: i32) usize {
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

pub fn classifyLine(row: []const u8) LineKind {
    if (row.len >= 8 and std.mem.eql(u8, row[0..8], snapshot_header_identifier)) return .header;
    if (row.len >= 8 and std.mem.eql(u8, row[0..8], trailer_record_identifier)) return .trailer;
    if (row.len <= 8) return .other;
    return switch (row[8]) {
        company_record_type => .company,
        person_record_type => .person,
        else => .other,
    };
}

/// True if `input` begins with the snapshot magic `DDDDSNAP`.
pub fn startsWithSnapshotHeader(input: []const u8) bool {
    return input.len >= snapshot_header_identifier.len and
        std.mem.eql(u8, input[0..snapshot_header_identifier.len], snapshot_header_identifier);
}

/// Fail unless `input` begins with `DDDDSNAP` (snapshot file signature).
pub fn requireSnapshotHeader(input: []const u8) error{UnsupportedFileType}!void {
    if (!startsWithSnapshotHeader(input)) return error.UnsupportedFileType;
}

pub fn parseHeader(row: []const u8) error{UnsupportedFileType}!HeaderInfo {
    if (row.len < 20 or !std.mem.eql(u8, row[0..8], snapshot_header_identifier)) {
        return error.UnsupportedFileType;
    }
    return .{
        .run_number = row[8..12],
        .production_date = row[12..20],
    };
}

pub fn parseTrailerCount(row: []const u8) i32 {
    return fastAtoi(clamp(row, 8, 16));
}

/// Format a company record as one CSV line (including trailing newline).
/// `dest` must be at least `max_csv_row_bytes`.
pub fn formatCompanyRow(dest: []u8, row: []const u8) usize {
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

    return p;
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

/// Format a person record as one CSV line (including trailing newline).
/// `dest` must be at least `max_csv_row_bytes`.
pub fn formatPersonRow(dest: []u8, row: []const u8) usize {
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

    return p;
}

/// Strip a trailing CR from a line (handles CRLF inputs).
pub fn stripCr(row: []const u8) []const u8 {
    if (row.len > 0 and row[row.len - 1] == '\r') {
        return row[0 .. row.len - 1];
    }
    return row;
}
