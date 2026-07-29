//! Loom — the trusted local engine of LuciaOS.
//!
//! This module is the Zig implementation of the engine described in
//! docs/LOOM.md: a persistent Fabric of identity-bearing Texels connected
//! by typed Fibers, with demand-driven evaluation and push invalidation.
//! The on-disk image format is shared with the reference C++ tree; the
//! golden fixture test proves both implementations read the same bytes.

pub const volume = @import("storage/volume.zig");
pub const texel_id = @import("fabric/texel_id.zig");
pub const value = @import("fabric/value.zig");
pub const texel = @import("fabric/texel.zig");

test {
    _ = volume;
    _ = texel_id;
    _ = value;
    _ = texel;
}
