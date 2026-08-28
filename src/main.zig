//! CLI entry point: local file/directory, HTTP(S) URL, or stdin (`-`) in, CSV files out.
//! Parsing logic lives in the `ch_fixedwidth` library.
//!
//! Invocation: `ch-fixedwidth [-workers N] -o DIR <input>`
//! `-o` is required (no cwd default). Flags must precede the positional input.

const std = @import("std");
const ch = @import("ch_fixedwidth");

fn printVersion() void {
    const info = ch.libraryInfo();
    std.debug.print("ch-fixedwidth {s} ({s})\n", .{ info.version, info.git_commit });
}

fn printHelp() void {
    std.debug.print(
        \\ch-fixedwidth — Companies House bulk fixed-width to named CSVs
        \\
        \\Usage:
        \\  ch-fixedwidth --version
        \\  ch-fixedwidth --help
        \\  ch-fixedwidth [-workers N] -o DIR <input>
        \\
        \\Options:
        \\  -o DIR           Output directory (required; created if missing).
        \\                   There is no default; the current directory is not used.
        \\  -workers N       Officers seek-split worker threads (default: CPU count, max 32)
        \\  -h, --help       Show this help
        \\  -V, --version    Print version and git commit
        \\
        \\Flags must come before the positional <input>.
        \\
        \\Input:
        \\  file             Path to a single .dat file
        \\  directory        Top-level *.dat files (one after another)
        \\  http(s)://...    Stream a remote .dat
        \\  -                Read a .dat from stdin
        \\
        \\Output:
        \\  CSVs written to the directory given with -o (created if missing).
        \\  Filenames: {{stem}}_data_{{basename}}.csv (stdin basename is "stdin").
        \\
        \\Products and output stems:
        \\
    , .{});

    for (ch.parse.FileType.all) |ft| {
        std.debug.print("  {s} ({s})\n", .{ ft.displayName(), ft.identifier() });
        for (ft.outputKinds()) |kind| {
            std.debug.print("    {s}_*.csv\n", .{kind.fileStem()});
        }
    }

    std.debug.print(
        \\
        \\Exit codes:
        \\  0  Success (trailer counts match). Prod 197 unknown tags are
        \\     warnings on stderr; they do not change the exit code.
        \\  1  Failure (unknown record, overflow, trailer mismatch, I/O, …)
        \\
        \\A failed run leaves whatever CSVs were already written.
        \\
    , .{});
}

fn isHelpFlag(s: []const u8) bool {
    return std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h");
}

fn isVersionFlag(s: []const u8) bool {
    return std.mem.eql(u8, s, "--version") or std.mem.eql(u8, s, "-V");
}

fn isOutputFlag(s: []const u8) bool {
    return std.mem.eql(u8, s, "-o") or std.mem.eql(u8, s, "--output");
}

fn isWorkersFlag(s: []const u8) bool {
    return std.mem.eql(u8, s, "-workers") or std.mem.eql(u8, s, "--workers");
}

const ParseError = error{
    MissingOutput,
    MissingInput,
    MissingOutputValue,
    MissingWorkersValue,
    InvalidWorkers,
    DuplicateOutput,
    DuplicateWorkers,
    UnknownOption,
    ExtraArguments,
    FlagsAfterInput,
};

const ConvertArgs = struct {
    input: []const u8,
    output_folder: []const u8,
    workers: ?usize,
};

const CliAction = union(enum) {
    help,
    version,
    convert: ConvertArgs,
};

fn parsePositiveWorkers(s: []const u8) ?usize {
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    if (n == 0) return null;
    return n;
}

/// Parse `args` (including argv[0]). Help and version may appear anywhere.
/// Conversion flags (`-o`, `-workers`) must precede the single positional input.
fn parseArgs(args: []const []const u8) ParseError!CliAction {
    var output_folder: ?[]const u8 = null;
    var workers: ?usize = null;
    var input: ?[]const u8 = null;
    var saw_help = false;
    var saw_version = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];

        if (isHelpFlag(a)) {
            saw_help = true;
            continue;
        }
        if (isVersionFlag(a)) {
            saw_version = true;
            continue;
        }

        if (isOutputFlag(a)) {
            if (input != null) return error.FlagsAfterInput;
            if (output_folder != null) return error.DuplicateOutput;
            i += 1;
            if (i >= args.len) return error.MissingOutputValue;
            output_folder = args[i];
            continue;
        }

        if (isWorkersFlag(a)) {
            if (input != null) return error.FlagsAfterInput;
            if (workers != null) return error.DuplicateWorkers;
            i += 1;
            if (i >= args.len) return error.MissingWorkersValue;
            workers = parsePositiveWorkers(args[i]) orelse return error.InvalidWorkers;
            continue;
        }

        if (a.len > 1 and a[0] == '-') {
            return error.UnknownOption;
        }

        if (input != null) return error.ExtraArguments;
        input = a;
    }

    if (saw_help) return .help;
    if (saw_version) return .version;
    if (output_folder == null) return error.MissingOutput;
    if (input == null) return error.MissingInput;

    return .{ .convert = .{
        .input = input.?,
        .output_folder = output_folder.?,
        .workers = workers,
    } };
}

fn printParseError(err: ParseError) void {
    const msg: []const u8 = switch (err) {
        error.MissingOutput => "Error: -o DIR is required (output is not defaulted to the current directory)",
        error.MissingInput => "Error: missing input (file, directory, URL, or -)",
        error.MissingOutputValue => "Error: -o requires a directory argument",
        error.MissingWorkersValue => "Error: -workers requires a positive integer",
        error.InvalidWorkers => "Error: -workers must be a positive integer",
        error.DuplicateOutput => "Error: -o specified more than once",
        error.DuplicateWorkers => "Error: -workers specified more than once",
        error.UnknownOption => "Error: unknown option",
        error.ExtraArguments => "Error: unexpected extra argument",
        error.FlagsAfterInput => "Error: flags must come before the positional input",
    };
    std.debug.print("{s}\n", .{msg});
}

pub fn main(init: std.process.Init) void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = init.minimal.args.toSlice(arena) catch {
        std.debug.print("Error reading arguments\n", .{});
        std.process.exit(1);
    };

    const action = parseArgs(args) catch |err| {
        printParseError(err);
        printHelp();
        std.process.exit(1);
    };

    switch (action) {
        .help => {
            printHelp();
            std.process.exit(0);
        },
        .version => {
            printVersion();
            std.process.exit(0);
        },
        .convert => |c| {
            const code = ch.file_convert.processInput(io, arena, c.input, c.output_folder, c.workers) catch |err| {
                std.debug.print("Fatal error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            std.process.exit(code);
        },
    }
}

fn expectConvert(args: []const []const u8, input: []const u8, output: []const u8, workers: ?usize) !void {
    const action = try parseArgs(args);
    const c = action.convert;
    try std.testing.expectEqualStrings(input, c.input);
    try std.testing.expectEqualStrings(output, c.output_folder);
    try std.testing.expectEqual(workers, c.workers);
}

test "parseArgs requires -o and a positional input" {
    try std.testing.expectError(error.MissingOutput, parseArgs(&.{"ch-fixedwidth"}));
    try std.testing.expectError(error.MissingOutput, parseArgs(&.{ "ch-fixedwidth", "in.dat" }));
    try std.testing.expectError(error.MissingInput, parseArgs(&.{ "ch-fixedwidth", "-o", "out" }));
    try expectConvert(&.{ "ch-fixedwidth", "-o", "out", "in.dat" }, "in.dat", "out", null);
}

test "parseArgs accepts -workers before the positional" {
    try expectConvert(
        &.{ "ch-fixedwidth", "-workers", "4", "-o", "out", "in.dat" },
        "in.dat",
        "out",
        4,
    );
    try expectConvert(
        &.{ "ch-fixedwidth", "-o", "out", "--workers", "8", "in.dat" },
        "in.dat",
        "out",
        8,
    );
    try expectConvert(
        &.{ "ch-fixedwidth", "-o", "csv", "-" },
        "-",
        "csv",
        null,
    );
}

test "parseArgs rejects flags after the positional" {
    try std.testing.expectError(error.FlagsAfterInput, parseArgs(&.{ "ch-fixedwidth", "in.dat", "-o", "out" }));
    try std.testing.expectError(error.FlagsAfterInput, parseArgs(&.{ "ch-fixedwidth", "-o", "out", "in.dat", "-workers", "2" }));
    try std.testing.expectError(error.ExtraArguments, parseArgs(&.{ "ch-fixedwidth", "-o", "out", "in.dat", "extra" }));
}

test "parseArgs rejects invalid workers and unknown flags" {
    try std.testing.expectError(error.InvalidWorkers, parseArgs(&.{ "ch-fixedwidth", "-workers", "0", "-o", "out", "in.dat" }));
    try std.testing.expectError(error.InvalidWorkers, parseArgs(&.{ "ch-fixedwidth", "-workers", "x", "-o", "out", "in.dat" }));
    try std.testing.expectError(error.MissingWorkersValue, parseArgs(&.{ "ch-fixedwidth", "-workers" }));
    try std.testing.expectError(error.MissingOutputValue, parseArgs(&.{ "ch-fixedwidth", "-o" }));
    try std.testing.expectError(error.UnknownOption, parseArgs(&.{ "ch-fixedwidth", "-q", "-o", "out", "in.dat" }));
    try std.testing.expectError(error.DuplicateOutput, parseArgs(&.{ "ch-fixedwidth", "-o", "a", "-o", "b", "in.dat" }));
}

test "parseArgs help and version win even without -o" {
    try std.testing.expectEqual(CliAction.help, try parseArgs(&.{ "ch-fixedwidth", "--help" }));
    try std.testing.expectEqual(CliAction.help, try parseArgs(&.{ "ch-fixedwidth", "-h", "-o", "out", "in.dat" }));
    try std.testing.expectEqual(CliAction.version, try parseArgs(&.{ "ch-fixedwidth", "-V" }));
    try std.testing.expectEqual(CliAction.version, try parseArgs(&.{ "ch-fixedwidth", "--version" }));
}
