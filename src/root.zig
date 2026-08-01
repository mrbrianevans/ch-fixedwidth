//! ch_fixedwidth — Companies House fixed-width multi-product parser library.
//!
//! Products are selected from the 8-byte header identifier (`DDDDSNAP`,
//! `DDDDUPDT`, `DISQUALS`, `LIQNFORM`). Outputs use named `OutputKind` channels
//! (never overloaded across products).
//!
//! - `parse` — product identification, pure record classification and CSV formatting (no I/O)
//! - `document` — in-memory full-file conversion to named CSVs
//! - `stream` — chunked input + batched CSV output by `OutputKind`
//! - `file_convert` — streaming filesystem CLI path (multithreaded on native for officers)
//! - `c_api` — C ABI / WASM exports for embedding

pub const parse = @import("parse.zig");
pub const document = @import("document.zig");
pub const stream = @import("stream.zig");
pub const file_convert = @import("file_convert.zig");
pub const c_api = @import("c_api.zig");

test {
    _ = parse;
    _ = document;
    _ = stream;
    _ = file_convert;
    _ = c_api;
    _ = @import("parse_test.zig");
}
