//! Port of foot-features.c: the "foot --version" feature line.
//!
//! The C original is a chain of #ifdefs over the compile-time feature set;
//! here the same set arrives as `build_options` (mirrored by meson) so the
//! string is assembled at comptime instead.

const build_options = @import("build_options");

fn feature(enabled: bool, name: []const u8) []const u8 {
    return if (enabled) " +" ++ name else " -" ++ name;
}

const features =
    "version: " ++ build_options.foot_version ++
    feature(build_options.pgo, "pgo") ++
    feature(build_options.ime, "ime") ++
    feature(build_options.grapheme_clustering, "graphemes") ++
    feature(build_options.toplevel_tag, "toplevel-tag") ++
    feature(build_options.blur, "blur") ++
    feature(build_options.assertions, "assertions");

/// foot-features.h declares this as `extern const char version_and_features[]`,
/// so the symbol has to be the array itself, NUL-terminated, not a pointer.
export const version_and_features: [features.len:0]u8 = blk: {
    var arr: [features.len:0]u8 = undefined;
    @memcpy(arr[0..features.len], features);
    arr[features.len] = 0;
    break :blk arr;
};
