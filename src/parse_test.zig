//! Unit tests for pure parse + in-memory snapshot conversion.
//! Fixtures are embedded from testdata/ (small; safe to keep in git).

const std = @import("std");
const parse = @import("parse.zig");
const snapshot = @import("snapshot.zig");
const c_api = @import("c_api.zig");

const mini_snapshot = @embedFile("testdata/mini_snapshot.dat");
const expected_companies = @embedFile("testdata/expected_companies.csv");
const expected_persons = @embedFile("testdata/expected_persons.csv");

test "classifyLine header company person trailer" {
    try std.testing.expectEqual(parse.LineKind.header, parse.classifyLine("DDDDSNAP425720260706"));
    try std.testing.expectEqual(parse.LineKind.trailer, parse.classifyLine("9999999900000004"));
    try std.testing.expectEqual(parse.LineKind.company, parse.classifyLine("029052131D                      00160024X<"));
    try std.testing.expectEqual(parse.LineKind.person, parse.classifyLine("029052132302900006800001Y       19940307"));
    try std.testing.expectEqual(parse.LineKind.other, parse.classifyLine("short"));
}

test "parseHeader extracts run and date" {
    const info = try parse.parseHeader("DDDDSNAP425720260706");
    try std.testing.expectEqualStrings("4257", info.run_number);
    try std.testing.expectEqualStrings("20260706", info.production_date);
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
    const n = parse.formatCompanyRow(&dest, row);
    const csv = dest[0..n];
    try std.testing.expectEqualStrings("02905213,D,16,I.T.K. (SAFETY) LIMITED\n", csv);
}

test "formatPersonRow splits chevrons" {
    const row = "029052132102038532340001        1995060119990201BB3 3LD 196608          0088<DAVID ROY<EVANS<<<<86 POLE LANE<DARWEN<LANCASHIRE<<<FINANCIAL DIRECTOR<BRITISH<ENGLAND<";
    var dest: [parse.max_csv_row_bytes]u8 = undefined;
    const n = parse.formatPersonRow(&dest, row);
    const csv = dest[0..n];
    try std.testing.expect(std.mem.startsWith(u8, csv, "02905213,1,02,038532340001, ,19950601,19990201,"));
    try std.testing.expect(std.mem.indexOf(u8, csv, "DAVID ROY") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "EVANS") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "FINANCIAL DIRECTOR") != null);
    try std.testing.expect(csv[csv.len - 1] == '\n');
}

test "appendField quotes commas and doubles quotes" {
    var dest: [64]u8 = undefined;
    const n = parse.appendField(&dest, 0, "a,b\"c");
    try std.testing.expectEqualStrings("\"a,b\"\"c\"", dest[0..n]);
}

test "parseSnapshot mini fixture matches expected CSV" {
    const allocator = std.testing.allocator;
    var result = try snapshot.parseSnapshot(allocator, mini_snapshot);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 2), result.companies);
    try std.testing.expectEqual(@as(i32, 3), result.persons);
    try std.testing.expectEqual(@as(i32, 5), result.trailer_count);

    try std.testing.expectEqualStrings(expected_companies, result.companies_csv);
    try std.testing.expectEqualStrings(expected_persons, result.persons_csv);
}

test "parseSnapshot trailer mismatch" {
    const bad =
        \\DDDDSNAP425720260706
        \\029052131D                      00010013WGFA LIMITED<
        \\9999999900000099
        \\
    ;
    try std.testing.expectError(error.TrailerMismatch, snapshot.parseSnapshot(std.testing.allocator, bad));
}

test "parseSnapshot missing trailer" {
    const bad =
        \\DDDDSNAP425720260706
        \\029052131D                      00010013WGFA LIMITED<
        \\
    ;
    try std.testing.expectError(error.MissingTrailer, snapshot.parseSnapshot(std.testing.allocator, bad));
}

test "C ABI ch_parse_snapshot on mini fixture" {
    var out: c_api.ChParseResult = .{};
    const rc = c_api.ch_parse_snapshot(mini_snapshot.ptr, mini_snapshot.len, &out);
    defer c_api.ch_parse_result_free(&out);

    try std.testing.expectEqual(c_api.CH_OK, rc);
    try std.testing.expectEqual(@as(i32, 2), out.companies);
    try std.testing.expectEqual(@as(i32, 3), out.persons);
    try std.testing.expectEqual(@as(i32, 5), out.trailer_count);
    try std.testing.expect(out.companies_csv.data != null);
    try std.testing.expect(out.persons_csv.data != null);
    try std.testing.expect(out.companies_csv.len > 0);
    try std.testing.expect(out.persons_csv.len > 0);
}

test "C ABI rejects null args" {
    var out: c_api.ChParseResult = .{};
    try std.testing.expectEqual(c_api.CH_ERR_INVALID_ARG, c_api.ch_parse_snapshot(null, 10, &out));
    try std.testing.expectEqual(c_api.CH_ERR_INVALID_ARG, c_api.ch_parse_snapshot(@as([*]const u8, @ptrCast("x")), 0, &out));
}
