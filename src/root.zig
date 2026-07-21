//! Companies House fixed-width snapshot parser library.
//!
//! - `parse` — pure record classification and CSV formatting (no I/O)
//! - `snapshot` — in-memory full-file conversion to CSV
//! - `stream` — chunked input + batched CSV output (for large files / WASM)
//! - `file_convert` — streaming filesystem CLI path (multithreaded on native)
//! - `c_api` — C ABI / WASM exports for embedding

pub const parse = @import("parse.zig");
pub const snapshot = @import("snapshot.zig");
pub const stream = @import("stream.zig");
pub const file_convert = @import("file_convert.zig");
pub const c_api = @import("c_api.zig");

test {
    _ = parse;
    _ = snapshot;
    _ = stream;
    _ = file_convert;
    _ = c_api;
    _ = @import("parse_test.zig");
}
