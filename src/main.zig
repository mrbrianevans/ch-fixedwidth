//! CLI entry point: file paths in, CSV files out.
//! Parsing logic lives in the `ch_fixedwidth` library.

const std = @import("std");
const ch = @import("ch_fixedwidth");

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

    const code = ch.file_convert.processCompanyAppointmentsData(io, arena, args[1], args[2]) catch |err| {
        std.debug.print("Fatal error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.process.exit(code);
}
