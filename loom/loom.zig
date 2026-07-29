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
pub const encode = @import("fabric/encode.zig");
pub const store = @import("fabric/store.zig");
pub const fiber_index = @import("evaluation/fiber_index.zig");
pub const spool = @import("evaluation/spool.zig");
pub const state = @import("evaluation/state.zig");
pub const arrangement = @import("organization/arrangement.zig");
pub const effect = @import("effects/effect.zig");
pub const capability = @import("authority/capability.zig");
pub const view_evaluators = @import("view/evaluators.zig");
pub const shell = @import("view/shell.zig");

test {
    _ = volume;
    _ = texel_id;
    _ = value;
    _ = texel;
    _ = encode;
    _ = store;
    _ = fiber_index;
    _ = spool;
    _ = state;
    _ = arrangement;
    _ = effect;
    _ = capability;
    _ = view_evaluators;
    _ = shell;
}
