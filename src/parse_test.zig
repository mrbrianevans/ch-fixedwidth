//! Unit tests for pure parse + in-memory document conversion.
//! Fixtures are embedded from testdata/ (small; safe to keep in git).

const std = @import("std");
const parse = @import("parse.zig");
const document = @import("document.zig");
const stream_mod = @import("stream.zig");
const c_api = @import("c_api.zig");

const mini_snapshot = @embedFile("testdata/mini_snapshot.dat");
const expected_companies = @embedFile("testdata/expected_companies.csv");
const expected_persons = @embedFile("testdata/expected_persons.csv");
const mini_update = @embedFile("testdata/mini_update.dat");
const expected_update_companies = @embedFile("testdata/expected_update_companies.csv");
const expected_update_persons = @embedFile("testdata/expected_update_persons.csv");

test "classifyLine header company person trailer" {
    try std.testing.expectEqual(parse.LineKind.header, parse.classifyLine("DDDDSNAP425720260706"));
    try std.testing.expectEqual(parse.LineKind.header, parse.classifyLine("DDDDUPDT172420161018"));
    try std.testing.expectEqual(parse.LineKind.header, parse.classifyLine("DISQUALS000120240501"));
    try std.testing.expectEqual(parse.LineKind.trailer, parse.classifyLine("9999999900000004"));
    try std.testing.expectEqual(parse.LineKind.company, parse.classifyLine("029052131D                      00160024X<"));
    try std.testing.expectEqual(parse.LineKind.person, parse.classifyLine("029052132302900006800001Y       19940307"));
    try std.testing.expectEqual(parse.LineKind.other, parse.classifyLine("short"));
}

test "identifyFileType maps known header magics" {
    try std.testing.expectEqual(parse.FileType.officers_snapshot, try parse.identifyFileType("DDDDSNAP"));
    try std.testing.expectEqual(parse.FileType.officers_update, try parse.identifyFileType("DDDDUPDT"));
    try std.testing.expectEqual(parse.FileType.disqualifications, try parse.identifyFileType("DISQUALS"));
    try std.testing.expectEqual(parse.FileType.liquidation, try parse.identifyFileType("LIQNFORM"));
    try std.testing.expectError(error.UnsupportedFileType, parse.identifyFileType("NOTASNAP"));
    try std.testing.expectError(error.UnsupportedFileType, parse.identifyFileType("SHORT"));
    try std.testing.expectEqual(parse.FileType.officers_snapshot, try parse.identifyFileTypeFromInput("DDDDSNAP425720260706\n"));
    try std.testing.expect(parse.FileType.officers_snapshot.isImplemented());
    try std.testing.expect(parse.FileType.officers_update.isImplemented());
    try std.testing.expect(parse.FileType.disqualifications.isImplemented());
    try std.testing.expect(parse.FileType.liquidation.isImplemented());
}

test "parseHeader extracts run and date for all known products" {
    const snap = try parse.parseHeader("DDDDSNAP425720260706");
    try std.testing.expectEqual(parse.FileType.officers_snapshot, snap.file_type);
    try std.testing.expectEqualStrings("4257", snap.run_number);
    try std.testing.expectEqualStrings("20260706", snap.production_date);

    const upd = try parse.parseHeader("DDDDUPDT172420161018");
    try std.testing.expectEqual(parse.FileType.officers_update, upd.file_type);
    try std.testing.expectEqualStrings("1724", upd.run_number);
    try std.testing.expectEqualStrings("20161018", upd.production_date);

    const disq = try parse.parseHeader("DISQUALS000120240501");
    try std.testing.expectEqual(parse.FileType.disqualifications, disq.file_type);
    try std.testing.expectEqualStrings("0001", disq.run_number);
    try std.testing.expectEqualStrings("20240501", disq.production_date);

    const liq = try parse.parseHeader("LIQNFORM427620260731");
    try std.testing.expectEqual(parse.FileType.liquidation, liq.file_type);
    try std.testing.expectEqualStrings("4276", liq.run_number);
    try std.testing.expectEqualStrings("20260731", liq.production_date);
}

test "parseHeader rejects bad header" {
    try std.testing.expectError(error.UnsupportedFileType, parse.parseHeader("NOTASNAP000000000000"));
    try std.testing.expectError(error.UnsupportedFileType, parse.parseHeader("DDDDSNAP"));
}

test "parseTrailerCount" {
    try std.testing.expectEqual(@as(i32, 4), parse.parseTrailerCount("9999999900000004"));
    try std.testing.expectEqual(@as(i32, 6182956), parse.parseTrailerCount("9999999906182956"));
}

test "formatCompanyRow ASCII" {
    const row = "029052131D                      00160024I.T.K. (SAFETY) LIMITED<                                                                                                                                         ";
    var dest: [parse.max_csv_row_bytes]u8 = undefined;
    const n = try parse.formatCompanyRow(&dest, row);
    const csv = dest[0..n];
    try std.testing.expectEqualStrings("02905213,D,16,I.T.K. (SAFETY) LIMITED\n", csv);
}

test "formatPersonRow splits chevrons" {
    const row = "029052132102038532340001        1995060119990201BB3 3LD 196608          0088<DAVID ROY<EVANS<<<<86 POLE LANE<DARWEN<LANCASHIRE<<<FINANCIAL DIRECTOR<BRITISH<ENGLAND<";
    var dest: [parse.max_csv_row_bytes]u8 = undefined;
    const n = try parse.formatPersonRow(&dest, row);
    const csv = dest[0..n];
    try std.testing.expect(std.mem.startsWith(u8, csv, "02905213,1,02,038532340001, ,19950601,19990201,"));
    try std.testing.expect(std.mem.indexOf(u8, csv, "DAVID ROY") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "EVANS") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "FINANCIAL DIRECTOR") != null);
    try std.testing.expect(csv[csv.len - 1] == '\n');
}

test "appendField quotes commas and doubles quotes" {
    var dest: [64]u8 = undefined;
    const n = try parse.appendField(&dest, 0, "a,b\"c");
    try std.testing.expectEqualStrings("\"a,b\"\"c\"", dest[0..n]);
}

test "appendField and formatCompanyRow reject undersized dest" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.RowTooLarge, parse.appendField(&tiny, 0, "hello"));
    const row = "029052131D                      00160024I.T.K. (SAFETY) LIMITED<";
    try std.testing.expectError(error.RowTooLarge, parse.formatCompanyRow(&tiny, row));
}

test "parseDocument mini fixture matches expected CSV" {
    const allocator = std.testing.allocator;
    var result = try document.parseDocument(allocator, mini_snapshot);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 2), result.companies);
    try std.testing.expectEqual(@as(i32, 3), result.persons);
    try std.testing.expectEqual(@as(i32, 5), result.trailer_count);

    try std.testing.expectEqualStrings(expected_companies, result.companies_csv);
    try std.testing.expectEqualStrings(expected_persons, result.persons_csv);
}

test "parseDocument trailer mismatch" {
    const bad =
        \\DDDDSNAP425720260706
        \\029052131D                      00010013WGFA LIMITED<
        \\9999999900000099
        \\
    ;
    try std.testing.expectError(error.TrailerMismatch, document.parseDocument(std.testing.allocator, bad));
}

test "parseDocument missing trailer" {
    const bad =
        \\DDDDSNAP425720260706
        \\029052131D                      00010013WGFA LIMITED<
        \\
    ;
    try std.testing.expectError(error.MissingTrailer, document.parseDocument(std.testing.allocator, bad));
}

test "parseDocument rejects non-snapshot prefix" {
    const bad =
        \\NOTASNAP425720260706
        \\029052131D                      00010013WGFA LIMITED<
        \\9999999900000001
        \\
    ;
    try std.testing.expectError(error.UnsupportedFileType, document.parseDocument(std.testing.allocator, bad));
    try std.testing.expectError(error.UnsupportedFileType, document.parseDocument(std.testing.allocator, ""));
    try std.testing.expectError(error.UnsupportedFileType, document.parseDocument(std.testing.allocator, "random csv,data\n"));
}

test "parseDocument mini update fixture matches expected CSV" {
    const allocator = std.testing.allocator;
    var result = try document.parseDocument(allocator, mini_update);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 4), result.companies);
    try std.testing.expectEqual(@as(i32, 9), result.persons);
    try std.testing.expectEqual(@as(i32, 13), result.trailer_count);

    try std.testing.expectEqualStrings(expected_update_companies, result.companies_csv);
    try std.testing.expectEqualStrings(expected_update_persons, result.persons_csv);
}

test "formatUpdatePersonRow extracts fixed and chevron fields" {
    const row = "0426797621     0101186084280001186084280003196906                  TR27 5ET20100329        20260724202607240146MR<WARREN ALAN<DIXON<<<<C/O CALLOOSE CARAVAN PARK 16 CALLOOSE LANE W<LEEDSTOWN<HAYLE<CORNWALL<ENGLAND<MANAGER<BRITISH<UNITED KINGDOM<<<<<<<<<<<<<<";
    var dest: [parse.max_csv_row_bytes]u8 = undefined;
    const n = try parse.formatUpdatePersonRow(&dest, row);
    const csv = dest[0..n];
    try std.testing.expect(std.mem.startsWith(u8, csv, "04267976,1, , , ,01,01,186084280001,186084280003,196906  ,"));
    try std.testing.expect(std.mem.indexOf(u8, csv, "TR27 5ET") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "WARREN ALAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "DIXON") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "MANAGER") != null);
    try std.testing.expect(csv[csv.len - 1] == '\n');
}

test "LiqForm applyRecord fails when practitioner limit exceeded" {
    var form: parse.LiqForm = .{};
    try form.applyRecord("FM0001");
    var i: usize = 0;
    while (i < parse.liq_max_practitioners) : (i += 1) {
        try form.applyRecord("NPNAME<ADDR");
    }
    try std.testing.expectError(error.RecordLimitExceeded, form.applyRecord("NPONE MORE"));
}

test "parseDocument fails when liquidation form exceeds practitioner limit" {
    // One form group with more NP lines than liq_max_practitioners.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, "LIQNFORM427620260731\n");
    try list.appendSlice(std.testing.allocator, "FMTESTFORM\n");
    try list.appendSlice(std.testing.allocator, "CN12345678\n");
    var i: usize = 0;
    while (i < parse.liq_max_practitioners + 1) : (i += 1) {
        try list.appendSlice(std.testing.allocator, "NPA PRACTITIONER\n");
    }
    try list.appendSlice(std.testing.allocator, "9999999900000019\n");
    try std.testing.expectError(
        error.RecordLimitExceeded,
        document.parseDocument(std.testing.allocator, list.items),
    );
}

const mini_disqual = @embedFile("testdata/mini_disqual.dat");
const expected_disqual_persons = @embedFile("testdata/expected_disqual_persons.csv");
const expected_disqualifications = @embedFile("testdata/expected_disqualifications.csv");
const expected_exemptions = @embedFile("testdata/expected_exemptions.csv");
const expected_variations = @embedFile("testdata/expected_variations.csv");

test "parseDocument mini disqual fixture matches expected CSV" {
    const allocator = std.testing.allocator;
    var result = try document.parseDocument(allocator, mini_disqual);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 3), result.persons);
    try std.testing.expectEqual(@as(i32, 3), result.disqualifications);
    try std.testing.expectEqual(@as(i32, 2), result.exemptions);
    try std.testing.expectEqual(@as(i32, 1), result.variations);
    try std.testing.expectEqual(@as(i32, 9), result.trailer_count);

    try std.testing.expectEqualStrings(expected_disqual_persons, result.persons_csv);
    try std.testing.expectEqualStrings(expected_disqualifications, result.disqualifications_csv);
    try std.testing.expectEqualStrings(expected_exemptions, result.exemptions_csv);
    try std.testing.expectEqualStrings(expected_variations, result.variations_csv);
}

test "stream matches snapshot on mini disqual with tiny chunks" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{ .batch_rows = 2, .batch_bytes = 64 });
    defer s.deinit();

    for (mini_disqual) |byte| {
        try s.feed(&.{byte});
    }
    try s.finish();

    var persons = std.ArrayList(u8).empty;
    defer persons.deinit(allocator);
    var disq = std.ArrayList(u8).empty;
    defer disq.deinit(allocator);
    var exempt = std.ArrayList(u8).empty;
    defer exempt.deinit(allocator);
    var variations = std.ArrayList(u8).empty;
    defer variations.deinit(allocator);

    while (s.nextBatch()) |batch| {
        var b = batch;
        defer b.deinit(allocator);
        switch (b.kind) {
            .persons => try persons.appendSlice(allocator, b.data),
            .disqualifications => try disq.appendSlice(allocator, b.data),
            .exemptions => try exempt.appendSlice(allocator, b.data),
            .variations => try variations.appendSlice(allocator, b.data),
            .companies, .forms, .practitioners, .free_text => {},
        }
    }

    try std.testing.expectEqual(@as(i32, 3), s.countOf(.persons));
    try std.testing.expectEqual(@as(i32, 3), s.countOf(.disqualifications));
    try std.testing.expectEqual(@as(i32, 2), s.countOf(.exemptions));
    try std.testing.expectEqual(@as(i32, 1), s.countOf(.variations));
    try std.testing.expectEqual(@as(i32, 9), s.trailer_count.?);
    try std.testing.expectEqualStrings(expected_disqual_persons, persons.items);
    try std.testing.expectEqualStrings(expected_disqualifications, disq.items);
    try std.testing.expectEqualStrings(expected_exemptions, exempt.items);
    try std.testing.expectEqualStrings(expected_variations, variations.items);
}

test "classifyDisqualLine distinguishes header trailer and body types" {
    try std.testing.expectEqual(parse.DisqualLineKind.header, parse.classifyDisqualLine("DISQUALS428620260801"));
    try std.testing.expectEqual(parse.DisqualLineKind.trailer, parse.classifyDisqualLine("DISQUALS/00000003/00000003/00000002/00000001/00000009"));
    try std.testing.expectEqual(parse.DisqualLineKind.person, parse.classifyDisqualLine("1000987800001"));
    try std.testing.expectEqual(parse.DisqualLineKind.disqualification, parse.classifyDisqualLine("2000987800001"));
    try std.testing.expectEqual(parse.DisqualLineKind.exemption, parse.classifyDisqualLine("3054199360002"));
    try std.testing.expectEqual(parse.DisqualLineKind.variation, parse.classifyDisqualLine("4309153140001"));
}

const mini_liquidation = @embedFile("testdata/mini_liquidation.dat");
const expected_liq_forms = @embedFile("testdata/expected_liq_forms.csv");
const expected_liq_practitioners = @embedFile("testdata/expected_liq_practitioners.csv");
const expected_liq_free_text = @embedFile("testdata/expected_liq_free_text.csv");

test "classifyLiqLine distinguishes header trailer form and data" {
    try std.testing.expectEqual(parse.LiqLineKind.header, parse.classifyLiqLine("LIQNFORM427620260731"));
    try std.testing.expectEqual(parse.LiqLineKind.trailer, parse.classifyLiqLine("9999999900002215"));
    try std.testing.expectEqual(parse.LiqLineKind.form, parse.classifyLiqLine("FM600       "));
    try std.testing.expectEqual(parse.LiqLineKind.data, parse.classifyLiqLine("RNNI037932"));
    try std.testing.expectEqual(parse.LiqLineKind.data, parse.classifyLiqLine("ID3535999865"));
    try std.testing.expectEqual(parse.LiqLineKind.other, parse.classifyLiqLine("X"));
}

test "parseDocument mini liquidation fixture matches expected CSV" {
    const allocator = std.testing.allocator;
    var result = try document.parseDocument(allocator, mini_liquidation);
    defer result.deinit(allocator);

    try std.testing.expectEqual(parse.FileType.liquidation, result.file_type);
    try std.testing.expectEqual(@as(i32, 8), result.forms);
    try std.testing.expectEqual(@as(i32, 7), result.practitioners);
    try std.testing.expectEqual(@as(i32, 3), result.free_text);
    try std.testing.expectEqual(@as(i32, 0), result.companies);
    try std.testing.expectEqual(@as(i32, 61), result.trailer_count);

    try std.testing.expectEqualStrings(expected_liq_forms, result.forms_csv);
    try std.testing.expectEqualStrings(expected_liq_practitioners, result.practitioners_csv);
    try std.testing.expectEqualStrings(expected_liq_free_text, result.free_text_csv);
}

test "stream matches document on mini liquidation with tiny chunks" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{ .batch_rows = 2, .batch_bytes = 64 });
    defer s.deinit();

    for (mini_liquidation) |byte| {
        try s.feed(&.{byte});
    }
    try s.finish();

    var forms = std.ArrayList(u8).empty;
    defer forms.deinit(allocator);
    var prac = std.ArrayList(u8).empty;
    defer prac.deinit(allocator);
    var free_t = std.ArrayList(u8).empty;
    defer free_t.deinit(allocator);

    while (s.nextBatch()) |batch| {
        var b = batch;
        defer b.deinit(allocator);
        switch (b.kind) {
            .forms => try forms.appendSlice(allocator, b.data),
            .practitioners => try prac.appendSlice(allocator, b.data),
            .free_text => try free_t.appendSlice(allocator, b.data),
            .companies, .persons, .disqualifications, .exemptions, .variations => {},
        }
    }

    try std.testing.expectEqual(@as(i32, 8), s.countOf(.forms));
    try std.testing.expectEqual(@as(i32, 7), s.countOf(.practitioners));
    try std.testing.expectEqual(@as(i32, 3), s.countOf(.free_text));
    try std.testing.expectEqual(@as(i32, 0), s.countOf(.companies));
    try std.testing.expectEqual(@as(i32, 61), s.trailer_count.?);
    try std.testing.expectEqual(@as(i32, 61), s.liq_data_records);
    try std.testing.expectEqualStrings(expected_liq_forms, forms.items);
    try std.testing.expectEqualStrings(expected_liq_practitioners, prac.items);
    try std.testing.expectEqualStrings(expected_liq_free_text, free_t.items);
}

test "stream accepts LIQNFORM magic" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{});
    defer s.deinit();
    try s.feed("LIQNFORM4276");
    try std.testing.expectEqual(parse.FileType.liquidation, s.file_type.?);
}

test "C ABI ch_parse on mini fixture" {
    var out: c_api.ChParseResult = .{};
    const rc = c_api.ch_parse(mini_snapshot.ptr, mini_snapshot.len, &out);
    defer c_api.ch_parse_result_free(&out);

    try std.testing.expectEqual(c_api.CH_OK, rc);
    try std.testing.expectEqual(@as(i32, c_api.CH_FILE_OFFICERS_SNAPSHOT), out.file_type);
    try std.testing.expectEqual(@as(i32, 2), out.companies);
    try std.testing.expectEqual(@as(i32, 3), out.persons);
    try std.testing.expectEqual(@as(i32, 5), out.trailer_count);
    try std.testing.expectEqual(@as(i32, 0), out.forms);
    try std.testing.expect(out.companies_csv.data != null);
    try std.testing.expect(out.persons_csv.data != null);
    try std.testing.expect(out.companies_csv.len > 0);
    try std.testing.expect(out.persons_csv.len > 0);
}

test "C ABI rejects null args" {
    var out: c_api.ChParseResult = .{};
    try std.testing.expectEqual(c_api.CH_ERR_INVALID_ARG, c_api.ch_parse(null, 10, &out));
    try std.testing.expectEqual(c_api.CH_ERR_INVALID_ARG, c_api.ch_parse(@as([*]const u8, @ptrCast("x")), 0, &out));
}

test "stream matches snapshot on mini fixture with tiny chunks" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{ .batch_rows = 2, .batch_bytes = 64 });
    defer s.deinit();

    // Feed one byte at a time to stress the carry buffer.
    for (mini_snapshot) |byte| {
        try s.feed(&.{byte});
    }
    try s.finish();

    var companies = std.ArrayList(u8).empty;
    defer companies.deinit(allocator);
    var persons = std.ArrayList(u8).empty;
    defer persons.deinit(allocator);

    while (s.nextBatch()) |batch| {
        var b = batch;
        defer b.deinit(allocator);
        switch (b.kind) {
            .companies => try companies.appendSlice(allocator, b.data),
            .persons => try persons.appendSlice(allocator, b.data),
            .disqualifications, .exemptions, .variations, .forms, .practitioners, .free_text => {},
        }
    }

    try std.testing.expectEqual(@as(i32, 2), s.countOf(.companies));
    try std.testing.expectEqual(@as(i32, 3), s.countOf(.persons));
    try std.testing.expectEqual(@as(i32, 5), s.trailer_count.?);
    try std.testing.expectEqualStrings(expected_companies, companies.items);
    try std.testing.expectEqualStrings(expected_persons, persons.items);
}

test "stream rejects wrong file prefix early" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{});
    defer s.deinit();

    try std.testing.expectError(error.UnsupportedFileType, s.feed("NOTASNAP4257\n"));
}

test "stream rejects wrong prefix across tiny chunks" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{});
    defer s.deinit();

    // Same path the web client can take: magic split across feeds.
    try s.feed("NOTA");
    try std.testing.expectError(error.UnsupportedFileType, s.feed("SNAP!!!!"));
}

test "stream accepts DDDDUPDT and DISQUALS magic" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{});
    defer s.deinit();
    try s.feed("DDDDUPDT1724");
    try std.testing.expectEqual(parse.FileType.officers_update, s.file_type.?);

    var s2 = stream_mod.Stream.init(allocator, .{});
    defer s2.deinit();
    try s2.feed("DISQUALS0001");
    try std.testing.expectEqual(parse.FileType.disqualifications, s2.file_type.?);
}

test "stream matches snapshot on mini update with tiny chunks" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{ .batch_rows = 2, .batch_bytes = 64 });
    defer s.deinit();

    for (mini_update) |byte| {
        try s.feed(&.{byte});
    }
    try s.finish();

    var companies = std.ArrayList(u8).empty;
    defer companies.deinit(allocator);
    var persons = std.ArrayList(u8).empty;
    defer persons.deinit(allocator);

    while (s.nextBatch()) |batch| {
        var b = batch;
        defer b.deinit(allocator);
        switch (b.kind) {
            .companies => try companies.appendSlice(allocator, b.data),
            .persons => try persons.appendSlice(allocator, b.data),
            .disqualifications, .exemptions, .variations, .forms, .practitioners, .free_text => {},
        }
    }

    try std.testing.expectEqual(@as(i32, 4), s.countOf(.companies));
    try std.testing.expectEqual(@as(i32, 9), s.countOf(.persons));
    try std.testing.expectEqual(@as(i32, 13), s.trailer_count.?);
    try std.testing.expectEqualStrings(expected_update_companies, companies.items);
    try std.testing.expectEqualStrings(expected_update_persons, persons.items);
}

test "stream finish rejects empty input" {
    const allocator = std.testing.allocator;
    var s = stream_mod.Stream.init(allocator, .{});
    defer s.deinit();
    try std.testing.expectError(error.UnsupportedFileType, s.finish());
}

test "C ABI stream feed/finish on mini fixture" {
    const s = c_api.ch_stream_create(null) orelse return error.TestUnexpectedResult;
    defer c_api.ch_stream_destroy(s);

    // Two coarse chunks split mid-file.
    const mid = mini_snapshot.len / 2;
    try std.testing.expectEqual(c_api.CH_OK, c_api.ch_stream_feed(s, mini_snapshot.ptr, mid));
    try std.testing.expectEqual(c_api.CH_OK, c_api.ch_stream_feed(s, mini_snapshot[mid..].ptr, mini_snapshot.len - mid));
    try std.testing.expectEqual(c_api.CH_OK, c_api.ch_stream_finish(s));

    var stats: c_api.ChStreamStats = .{};
    c_api.ch_stream_stats(s, &stats);
    try std.testing.expectEqual(@as(i32, c_api.CH_FILE_OFFICERS_SNAPSHOT), stats.file_type);
    try std.testing.expectEqual(@as(i32, 2), stats.companies);
    try std.testing.expectEqual(@as(i32, 3), stats.persons);
    try std.testing.expectEqual(@as(i32, 5), stats.trailer_count);

    var got_companies: usize = 0;
    var got_persons: usize = 0;
    while (true) {
        var batch: c_api.ChCsvBatch = .{};
        const n = c_api.ch_stream_next_batch(s, &batch);
        if (n == 0) break;
        try std.testing.expectEqual(@as(c_int, 1), n);
        defer c_api.ch_csv_batch_free(&batch);
        if (batch.kind == c_api.CH_OUTPUT_COMPANIES) {
            got_companies += @intCast(batch.row_count);
        } else if (batch.kind == c_api.CH_OUTPUT_PERSONS) {
            got_persons += @intCast(batch.row_count);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), got_companies);
    try std.testing.expectEqual(@as(usize, 3), got_persons);
}
