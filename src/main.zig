//! CLI entry point: local file/directory, HTTP(S) URL, or stdin (`-`) in, CSV files out.
//! Parsing logic lives in the `ch_fixedwidth` library.

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
        \\  ch-fixedwidth <input> <output_folder>
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -V, --version    Print version and git commit
        \\
        \\Input:
        \\  file             Path to a single .dat file
        \\  directory        Top-level *.dat files (one after another)
        \\  http(s)://...    Stream a remote .dat
        \\  -                Read a .dat from stdin
        \\
        \\Output:
        \\  CSVs written to <output_folder> (created if missing).
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

pub fn main(init: std.process.Init) void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = init.minimal.args.toSlice(arena) catch {
        std.debug.print("Error reading arguments\n", .{});
        std.process.exit(1);
    };

    if (args.len < 2) {
        printHelp();
        std.process.exit(1);
    }

    if (isHelpFlag(args[1])) {
        printHelp();
        std.process.exit(0);
    }
    if (isVersionFlag(args[1])) {
        printVersion();
        std.process.exit(0);
    }

    if (args.len < 3) {
        printHelp();
        std.process.exit(1);
    }

    const code = ch.file_convert.processInput(io, arena, args[1], args[2], null) catch |err| {
        std.debug.print("Fatal error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
