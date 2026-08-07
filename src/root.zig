//! ch_fixedwidth — Companies House fixed-width multi-product parser library.
//!
//! Products are selected from the 8-byte header identifier (`DDDDSNAP`,
//! `DDDDUPDT`, `DISQUALS`, `LIQNFORM`). Outputs use named `OutputKind` channels
//! (never overloaded across products).
//!
//! - `parse` — product identification, pure record classification and CSV formatting (no I/O)
//! - `stream` — single body parser: chunked input + batched CSV by `OutputKind`
//! - `document` — one-shot wrapper around `stream` (full buffer → named CSVs)
//! - `file_convert` — CLI I/O; sequential path drains `stream` (parallel officers on native)
//! - `version` — semver + git commit + `libraryInfo()` / supported formats catalogue
//! - `c_api` — C ABI / WASM exports for embedding

pub const parse = @import("parse.zig");
pub const version = @import("version.zig");
pub const document = @import("document.zig");
pub const stream = @import("stream.zig");
pub const file_convert = @import("file_convert.zig");
pub const c_api = @import("c_api.zig");

pub const libraryInfo = version.libraryInfo;
pub const supportedFormats = parse.supportedFormats;

test {
    _ = parse;
    _ = version;
    _ = document;
    _ = stream;
    _ = file_convert;
    _ = c_api;
    _ = @import("parse_test.zig");
}
