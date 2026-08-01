//! Pure record parsing and CSV formatting (no file I/O).
//! Field layout matches the historical Go/Python reference parsers.
//!
//! Positions are Unicode character offsets (Python text mode). Most rows are
//! pure ASCII, so the hot path uses byte indexing; multi-byte rows fall back
//! to UTF-8 character walking so field boundaries still match the reference.
//!
//! File products share an 8-byte header identifier at the start of the first
//! line. Callers identify the product from that magic, then branch to the
//! matching body parser. Implemented: officers snapshot (`DDDDSNAP`), officers
//! update (`DDDDUPDT`), disqualified persons (`DISQUALS`), and liquidation
//! daily updates (`LIQNFORM`).

const std = @import("std");
const unicode = std.unicode;

/// Length of the product magic at the start of a header record / file.
pub const header_identifier_len: usize = 8;

/// Companies House bulk product identified from the header record magic.
pub const FileType = enum {
    /// Products 195 / 216 — company appointments snapshot.
    officers_snapshot,
    /// Product 198 — company appointments update.
    officers_update,
    /// Product 192 — disqualified persons snapshot.
    disqualifications,
    /// Product 197 — liquidation daily updates (form groups).
    liquidation,

    /// 8-byte header identifier for this product.
    pub fn identifier(self: FileType) []const u8 {
        return switch (self) {
            .officers_snapshot => officers_snapshot_header_id,
            .officers_update => officers_update_header_id,
            .disqualifications => disqualifications_header_id,
            .liquidation => liquidation_header_id,
        };
    }

    /// Short human-readable product name (for logs / errors).
    pub fn displayName(self: FileType) []const u8 {
        return switch (self) {
            .officers_snapshot => "officers snapshot (Prod 195/216)",
            .officers_update => "officers update (Prod 198)",
            .disqualifications => "disqualified persons (Prod 192)",
            .liquidation => "liquidation daily updates (Prod 197)",
        };
    }

    /// True when a full body parser exists for this product.
    pub fn isImplemented(self: FileType) bool {
        return switch (self) {
            .officers_snapshot, .officers_update, .disqualifications, .liquidation => true,
        };
    }

    /// CSV header line for the persons (officer) output of officers products.
    pub fn personsCsvHeader(self: FileType) []const u8 {
        return switch (self) {
            .officers_snapshot => persons_header,
            .officers_update => update_persons_header,
            .disqualifications => disqual_persons_header,
            .liquidation => liq_practitioners_header,
        };
    }
};

pub const officers_snapshot_header_id = "DDDDSNAP";
pub const officers_update_header_id = "DDDDUPDT";
pub const disqualifications_header_id = "DISQUALS";
pub const liquidation_header_id = "LIQNFORM";

/// Alias retained for callers that only deal with the officers snapshot product.
pub const snapshot_header_identifier = officers_snapshot_header_id;
pub const trailer_record_identifier = "99999999";
pub const company_record_type: u8 = '1';
pub const person_record_type: u8 = '2';

/// Maximum bytes written for a single CSV data row (including newline).
pub const max_csv_row_bytes = 64 * 1024;

pub const companies_header =
    "Company Number,Company Status,Number of Officers,Company Name\n";
pub const persons_header =
    "Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country\n";
/// Prod 198 update person row CSV header (fixed fields + 14 named chevron fields).
pub const update_persons_header =
    "Company Number,App Date Origin,Res Date Origin,Correction Indicator,Corporate Indicator,Old Appointment Type,New Appointment Type,Old Person Number,New Person Number,Partial Date of Birth,Full Date of Birth,Old Person Postcode,New Person Postcode,Appointment Date,Resignation Date,Change Date,Update Date,New Title,New Forenames,New Surname,New Honours,Care Of,PO Box,New Address Line 1,New Address Line 2,New Post Town,New County,New Country,Occupation,New Nationality,New Residential Country\n";

/// Prod 192 record type 1 — disqualified person.
pub const disqual_persons_header =
    "Person Number,Date of Birth,Postcode,Title,Forenames,Surname,Honours,Address Line 1,Address Line 2,Posttown,County,Country,Nationality,Corporate Number,Country Registration\n";
/// Prod 192 record type 2 — disqualification.
pub const disqualifications_header =
    "Person Number,Disqual Start Date,Disqual End Date,Section of the Act,Disqualification Type,Order/Undertaking Date,Case Number,Company Name,Court Name\n";
/// Prod 192 record type 3 — exemption.
pub const exemptions_header =
    "Person Number,Exemption Start Date,Exemption End Date,Exemption Purpose,Exemption Company Name\n";
/// Prod 192 record type 4 — variation.
pub const variations_header =
    "Person Number,Disqualification Type,Order/Undertaking Date,Variation Court Action Date,Variation Case Number,Variation Court Name\n";

/// Prod 197 — one CSV row per form group (`FM` … next `FM` / trailer).
pub const liq_forms_header =
    "Form Number,Company Number,Company Name,Court Reference,Appointment Date,Date of Order,Date of Petition,Resolution Date,Final Meeting Date,Termination Date,Date Form Registered,Form Dated,New Dissolution Date,Transaction ID,Registered Office\n";
/// Prod 197 — one CSV row per practitioner (`NP`) record.
pub const liq_practitioners_header =
    "Transaction ID,Form Number,Company Number,Sequence,Name,Address Line 1,Address Line 2,Address Line 3,Address Line 4,Address Line 5\n";
/// Prod 197 — one CSV row per free-text (`FT`) record.
pub const liq_free_text_header =
    "Transaction ID,Form Number,Company Number,Sequence,Free Text\n";

pub const LineKind = enum {
    header,
    company,
    person,
    trailer,
    other,
};

/// Line kinds for Prod 192 (`DISQUALS`) body records (type at byte 0).
pub const DisqualLineKind = enum {
    header,
    trailer,
    person,
    disqualification,
    exemption,
    variation,
    other,
};

/// Parsed Prod 192 trailer (`DISQUALS/t1/t2/t3/t4/total`).
pub const DisqualTrailer = struct {
    type1: i32,
    type2: i32,
    type3: i32,
    type4: i32,
    total: i32,
};

/// Line kinds for Prod 197 (`LIQNFORM`) form-group files.
pub const LiqLineKind = enum {
    header,
    trailer,
    /// Starts a new form group (`FM…`).
    form,
    /// Any other tagged data record belonging to the current form group.
    data,
    other,
};

/// Capacity limits for one form group (live files stay well below these).
pub const liq_max_practitioners: usize = 16;
pub const liq_max_free_texts: usize = 8;
pub const liq_field_cap: usize = 100;
pub const liq_form_number_cap: usize = 10;
pub const liq_company_number_cap: usize = 8;
pub const liq_date_cap: usize = 8;
pub const liq_id_cap: usize = 10;
pub const liq_court_cap: usize = 13;
pub const liq_ft_cap: usize = 40;

/// Accumulator for one Prod 197 form group. Fields are owned copies so stream
/// parsers can reuse input line buffers.
pub const LiqForm = struct {
    active: bool = false,
    form_number: [liq_form_number_cap]u8 = undefined,
    form_number_len: u8 = 0,
    company_number: [liq_company_number_cap]u8 = undefined,
    company_number_len: u8 = 0,
    company_name: [liq_field_cap]u8 = undefined,
    company_name_len: u8 = 0,
    court_ref: [liq_court_cap]u8 = undefined,
    court_ref_len: u8 = 0,
    appointment_date: [liq_date_cap]u8 = undefined,
    appointment_date_len: u8 = 0,
    date_of_order: [liq_date_cap]u8 = undefined,
    date_of_order_len: u8 = 0,
    date_of_petition: [liq_date_cap]u8 = undefined,
    date_of_petition_len: u8 = 0,
    resolution_date: [liq_date_cap]u8 = undefined,
    resolution_date_len: u8 = 0,
    final_meeting_date: [liq_date_cap]u8 = undefined,
    final_meeting_date_len: u8 = 0,
    termination_date: [liq_date_cap]u8 = undefined,
    termination_date_len: u8 = 0,
    date_registered: [liq_date_cap]u8 = undefined,
    date_registered_len: u8 = 0,
    form_dated: [liq_date_cap]u8 = undefined,
    form_dated_len: u8 = 0,
    new_dissolution_date: [liq_date_cap]u8 = undefined,
    new_dissolution_date_len: u8 = 0,
    transaction_id: [liq_id_cap]u8 = undefined,
    transaction_id_len: u8 = 0,
    registered_office: [liq_field_cap]u8 = undefined,
    registered_office_len: u8 = 0,
    practitioners: [liq_max_practitioners][liq_field_cap]u8 = undefined,
    practitioner_lens: [liq_max_practitioners]u8 = .{0} ** liq_max_practitioners,
    practitioner_count: u8 = 0,
    free_texts: [liq_max_free_texts][liq_ft_cap]u8 = undefined,
    free_text_lens: [liq_max_free_texts]u8 = .{0} ** liq_max_free_texts,
    free_text_count: u8 = 0,

    pub fn reset(self: *LiqForm) void {
        self.* = .{};
    }

    pub fn formNumber(self: *const LiqForm) []const u8 {
        return self.form_number[0..self.form_number_len];
    }
    pub fn companyNumber(self: *const LiqForm) []const u8 {
        return self.company_number[0..self.company_number_len];
    }
    pub fn companyName(self: *const LiqForm) []const u8 {
        return self.company_name[0..self.company_name_len];
    }
    pub fn courtRef(self: *const LiqForm) []const u8 {
        return self.court_ref[0..self.court_ref_len];
    }
    pub fn appointmentDate(self: *const LiqForm) []const u8 {
        return self.appointment_date[0..self.appointment_date_len];
    }
    pub fn dateOfOrder(self: *const LiqForm) []const u8 {
        return self.date_of_order[0..self.date_of_order_len];
    }
    pub fn dateOfPetition(self: *const LiqForm) []const u8 {
        return self.date_of_petition[0..self.date_of_petition_len];
    }
    pub fn resolutionDate(self: *const LiqForm) []const u8 {
        return self.resolution_date[0..self.resolution_date_len];
    }
    pub fn finalMeetingDate(self: *const LiqForm) []const u8 {
        return self.final_meeting_date[0..self.final_meeting_date_len];
    }
    pub fn terminationDate(self: *const LiqForm) []const u8 {
        return self.termination_date[0..self.termination_date_len];
    }
    pub fn dateRegistered(self: *const LiqForm) []const u8 {
        return self.date_registered[0..self.date_registered_len];
    }
    pub fn formDated(self: *const LiqForm) []const u8 {
        return self.form_dated[0..self.form_dated_len];
    }
    pub fn newDissolutionDate(self: *const LiqForm) []const u8 {
        return self.new_dissolution_date[0..self.new_dissolution_date_len];
    }
    pub fn transactionId(self: *const LiqForm) []const u8 {
        return self.transaction_id[0..self.transaction_id_len];
    }
    pub fn registeredOffice(self: *const LiqForm) []const u8 {
        return self.registered_office[0..self.registered_office_len];
    }
    pub fn practitioner(self: *const LiqForm, i: usize) []const u8 {
        return self.practitioners[i][0..self.practitioner_lens[i]];
    }
    pub fn freeText(self: *const LiqForm, i: usize) []const u8 {
        return self.free_texts[i][0..self.free_text_lens[i]];
    }

    /// Apply one tagged data record to this form (including the opening `FM`).
    pub fn applyRecord(self: *LiqForm, row: []const u8) void {
        if (row.len < 2) return;
        const tag = row[0..2];
        const payload = if (row.len > 2) trimRightSpaces(row[2..]) else row[0..0];

        if (std.mem.eql(u8, tag, "FM")) {
            self.active = true;
            setField(&self.form_number, &self.form_number_len, payload, liq_form_number_cap);
            return;
        }
        if (!self.active) return;

        if (std.mem.eql(u8, tag, "RN")) {
            setField(&self.company_number, &self.company_number_len, payload, liq_company_number_cap);
        } else if (std.mem.eql(u8, tag, "NA")) {
            setField(&self.company_name, &self.company_name_len, payload, liq_field_cap);
        } else if (std.mem.eql(u8, tag, "CO")) {
            setField(&self.court_ref, &self.court_ref_len, payload, liq_court_cap);
        } else if (std.mem.eql(u8, tag, "AD")) {
            setField(&self.appointment_date, &self.appointment_date_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "DO")) {
            setField(&self.date_of_order, &self.date_of_order_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "DP")) {
            setField(&self.date_of_petition, &self.date_of_petition_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "RD")) {
            setField(&self.resolution_date, &self.resolution_date_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "MD")) {
            setField(&self.final_meeting_date, &self.final_meeting_date_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "TD")) {
            setField(&self.termination_date, &self.termination_date_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "DR")) {
            setField(&self.date_registered, &self.date_registered_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "FD")) {
            setField(&self.form_dated, &self.form_dated_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "ND")) {
            setField(&self.new_dissolution_date, &self.new_dissolution_date_len, payload, liq_date_cap);
        } else if (std.mem.eql(u8, tag, "ID")) {
            setField(&self.transaction_id, &self.transaction_id_len, payload, liq_id_cap);
        } else if (std.mem.eql(u8, tag, "RE")) {
            // Overflow RE records append with a space separator.
            if (self.registered_office_len == 0) {
                setField(&self.registered_office, &self.registered_office_len, payload, liq_field_cap);
            } else if (self.registered_office_len < liq_field_cap) {
                const space_at = self.registered_office_len;
                if (space_at + 1 < liq_field_cap) {
                    self.registered_office[space_at] = ' ';
                    self.registered_office_len = @intCast(space_at + 1);
                    const room = liq_field_cap - self.registered_office_len;
                    const take = @min(payload.len, room);
                    @memcpy(self.registered_office[self.registered_office_len..][0..take], payload[0..take]);
                    self.registered_office_len += @intCast(take);
                }
            }
        } else if (std.mem.eql(u8, tag, "NP")) {
            if (self.practitioner_count < liq_max_practitioners) {
                const i = self.practitioner_count;
                setField(&self.practitioners[i], &self.practitioner_lens[i], payload, liq_field_cap);
                self.practitioner_count += 1;
            }
        } else if (std.mem.eql(u8, tag, "FT")) {
            if (self.free_text_count < liq_max_free_texts) {
                const i = self.free_text_count;
                setField(&self.free_texts[i], &self.free_text_lens[i], payload, liq_ft_cap);
                self.free_text_count += 1;
            }
        }
        // Unknown tags are ignored (forward-compatible with newer codes).
    }
};

fn setField(buf: []u8, len_out: *u8, src: []const u8, cap: usize) void {
    const take = @min(src.len, cap);
    @memcpy(buf[0..take], src[0..take]);
    len_out.* = @intCast(take);
}

pub const HeaderInfo = struct {
    file_type: FileType,
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

/// Map an 8-byte header identifier to a known `FileType`.
pub fn identifyFileType(header_id: []const u8) error{UnsupportedFileType}!FileType {
    if (header_id.len < header_identifier_len) return error.UnsupportedFileType;
    const id = header_id[0..header_identifier_len];
    if (std.mem.eql(u8, id, officers_snapshot_header_id)) return .officers_snapshot;
    if (std.mem.eql(u8, id, officers_update_header_id)) return .officers_update;
    if (std.mem.eql(u8, id, disqualifications_header_id)) return .disqualifications;
    if (std.mem.eql(u8, id, liquidation_header_id)) return .liquidation;
    return error.UnsupportedFileType;
}

/// Identify product from the leading bytes of a file or header line.
pub fn identifyFileTypeFromInput(input: []const u8) error{UnsupportedFileType}!FileType {
    if (input.len < header_identifier_len) return error.UnsupportedFileType;
    return identifyFileType(input[0..header_identifier_len]);
}

/// Fail unless `file_type` has an implemented body parser.
pub fn requireImplemented(file_type: FileType) error{NotImplemented}!void {
    if (!file_type.isImplemented()) return error.NotImplemented;
}

/// Classify a line for **officers** body layouts (Prod 195/216/198).
/// Header magics are `.header`. Officers trailer is `99999999…`.
/// For Prod 192, use `classifyDisqualLine` instead (type at byte 0; trailer is
/// `DISQUALS/…`).
pub fn classifyLine(row: []const u8) LineKind {
    if (row.len >= header_identifier_len) {
        if (std.mem.eql(u8, row[0..header_identifier_len], disqualifications_header_id)) {
            // Disqual trailer also starts with DISQUALS — keep officers path clear.
            if (row.len > header_identifier_len and row[header_identifier_len] == '/') {
                return .trailer;
            }
            return .header;
        }
        if (identifyFileType(row[0..header_identifier_len])) |_| {
            return .header;
        } else |_| {}
        if (std.mem.eql(u8, row[0..header_identifier_len], trailer_record_identifier)) {
            return .trailer;
        }
    }
    if (row.len <= 8) return .other;
    return switch (row[8]) {
        company_record_type => .company,
        person_record_type => .person,
        else => .other,
    };
}

/// Classify a Prod 192 line. Header is `DISQUALS` without `/`; trailer is
/// `DISQUALS/…`. Body record type is the first character (`1`–`4`).
pub fn classifyDisqualLine(row: []const u8) DisqualLineKind {
    if (row.len >= header_identifier_len and
        std.mem.eql(u8, row[0..header_identifier_len], disqualifications_header_id))
    {
        if (row.len > header_identifier_len and row[header_identifier_len] == '/') {
            return .trailer;
        }
        return .header;
    }
    if (row.len == 0) return .other;
    return switch (row[0]) {
        '1' => .person,
        '2' => .disqualification,
        '3' => .exemption,
        '4' => .variation,
        else => .other,
    };
}

/// Classify a Prod 197 line. Header is `LIQNFORM…`; trailer is `99999999…`.
/// Form groups start with `FM`; other 2-character tags are `.data`.
pub fn classifyLiqLine(row: []const u8) LiqLineKind {
    if (row.len >= header_identifier_len) {
        if (std.mem.eql(u8, row[0..header_identifier_len], liquidation_header_id)) {
            return .header;
        }
        if (std.mem.eql(u8, row[0..header_identifier_len], trailer_record_identifier)) {
            return .trailer;
        }
    }
    if (row.len < 2) return .other;
    if (row[0] == 'F' and row[1] == 'M') return .form;
    // Known / plausible two-letter tags count as data; unknown tags still count
    // toward the trailer total when callers treat all non-header/trailer lines
    // as records — classification as `.data` keeps them on the form path.
    return .data;
}

/// True if `input` begins with the snapshot magic `DDDDSNAP`.
pub fn startsWithSnapshotHeader(input: []const u8) bool {
    return input.len >= officers_snapshot_header_id.len and
        std.mem.eql(u8, input[0..officers_snapshot_header_id.len], officers_snapshot_header_id);
}

/// Fail unless `input` begins with `DDDDSNAP` (snapshot file signature).
pub fn requireSnapshotHeader(input: []const u8) error{UnsupportedFileType}!void {
    if (!startsWithSnapshotHeader(input)) return error.UnsupportedFileType;
}

/// Parse a header record for any known product (shared 20-byte layout).
/// Does **not** require the product to be implemented — callers should branch
/// on `file_type` / `requireImplemented` to select a body parser.
pub fn parseHeader(row: []const u8) error{UnsupportedFileType}!HeaderInfo {
    if (row.len < 20) return error.UnsupportedFileType;
    const file_type = try identifyFileType(row[0..header_identifier_len]);
    return .{
        .file_type = file_type,
        .run_number = row[8..12],
        .production_date = row[12..20],
    };
}

pub fn parseTrailerCount(row: []const u8) i32 {
    return fastAtoi(clamp(row, 8, 16));
}

/// Parse a Prod 192 trailer: `DISQUALS/00011912/00013007/00000098/00000002/00025019`.
pub fn parseDisqualTrailer(row: []const u8) error{MissingTrailer}!DisqualTrailer {
    if (row.len < 53) return error.MissingTrailer;
    if (!std.mem.eql(u8, row[0..8], disqualifications_header_id)) return error.MissingTrailer;
    if (row[8] != '/') return error.MissingTrailer;
    // Fixed slash-separated 8-digit counts at known offsets.
    // DISQUALS/########/########/########/########/########
    // 0       8 9      17 18     26 27     35 36     44 45    53
    if (row[17] != '/' or row[26] != '/' or row[35] != '/' or row[44] != '/') {
        return error.MissingTrailer;
    }
    return .{
        .type1 = fastAtoi(row[9..17]),
        .type2 = fastAtoi(row[18..26]),
        .type3 = fastAtoi(row[27..35]),
        .type4 = fastAtoi(row[36..44]),
        .total = fastAtoi(row[45..53]),
    };
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

fn splitChevron(s: []const u8, dst: [][]const u8) void {
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

/// Format a snapshot person record (Prod 195/216) as one CSV line (incl. newline).
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
        splitChevron(clamp(row, 76, 76 + var_len), var_parts[0..]);
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
        splitChevron(sliceChars(row, 76, 76 + var_len), var_parts[0..]);
    }

    return writeCsvFields(dest, &fixed, &var_parts);
}

/// Format an update person record (Prod 198 / `DDDDUPDT`) as one CSV line.
/// Fixed layout per docs/Prod198_Update.md; variable data has 27 chevrons of
/// which the first 14 named fields are exported (trailing fillers omitted).
/// `dest` must be at least `max_csv_row_bytes`.
pub fn formatUpdatePersonRow(dest: []u8, row: []const u8) usize {
    var fixed: [17][]const u8 = undefined;
    var var_parts: [14][]const u8 = undefined;

    if (isAscii(row)) {
        // 0-based character positions from the Prod 198 person update layout.
        fixed[0] = clamp(row, 0, 8); // Company Number
        fixed[1] = clamp(row, 9, 10); // App Date Origin
        fixed[2] = clamp(row, 10, 11); // Res Date Origin
        fixed[3] = clamp(row, 11, 12); // Correction Indicator
        fixed[4] = clamp(row, 12, 13); // Corporate Indicator
        fixed[5] = clamp(row, 15, 17); // Old Appointment Type
        fixed[6] = clamp(row, 17, 19); // New Appointment Type
        fixed[7] = clamp(row, 19, 31); // Old Person Number
        fixed[8] = clamp(row, 31, 43); // New Person Number
        fixed[9] = clamp(row, 43, 51); // Partial DOB
        fixed[10] = clamp(row, 51, 59); // Full DOB
        fixed[11] = clamp(row, 59, 67); // Old Person Postcode
        fixed[12] = clamp(row, 67, 75); // New Person Postcode
        fixed[13] = clamp(row, 75, 83); // Appointment Date
        fixed[14] = clamp(row, 83, 91); // Resignation Date
        fixed[15] = clamp(row, 91, 99); // Change Date
        fixed[16] = clamp(row, 99, 107); // Update Date
        const var_len: usize = @intCast(fastAtoi(clamp(row, 107, 111)));
        splitChevron(clamp(row, 111, 111 + var_len), var_parts[0..]);
    } else {
        fixed[0] = sliceChars(row, 0, 8);
        fixed[1] = sliceChars(row, 9, 10);
        fixed[2] = sliceChars(row, 10, 11);
        fixed[3] = sliceChars(row, 11, 12);
        fixed[4] = sliceChars(row, 12, 13);
        fixed[5] = sliceChars(row, 15, 17);
        fixed[6] = sliceChars(row, 17, 19);
        fixed[7] = sliceChars(row, 19, 31);
        fixed[8] = sliceChars(row, 31, 43);
        fixed[9] = sliceChars(row, 43, 51);
        fixed[10] = sliceChars(row, 51, 59);
        fixed[11] = sliceChars(row, 59, 67);
        fixed[12] = sliceChars(row, 67, 75);
        fixed[13] = sliceChars(row, 75, 83);
        fixed[14] = sliceChars(row, 83, 91);
        fixed[15] = sliceChars(row, 91, 99);
        fixed[16] = sliceChars(row, 99, 107);
        const var_len: usize = @intCast(fastAtoi(sliceChars(row, 107, 111)));
        splitChevron(sliceChars(row, 111, 111 + var_len), var_parts[0..]);
    }

    return writeCsvFields(dest, &fixed, &var_parts);
}

fn writeCsvFields(dest: []u8, fixed: []const []const u8, var_parts: []const []const u8) usize {
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

/// Prod 192 type 1 — person. Variable details: 12 chevron fields.
pub fn formatDisqualPersonRow(dest: []u8, row: []const u8) usize {
    var fixed: [3][]const u8 = undefined;
    var var_parts: [12][]const u8 = undefined;

    if (isAscii(row)) {
        fixed[0] = clamp(row, 1, 13); // Person Number
        fixed[1] = clamp(row, 13, 21); // DOB
        fixed[2] = clamp(row, 21, 29); // Postcode
        const var_len: usize = @intCast(fastAtoi(clamp(row, 29, 33)));
        splitChevron(clamp(row, 33, 33 + var_len), var_parts[0..]);
    } else {
        fixed[0] = sliceChars(row, 1, 13);
        fixed[1] = sliceChars(row, 13, 21);
        fixed[2] = sliceChars(row, 21, 29);
        const var_len: usize = @intCast(fastAtoi(sliceChars(row, 29, 33)));
        splitChevron(sliceChars(row, 33, 33 + var_len), var_parts[0..]);
    }
    return writeCsvFields(dest, &fixed, &var_parts);
}

/// Prod 192 type 2 — disqualification.
/// Field starts after SECTION follow real bulk files (docs table is off by 8
/// from DISQUALIFICATION-TYPE onward: dtype begins at 0-based 49, company at 117,
/// court-name length at 277).
pub fn formatDisqualificationRow(dest: []u8, row: []const u8) usize {
    var fields: [9][]const u8 = undefined;

    if (isAscii(row)) {
        fields[0] = clamp(row, 1, 13); // Person Number
        fields[1] = clamp(row, 13, 21); // Start
        fields[2] = clamp(row, 21, 29); // End
        fields[3] = clamp(row, 29, 49); // Section
        fields[4] = clamp(row, 49, 79); // Type
        fields[5] = clamp(row, 79, 87); // Order/undertaking date
        fields[6] = clamp(row, 87, 117); // Case number
        var company = clamp(row, 117, 277);
        company = trimRightSpaces(company);
        fields[7] = company;
        const court_len: usize = @intCast(fastAtoi(clamp(row, 277, 281)));
        fields[8] = clamp(row, 281, 281 + court_len);
    } else {
        fields[0] = sliceChars(row, 1, 13);
        fields[1] = sliceChars(row, 13, 21);
        fields[2] = sliceChars(row, 21, 29);
        fields[3] = sliceChars(row, 29, 49);
        fields[4] = sliceChars(row, 49, 79);
        fields[5] = sliceChars(row, 79, 87);
        fields[6] = sliceChars(row, 87, 117);
        var company = sliceChars(row, 117, 277);
        company = trimRightSpaces(company);
        fields[7] = company;
        const court_len: usize = @intCast(fastAtoi(sliceChars(row, 277, 281)));
        fields[8] = sliceChars(row, 281, 281 + court_len);
    }
    return writeCsvFields(dest, &fields, &.{} );
}

/// Prod 192 type 3 — exemption.
pub fn formatExemptionRow(dest: []u8, row: []const u8) usize {
    var fields: [5][]const u8 = undefined;

    if (isAscii(row)) {
        fields[0] = clamp(row, 1, 13);
        fields[1] = clamp(row, 13, 21);
        fields[2] = clamp(row, 21, 29);
        fields[3] = clamp(row, 29, 39);
        const name_len: usize = @intCast(fastAtoi(clamp(row, 39, 43)));
        fields[4] = clamp(row, 43, 43 + name_len);
    } else {
        fields[0] = sliceChars(row, 1, 13);
        fields[1] = sliceChars(row, 13, 21);
        fields[2] = sliceChars(row, 21, 29);
        fields[3] = sliceChars(row, 29, 39);
        const name_len: usize = @intCast(fastAtoi(sliceChars(row, 39, 43)));
        fields[4] = sliceChars(row, 43, 43 + name_len);
    }
    return writeCsvFields(dest, &fields, &.{});
}

/// Prod 192 type 4 — variation.
pub fn formatVariationRow(dest: []u8, row: []const u8) usize {
    var fields: [6][]const u8 = undefined;

    if (isAscii(row)) {
        fields[0] = clamp(row, 1, 13);
        fields[1] = clamp(row, 13, 43);
        fields[2] = clamp(row, 43, 51);
        fields[3] = clamp(row, 51, 59);
        fields[4] = clamp(row, 59, 89);
        const court_len: usize = @intCast(fastAtoi(clamp(row, 89, 93)));
        fields[5] = clamp(row, 93, 93 + court_len);
    } else {
        fields[0] = sliceChars(row, 1, 13);
        fields[1] = sliceChars(row, 13, 43);
        fields[2] = sliceChars(row, 43, 51);
        fields[3] = sliceChars(row, 51, 59);
        fields[4] = sliceChars(row, 59, 89);
        const court_len: usize = @intCast(fastAtoi(sliceChars(row, 89, 93)));
        fields[5] = sliceChars(row, 93, 93 + court_len);
    }
    return writeCsvFields(dest, &fields, &.{});
}

/// Strip a trailing CR from a line (handles CRLF inputs).
pub fn stripCr(row: []const u8) []const u8 {
    if (row.len > 0 and row[row.len - 1] == '\r') {
        return row[0 .. row.len - 1];
    }
    return row;
}

/// Format one Prod 197 form group as a forms CSV row (including newline).
pub fn formatLiqFormRow(dest: []u8, form: *const LiqForm) usize {
    const fields = [_][]const u8{
        form.formNumber(),
        form.companyNumber(),
        form.companyName(),
        form.courtRef(),
        form.appointmentDate(),
        form.dateOfOrder(),
        form.dateOfPetition(),
        form.resolutionDate(),
        form.finalMeetingDate(),
        form.terminationDate(),
        form.dateRegistered(),
        form.formDated(),
        form.newDissolutionDate(),
        form.transactionId(),
        form.registeredOffice(),
    };
    return writeCsvFields(dest, &fields, &.{});
}

/// Format one Prod 197 practitioner (`NP`) as a CSV row (including newline).
/// `index` is 0-based into `form.practitioners`.
pub fn formatLiqPractitionerRow(dest: []u8, form: *const LiqForm, index: usize) usize {
    var parts: [6][]const u8 = .{ "", "", "", "", "", "" };
    splitChevron(form.practitioner(index), parts[0..]);

    var seq_buf: [12]u8 = undefined;
    const seq_len = appendInt(seq_buf[0..], 0, @intCast(index + 1));

    const fields = [_][]const u8{
        form.transactionId(),
        form.formNumber(),
        form.companyNumber(),
        seq_buf[0..seq_len],
        parts[0],
        parts[1],
        parts[2],
        parts[3],
        parts[4],
        parts[5],
    };
    return writeCsvFields(dest, &fields, &.{});
}

/// Format one Prod 197 free-text (`FT`) as a CSV row (including newline).
/// `index` is 0-based into `form.free_texts`.
pub fn formatLiqFreeTextRow(dest: []u8, form: *const LiqForm, index: usize) usize {
    var seq_buf: [12]u8 = undefined;
    const seq_len = appendInt(seq_buf[0..], 0, @intCast(index + 1));

    const fields = [_][]const u8{
        form.transactionId(),
        form.formNumber(),
        form.companyNumber(),
        seq_buf[0..seq_len],
        form.freeText(index),
    };
    return writeCsvFields(dest, &fields, &.{});
}
