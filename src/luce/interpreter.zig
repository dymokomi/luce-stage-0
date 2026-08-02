//! Re-export barrel for the Luce IR interpreter — the reference engine
//! behind the backend boundary.
//!
//! Implementation lives in interpreter/:
//!   machine.zig  — Machine struct, Frame, CallOutcome, run(),
//!                  execute() dispatch loop, and the instruction
//!                  decoding that calls `libluce_rt` for every
//!                  semantic (docs/CODEGEN.md).
//!   test.zig     — Integration tests exercising the full pipeline.
//!
//! The object heap, ownership, containers, strings, conversions, and
//! arithmetic used to live here too.  They are `../runtime.zig` now,
//! so compiled code and the interpreter share one implementation.

pub const run = @import("interpreter/machine.zig").run;
pub const CallOutcome = @import("interpreter/machine.zig").CallOutcome;
pub const Frame = @import("interpreter/machine.zig").Frame;
pub const Machine = @import("interpreter/machine.zig").Machine;

test {
    _ = @import("interpreter/test.zig");
}
