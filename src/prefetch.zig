//! Read-ahead `Io.Reader` adapter backed by a producer thread.
//!
//! The producer pulls from a source reader (for example an HTTP body wrapped
//! in a zstd decompressor) into a small ring of blocks while the consumer,
//! via the ordinary `Io.Reader` interface, parses earlier blocks. Download and
//! decompression then overlap with conversion instead of alternating with it
//! on one thread.
//!
//! The source reader is only touched by the producer thread between `start`
//! and `finish`; call `finish` before inspecting the source (or anything it
//! wraps) again.

const std = @import("std");
const Io = std.Io;
const Thread = std.Thread;

pub const default_block_len: usize = 1024 * 1024;
pub const default_block_count: usize = 4;

const BlockState = enum { free, filled };

const Block = struct {
    state: BlockState = .free,
    data: []u8,
    len: usize = 0,
};

pub const Prefetch = struct {
    io: Io,
    gpa: std.mem.Allocator,
    source: *Io.Reader,
    blocks: []Block,

    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Producer: next block to fill. Consumer: block being read.
    fill_index: usize = 0,
    read_index: usize = 0,
    /// Read position inside the consumer's current block.
    read_pos: usize = 0,
    /// Producer reached end of the source (`source_err` null) or failed.
    producer_done: bool = false,
    source_err: ?anyerror = null,
    /// Consumer gave up early; the producer stops at its next hand-off.
    stopped: bool = false,
    thread: ?Thread = null,

    /// The consumer side. Its own buffer is small: data is copied straight
    /// from blocks into callers' buffers.
    interface: Io.Reader,

    /// Allocate `block_count` blocks of `block_len` bytes and start the
    /// producer thread. `reader_buffer` backs `interface` (any size > 0).
    pub fn start(
        self: *Prefetch,
        io: Io,
        gpa: std.mem.Allocator,
        source: *Io.Reader,
        reader_buffer: []u8,
        block_len: usize,
        block_count: usize,
    ) !void {
        const blocks = try gpa.alloc(Block, @max(2, block_count));
        errdefer gpa.free(blocks);
        var made: usize = 0;
        errdefer for (blocks[0..made]) |b| gpa.free(b.data);
        while (made < blocks.len) : (made += 1) {
            blocks[made] = .{ .data = try gpa.alloc(u8, @max(1, block_len)) };
        }
        self.* = .{
            .io = io,
            .gpa = gpa,
            .source = source,
            .blocks = blocks,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = reader_buffer,
                .seek = 0,
                .end = 0,
            },
        };
        self.thread = try Thread.spawn(.{}, producerMain, .{self});
    }

    /// Stop the producer (if still running), join it and free the blocks.
    /// Returns the source's error, if reading it failed.
    pub fn finish(self: *Prefetch) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        self.stopped = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |t| t.join();
        self.thread = null;
        for (self.blocks) |b| self.gpa.free(b.data);
        self.gpa.free(self.blocks);
        self.blocks = &.{};
        return self.source_err;
    }

    fn producerMain(self: *Prefetch) void {
        while (true) {
            const block = &self.blocks[self.fill_index];
            self.mutex.lockUncancelable(self.io);
            while (block.state != .free and !self.stopped) self.cond.waitUncancelable(self.io, &self.mutex);
            const stop = self.stopped;
            self.mutex.unlock(self.io);
            if (stop) break;

            const n = self.source.readSliceShort(block.data) catch |err| {
                self.mutex.lockUncancelable(self.io);
                self.source_err = err;
                self.producer_done = true;
                self.cond.broadcast(self.io);
                self.mutex.unlock(self.io);
                return;
            };

            self.mutex.lockUncancelable(self.io);
            const eof = n < block.data.len;
            if (n > 0) {
                block.len = n;
                block.state = .filled;
                self.fill_index = (self.fill_index + 1) % self.blocks.len;
            }
            if (eof) self.producer_done = true;
            self.cond.broadcast(self.io);
            self.mutex.unlock(self.io);
            if (eof) return;
        }
        self.mutex.lockUncancelable(self.io);
        self.producer_done = true;
        self.cond.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Prefetch = @fieldParentPtr("interface", r);
        const block = &self.blocks[self.read_index];

        self.mutex.lockUncancelable(self.io);
        while (block.state != .filled and !self.producer_done) self.cond.waitUncancelable(self.io, &self.mutex);
        const ready = block.state == .filled;
        const failed = self.source_err != null;
        self.mutex.unlock(self.io);

        if (!ready) return if (failed) error.ReadFailed else error.EndOfStream;

        const avail = block.data[self.read_pos..block.len];
        const n = try w.write(avail[0..limit.minInt(avail.len)]);
        self.read_pos += n;
        if (self.read_pos == block.len) {
            self.mutex.lockUncancelable(self.io);
            block.state = .free;
            block.len = 0;
            self.cond.broadcast(self.io);
            self.mutex.unlock(self.io);
            self.read_pos = 0;
            self.read_index = (self.read_index + 1) % self.blocks.len;
        }
        return n;
    }
};

test "prefetch reader returns the source bytes unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var data: [10_000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 31 +% i / 7);

    // Odd block sizes and counts so reads straddle block boundaries.
    for ([_][2]usize{ .{ 1, 2 }, .{ 7, 3 }, .{ 100, 2 }, .{ 4096, 4 }, .{ 20_000, 2 } }) |cfg| {
        var source = Io.Reader.fixed(&data);
        var pf: Prefetch = undefined;
        var buf: [64]u8 = undefined;
        try pf.start(io, gpa, &source, &buf, cfg[0], cfg[1]);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        // Mix of line-oriented and bulk reads, as the converter does.
        while (true) {
            const line = pf.interface.takeDelimiterInclusive(200) catch |err| switch (err) {
                error.EndOfStream => break,
                error.StreamTooLong => {
                    const chunk = try pf.interface.peekGreedy(1);
                    try out.appendSlice(gpa, chunk);
                    pf.interface.toss(chunk.len);
                    continue;
                },
                else => |e| return e,
            };
            try out.appendSlice(gpa, line);
        }
        try out.appendSlice(gpa, pf.interface.buffered());
        try std.testing.expectEqual(@as(?anyerror, null), pf.finish());
        try std.testing.expectEqualSlices(u8, &data, out.items);
    }
}

test "prefetch reader reports a source failure as ReadFailed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var failing: Io.Reader = .failing;
    var pf: Prefetch = undefined;
    var buf: [64]u8 = undefined;
    try pf.start(io, gpa, &failing, &buf, 16, 2);
    try std.testing.expectError(error.ReadFailed, pf.interface.peekGreedy(1));
    try std.testing.expectEqual(@as(?anyerror, error.ReadFailed), pf.finish());
}

test "prefetch reader can be finished early without draining the source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const data = [_]u8{'x'} ** 50_000;
    var source = Io.Reader.fixed(&data);
    var pf: Prefetch = undefined;
    var buf: [64]u8 = undefined;
    try pf.start(io, gpa, &source, &buf, 100, 2);
    _ = try pf.interface.peekGreedy(1);
    try std.testing.expectEqual(@as(?anyerror, null), pf.finish());
}
