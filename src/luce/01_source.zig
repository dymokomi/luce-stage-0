//! Stage 1 — loading.  Source text in, source text out.
//!
//! Consumes: a module name or a path the host resolves.
//! Produces: the source bytes plus the positions everything downstream
//! points at (`Span`, `Place`).
//!
//! **What is not done here yet.**  There is no loader in this folder.
//! The compiler is given a byte slice and never opens a file itself:
//! `compile.zig`'s `Loader` is the seam a host fills, `src/apps/
//! files.zig` is the one implementation of it, and the standard
//! library resolves ahead of both from `@embedFile` tables in
//! `compile/modules.zig`.  Moving that resolution here — one place
//! that answers "what are the bytes of module X", std and disk alike —
//! is the work this stage still owes.  Today it holds positions only.
//!
//! Flat pieces beside this file:
//!
//!   positions.zig — `Span`, `Place`, and `place()`: byte offsets and
//!                   the line/column derived from them.

pub const Span = @import("01_source/positions.zig").Span;
pub const Place = @import("01_source/positions.zig").Place;
pub const place = @import("01_source/positions.zig").place;

test {
    _ = @import("01_source/positions.zig");
}
