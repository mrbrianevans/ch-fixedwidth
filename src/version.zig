//! Build-time library identity: semver and git commit.
//!
//! Values are injected from `build.zig` via `@import("build_options")` so every
//! artifact (CLI, static/shared lib, freestanding WASM) reports the same
//! version string and the short SHA of the tree that produced it.

const build_options = @import("build_options");
const parse = @import("parse.zig");

/// Semantic version of this library (e.g. `"0.1.0"`).
pub const version: []const u8 = build_options.version;

/// Short git commit SHA at build time, or `"unknown"` if unavailable.
pub const git_commit: []const u8 = build_options.git_commit;

/// Library identity plus the catalogue of supported bulk file formats.
pub const LibraryInfo = struct {
    /// Semantic version string (no leading `v`).
    version: []const u8,
    /// Short git commit hash when this binary/WASM was built.
    git_commit: []const u8,
    /// Formats with product codes, header magic, and short descriptions.
    formats: []const parse.SupportedFormat,
};

/// Return process-lifetime static library metadata (do not free).
pub fn libraryInfo() LibraryInfo {
    return .{
        .version = version,
        .git_commit = git_commit,
        .formats = parse.supportedFormats(),
    };
}
