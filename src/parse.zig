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

/// Named CSV output channel. Products emit a subset of these kinds; kinds are
/// never overloaded across products (e.g. liquidation forms are `.forms`, not
/// `.companies`).
pub const OutputKind = enum(i32) {
    companies = 0,
    persons = 1,
    disqualifications = 2,
    exemptions = 3,
    variations = 4,
    forms = 5,
    practitioners = 6,
    free_text = 7,

    pub const all = [_]OutputKind{
        .companies,
        .persons,
        .disqualifications,
        .exemptions,
        .variations,
        .forms,
        .practitioners,
        .free_text,
    };

    /// Filename stem before `_<basename>.csv` (e.g. `companies_data`).
    pub fn fileStem(self: OutputKind) []const u8 {
        return switch (self) {
            .companies => "companies_data",
            .persons => "persons_data",
            .disqualifications => "disqualifications_data",
            .exemptions => "exemptions_data",
            .variations => "variations_data",
            .forms => "forms_data",
            .practitioners => "practitioners_data",
            .free_text => "free_text_data",
        };
    }

    /// Short label for logs and UI.
    pub fn displayName(self: OutputKind) []const u8 {
        return switch (self) {
            .companies => "companies",
            .persons => "persons",
            .disqualifications => "disqualifications",
            .exemptions => "exemptions",
            .variations => "variations",
            .forms => "forms",
            .practitioners => "practitioners",
            .free_text => "free text",
        };
    }

    pub fn fromInt(v: i32) ?OutputKind {
        return std.meta.intToEnum(OutputKind, v) catch null;
    }
};

/// Companies House bulk product identified from the header record magic.
/// Integer values match the C ABI `CH_FILE_*` constants.
pub const FileType = enum(i32) {
    /// Products 195 / 216 — company appointments snapshot.
    officers_snapshot = 0,
    /// Product 198 — company appointments update.
    officers_update = 1,
    /// Product 192 — disqualified persons.
    disqualifications = 2,
    /// Product 197 — liquidation daily updates (form groups).
    liquidation = 3,

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
    /// Keep returning false for future magics once they are recognised but not wired.
    pub fn isImplemented(self: FileType) bool {
        return switch (self) {
            .officers_snapshot, .officers_update, .disqualifications, .liquidation => true,
        };
    }

    /// CSV output kinds produced by this product (stable order for writers).
    pub fn outputKinds(self: FileType) []const OutputKind {
        return switch (self) {
            .officers_snapshot, .officers_update => &.{ .companies, .persons },
            .disqualifications => &.{ .persons, .disqualifications, .exemptions, .variations },
            .liquidation => &.{ .forms, .practitioners, .free_text },
        };
    }

    /// True when this product emits `kind`.
    pub fn hasOutput(self: FileType, kind: OutputKind) bool {
        return std.mem.indexOfScalar(OutputKind, self.outputKinds(), kind) != null;
    }

    /// CSV header line for a `.persons` stream (officers or disqual type 1).
    /// Liquidation does not emit `.persons` (use `.practitioners`).
    pub fn personsCsvHeader(self: FileType) []const u8 {
        return switch (self) {
            .officers_snapshot => persons_header,
            .officers_update => update_persons_header,
            .disqualifications => disqual_persons_header,
            .liquidation => persons_header, // unused for this product
        };
    }

    /// CSV header for a given output kind on this product (prefer `hasOutput` first).
    pub fn csvHeader(self: FileType, kind: OutputKind) []const u8 {
        return switch (kind) {
            .companies => companies_header,
            .persons => self.personsCsvHeader(),
            .disqualifications => disqualifications_header,
            .exemptions => exemptions_header,
            .variations => variations_header,
            .forms => liq_forms_header,
            .practitioners => liq_practitioners_header,
            .free_text => liq_free_text_header,
        };
    }

    pub fn fromInt(v: i32) ?FileType {
        return std.meta.intToEnum(FileType, v) catch null;
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

/// Named single-value slots in a Prod 197 form group (tag-driven).
pub const LiqSlot = enum(u8) {
    form_number = 0,
    company_number = 1,
    company_name = 2,
    court_ref = 3,
    appointment_date = 4,
    date_of_order = 5,
    date_of_petition = 6,
    resolution_date = 7,
    final_meeting_date = 8,
    termination_date = 9,
    date_registered = 10,
    form_dated = 11,
    new_dissolution_date = 12,
    transaction_id = 13,
    registered_office = 14,

    pub const count: usize = 15;

    pub fn cap(self: LiqSlot) usize {
        return switch (self) {
            .form_number => liq_form_number_cap,
            .company_number => liq_company_number_cap,
            .company_name, .registered_office => liq_field_cap,
            .court_ref => liq_court_cap,
            .appointment_date, .date_of_order, .date_of_petition, .resolution_date, .final_meeting_date, .termination_date, .date_registered, .form_dated, .new_dissolution_date => liq_date_cap,
            .transaction_id => liq_id_cap,
        };
    }
};

const LiqTagAction = enum { set, append_re, push_np, push_ft };

const LiqTagRule = struct {
    tag: [2]u8,
    action: LiqTagAction,
    /// Used when `action == .set` (ignored for list/append actions).
    slot: LiqSlot = .form_number,
};

/// Tag dispatch for Prod 197 records. Unknown tags are ignored.
const liq_tag_rules = [_]LiqTagRule{
    .{ .tag = .{ 'F', 'M' }, .action = .set, .slot = .form_number },
    .{ .tag = .{ 'R', 'N' }, .action = .set, .slot = .company_number },
    .{ .tag = .{ 'N', 'A' }, .action = .set, .slot = .company_name },
    .{ .tag = .{ 'C', 'O' }, .action = .set, .slot = .court_ref },
    .{ .tag = .{ 'A', 'D' }, .action = .set, .slot = .appointment_date },
    .{ .tag = .{ 'D', 'O' }, .action = .set, .slot = .date_of_order },
    .{ .tag = .{ 'D', 'P' }, .action = .set, .slot = .date_of_petition },
    .{ .tag = .{ 'R', 'D' }, .action = .set, .slot = .resolution_date },
    .{ .tag = .{ 'M', 'D' }, .action = .set, .slot = .final_meeting_date },
    .{ .tag = .{ 'T', 'D' }, .action = .set, .slot = .termination_date },
    .{ .tag = .{ 'D', 'R' }, .action = .set, .slot = .date_registered },
    .{ .tag = .{ 'F', 'D' }, .action = .set, .slot = .form_dated },
    .{ .tag = .{ 'N', 'D' }, .action = .set, .slot = .new_dissolution_date },
    .{ .tag = .{ 'I', 'D' }, .action = .set, .slot = .transaction_id },
    .{ .tag = .{ 'R', 'E' }, .action = .append_re, .slot = .registered_office },
    .{ .tag = .{ 'N', 'P' }, .action = .push_np },
    .{ .tag = .{ 'F', 'T' }, .action = .push_ft },
};

fn findLiqTagRule(tag: []const u8) ?LiqTagRule {
    if (tag.len < 2) return null;
    for (liq_tag_rules) |rule| {
        if (rule.tag[0] == tag[0] and rule.tag[1] == tag[1]) return rule;
    }
    return null;
}

/// Accumulator for one Prod 197 form group. Fields are owned copies so stream
/// parsers can reuse input line buffers.
pub const LiqForm = struct {
    active: bool = false,
    /// Single-value tagged fields (see `LiqSlot`).
    slots: [LiqSlot.count][liq_field_cap]u8 = undefined,
    slot_lens: [LiqSlot.count]u8 = .{0} ** LiqSlot.count,
    practitioners: [liq_max_practitioners][liq_field_cap]u8 = undefined,
    practitioner_lens: [liq_max_practitioners]u8 = .{0} ** liq_max_practitioners,
    practitioner_count: u8 = 0,
    free_texts: [liq_max_free_texts][liq_ft_cap]u8 = undefined,
    free_text_lens: [liq_max_free_texts]u8 = .{0} ** liq_max_free_texts,
    free_text_count: u8 = 0,

    pub fn reset(self: *LiqForm) void {
        self.* = .{};
    }

    pub fn get(self: *const LiqForm, slot: LiqSlot) []const u8 {
        const i: usize = @intFromEnum(slot);
        return self.slots[i][0..self.slot_lens[i]];
    }

    pub fn formNumber(self: *const LiqForm) []const u8 {
        return self.get(.form_number);
    }
    pub fn companyNumber(self: *const LiqForm) []const u8 {
        return self.get(.company_number);
    }
    pub fn companyName(self: *const LiqForm) []const u8 {
        return self.get(.company_name);
    }
    pub fn courtRef(self: *const LiqForm) []const u8 {
        return self.get(.court_ref);
    }
    pub fn appointmentDate(self: *const LiqForm) []const u8 {
        return self.get(.appointment_date);
    }
    pub fn dateOfOrder(self: *const LiqForm) []const u8 {
        return self.get(.date_of_order);
    }
    pub fn dateOfPetition(self: *const LiqForm) []const u8 {
        return self.get(.date_of_petition);
    }
    pub fn resolutionDate(self: *const LiqForm) []const u8 {
        return self.get(.resolution_date);
    }
    pub fn finalMeetingDate(self: *const LiqForm) []const u8 {
        return self.get(.final_meeting_date);
    }
    pub fn terminationDate(self: *const LiqForm) []const u8 {
        return self.get(.termination_date);
    }
    pub fn dateRegistered(self: *const LiqForm) []const u8 {
        return self.get(.date_registered);
    }
    pub fn formDated(self: *const LiqForm) []const u8 {
        return self.get(.form_dated);
    }
    pub fn newDissolutionDate(self: *const LiqForm) []const u8 {
        return self.get(.new_dissolution_date);
    }
    pub fn transactionId(self: *const LiqForm) []const u8 {
        return self.get(.transaction_id);
    }
    pub fn registeredOffice(self: *const LiqForm) []const u8 {
        return self.get(.registered_office);
    }
    pub fn practitioner(self: *const LiqForm, i: usize) []const u8 {
        return self.practitioners[i][0..self.practitioner_lens[i]];
    }
    pub fn freeText(self: *const LiqForm, i: usize) []const u8 {
        return self.free_texts[i][0..self.free_text_lens[i]];
    }

    fn setSlot(self: *LiqForm, slot: LiqSlot, src: []const u8) void {
        const i: usize = @intFromEnum(slot);
        const cap = slot.cap();
        const take = @min(src.len, cap);
        @memcpy(self.slots[i][0..take], src[0..take]);
        self.slot_lens[i] = @intCast(take);
    }

    fn appendRegisteredOffice(self: *LiqForm, payload: []const u8) void {
        const i: usize = @intFromEnum(LiqSlot.registered_office);
        const cap = LiqSlot.registered_office.cap();
        if (self.slot_lens[i] == 0) {
            self.setSlot(.registered_office, payload);
            return;
        }
        if (self.slot_lens[i] >= cap) return;
        const space_at = self.slot_lens[i];
        if (space_at + 1 >= cap) return;
        self.slots[i][space_at] = ' ';
        self.slot_lens[i] = @intCast(space_at + 1);
        const room = cap - self.slot_lens[i];
        const take = @min(payload.len, room);
        @memcpy(self.slots[i][self.slot_lens[i]..][0..take], payload[0..take]);
        self.slot_lens[i] += @intCast(take);
    }

    /// Apply one tagged data record to this form (including the opening `FM`).
    pub fn applyRecord(self: *LiqForm, row: []const u8) void {
        if (row.len < 2) return;
        const rule = findLiqTagRule(row[0..2]) orelse return;
        const payload = if (row.len > 2) trimRightSpaces(row[2..]) else row[0..0];

        // Opening FM may arrive before `active` is set.
        if (rule.tag[0] == 'F' and rule.tag[1] == 'M') {
            self.active = true;
            self.setSlot(.form_number, payload);
            return;
        }
        if (!self.active) return;

        switch (rule.action) {
            .set => self.setSlot(rule.slot, payload),
            .append_re => self.appendRegisteredOffice(payload),
            .push_np => {
                if (self.practitioner_count < liq_max_practitioners) {
                    const i = self.practitioner_count;
                    const take = @min(payload.len, liq_field_cap);
                    @memcpy(self.practitioners[i][0..take], payload[0..take]);
                    self.practitioner_lens[i] = @intCast(take);
                    self.practitioner_count += 1;
                }
            },
            .push_ft => {
                if (self.free_text_count < liq_max_free_texts) {
                    const i = self.free_text_count;
                    const take = @min(payload.len, liq_ft_cap);
                    @memcpy(self.free_texts[i][0..take], payload[0..take]);
                    self.free_text_lens[i] = @intCast(take);
                    self.free_text_count += 1;
                }
            },
        }
    }
};

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

/// Row view that resolves character offsets once: byte indexing for pure ASCII
/// (hot path), UTF-8 character walking otherwise. Formatters use one layout.
pub const FieldView = struct {
    row: []const u8,
    ascii: bool,

    pub fn init(row: []const u8) FieldView {
        return .{ .row = row, .ascii = isAscii(row) };
    }

    /// Slice covering character range [start, end).
    pub fn get(self: FieldView, start: usize, end: usize) []const u8 {
        if (self.ascii) return clamp(self.row, start, end);
        return sliceChars(self.row, start, end);
    }

    pub fn atoi(self: FieldView, start: usize, end: usize) i32 {
        return fastAtoi(self.get(start, end));
    }
};

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
    const v = FieldView.init(row);
    const name_length: usize = @intCast(v.atoi(36, 40));
    var name = v.get(40, 40 + name_length -| 1);
    if (name.len > 0 and name[name.len - 1] == ' ') {
        name = trimRightSpaces(name);
    }

    var p: usize = 0;
    p = appendField(dest, p, v.get(0, 8));
    dest[p] = ',';
    p += 1;
    p = appendField(dest, p, v.get(9, 10));
    dest[p] = ',';
    p += 1;
    p = appendInt(dest, p, v.atoi(32, 36));
    dest[p] = ',';
    p += 1;
    p = appendField(dest, p, name);
    dest[p] = '\n';
    return p + 1;
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

/// Fill `out` from character ranges `[start, end)` on `v`.
fn fillFixed(v: FieldView, ranges: []const [2]usize, out: [][]const u8) void {
    std.debug.assert(ranges.len == out.len);
    for (ranges, out) |r, *slot| {
        slot.* = v.get(r[0], r[1]);
    }
}

/// Format a snapshot person record (Prod 195/216) as one CSV line (incl. newline).
/// `dest` must be at least `max_csv_row_bytes`.
pub fn formatPersonRow(dest: []u8, row: []const u8) usize {
    const v = FieldView.init(row);
    const ranges = [_][2]usize{
        .{ 0, 8 },   .{ 9, 10 },  .{ 10, 12 }, .{ 12, 24 }, .{ 24, 25 },
        .{ 32, 40 }, .{ 40, 48 }, .{ 48, 56 }, .{ 56, 64 }, .{ 64, 72 },
    };
    var fixed: [ranges.len][]const u8 = undefined;
    fillFixed(v, &ranges, &fixed);
    var var_parts: [14][]const u8 = undefined;
    const var_len: usize = @intCast(v.atoi(72, 76));
    splitChevron(v.get(76, 76 + var_len), var_parts[0..]);
    return writeCsvFields(dest, &fixed, &var_parts);
}

/// Format an update person record (Prod 198 / `DDDDUPDT`) as one CSV line.
/// Fixed layout per docs/Prod198_Update.md; variable data has 27 chevrons of
/// which the first 14 named fields are exported (trailing fillers omitted).
/// `dest` must be at least `max_csv_row_bytes`.
pub fn formatUpdatePersonRow(dest: []u8, row: []const u8) usize {
    const v = FieldView.init(row);
    // 0-based character positions from the Prod 198 person update layout.
    const ranges = [_][2]usize{
        .{ 0, 8 }, // Company Number
        .{ 9, 10 }, // App Date Origin
        .{ 10, 11 }, // Res Date Origin
        .{ 11, 12 }, // Correction Indicator
        .{ 12, 13 }, // Corporate Indicator
        .{ 15, 17 }, // Old Appointment Type
        .{ 17, 19 }, // New Appointment Type
        .{ 19, 31 }, // Old Person Number
        .{ 31, 43 }, // New Person Number
        .{ 43, 51 }, // Partial DOB
        .{ 51, 59 }, // Full DOB
        .{ 59, 67 }, // Old Person Postcode
        .{ 67, 75 }, // New Person Postcode
        .{ 75, 83 }, // Appointment Date
        .{ 83, 91 }, // Resignation Date
        .{ 91, 99 }, // Change Date
        .{ 99, 107 }, // Update Date
    };
    var fixed: [ranges.len][]const u8 = undefined;
    fillFixed(v, &ranges, &fixed);
    var var_parts: [14][]const u8 = undefined;
    const var_len: usize = @intCast(v.atoi(107, 111));
    splitChevron(v.get(111, 111 + var_len), var_parts[0..]);
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
    const v = FieldView.init(row);
    const ranges = [_][2]usize{ .{ 1, 13 }, .{ 13, 21 }, .{ 21, 29 } };
    var fixed: [ranges.len][]const u8 = undefined;
    fillFixed(v, &ranges, &fixed);
    var var_parts: [12][]const u8 = undefined;
    const var_len: usize = @intCast(v.atoi(29, 33));
    splitChevron(v.get(33, 33 + var_len), var_parts[0..]);
    return writeCsvFields(dest, &fixed, &var_parts);
}

/// Prod 192 type 2 — disqualification.
/// Field starts after SECTION follow real bulk files (docs table is off by 8
/// from DISQUALIFICATION-TYPE onward: dtype begins at 0-based 49, company at 117,
/// court-name length at 277).
pub fn formatDisqualificationRow(dest: []u8, row: []const u8) usize {
    const v = FieldView.init(row);
    var fields: [9][]const u8 = undefined;
    fields[0] = v.get(1, 13); // Person Number
    fields[1] = v.get(13, 21); // Start
    fields[2] = v.get(21, 29); // End
    fields[3] = v.get(29, 49); // Section
    fields[4] = v.get(49, 79); // Type
    fields[5] = v.get(79, 87); // Order/undertaking date
    fields[6] = v.get(87, 117); // Case number
    fields[7] = trimRightSpaces(v.get(117, 277));
    const court_len: usize = @intCast(v.atoi(277, 281));
    fields[8] = v.get(281, 281 + court_len);
    return writeCsvFields(dest, &fields, &.{});
}

/// Prod 192 type 3 — exemption.
pub fn formatExemptionRow(dest: []u8, row: []const u8) usize {
    const v = FieldView.init(row);
    var fields: [5][]const u8 = undefined;
    fields[0] = v.get(1, 13);
    fields[1] = v.get(13, 21);
    fields[2] = v.get(21, 29);
    fields[3] = v.get(29, 39);
    const name_len: usize = @intCast(v.atoi(39, 43));
    fields[4] = v.get(43, 43 + name_len);
    return writeCsvFields(dest, &fields, &.{});
}

/// Prod 192 type 4 — variation.
pub fn formatVariationRow(dest: []u8, row: []const u8) usize {
    const v = FieldView.init(row);
    var fields: [6][]const u8 = undefined;
    fields[0] = v.get(1, 13);
    fields[1] = v.get(13, 43);
    fields[2] = v.get(43, 51);
    fields[3] = v.get(51, 59);
    fields[4] = v.get(59, 89);
    const court_len: usize = @intCast(v.atoi(89, 93));
    fields[5] = v.get(93, 93 + court_len);
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
