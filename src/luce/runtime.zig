//! `libluce_rt` — the Luce runtime library, and re-export barrel.
//!
//! Luce's semantics below the instruction level live here: the object
//! heap and scope ownership (docs/OWNERSHIP.md), lists, maps, arrays,
//! `Builder`, string storage and the small String primitive set,
//! `str`/`parse_int`/`parse_float`/`chr`/`ord`, checked arithmetic, and
//! the trap channel they all report through.
//!
//! It exists as a library rather than a struct inside the interpreter
//! because a compiled `.lc` is a shared library and a standalone
//! executable has no interpreter process to call into: a compiled
//! program still needs something to call when it appends to a list
//! (docs/CODEGEN.md).  There is exactly one implementation of every
//! semantic, and both the interpreter and generated code reach it —
//! the interpreter through the Zig surface below, generated code
//! through the C surface in `exports.zig`.
//!
//! Flat pieces beside this file:
//!
//!   value.zig      — the 24-byte C-layout `Value` every operation
//!                    takes, plus the tagged-union `view()` Zig callers
//!                    switch on.
//!   heap.zig       — `Runtime` (the two allocators a run draws on,
//!                    the object table, serials, the trap channel),
//!                    objects, and the ownership walks S1–S43 are
//!                    written in terms of.
//!   containers.zig — List, Map, Array, Builder, and the `free`/`give`/
//!                    `copy` verbs.
//!   text.zig       — String storage and the pure conversions.
//!   operators.zig  — checked arithmetic, comparison, conversions, and
//!                    the math builtins.
//!   trace.zig      — the call trace a trapped compiled program builds
//!                    as it unwinds, and the tables that name it.
//!   exports.zig    — the `luce_rt_*` C entry points.
//!   test.zig       — the library proved on its own, before any engine.

pub const Error = @import("runtime/heap.zig").Error;
pub const Trap = @import("runtime/heap.zig").Trap;
pub const Runtime = @import("runtime/heap.zig").Runtime;
pub const Object = @import("runtime/heap.zig").Object;
pub const MapEntry = @import("runtime/heap.zig").MapEntry;
pub const Map = @import("runtime/heap.zig").Map;
pub const Memory = @import("runtime/heap.zig").Memory;
pub const Owner = @import("runtime/heap.zig").Owner;
pub const OwnedBy = @import("runtime/heap.zig").OwnedBy;
pub const flattenIndex = @import("runtime/heap.zig").flattenIndex;
pub const max_array_elements = @import("runtime/heap.zig").max_array_elements;

pub const Tag = @import("runtime/value.zig").Tag;
pub const Value = @import("runtime/value.zig").Value;
pub const View = @import("runtime/value.zig").View;
pub const null_index = @import("runtime/value.zig").null_index;
pub const keyEquals = @import("runtime/value.zig").keyEquals;

pub const containers = @import("runtime/containers.zig");
pub const operators = @import("runtime/operators.zig");
pub const text = @import("runtime/text.zig");
pub const trace = @import("runtime/trace.zig");

pub const Status = @import("runtime/exports.zig").Status;

// Force the C surface to be analyzed even when nothing in Zig calls
// it.  Without this the `luce_rt_*` symbols exist only in test builds
// and `libluce_rt.a` links empty — which shows up as an undefined
// symbol in a compiled artifact rather than as a compile error here.
comptime {
    _ = @import("runtime/exports.zig");
}

test {
    _ = @import("runtime/value.zig");
    _ = @import("runtime/heap.zig");
    _ = @import("runtime/containers.zig");
    _ = @import("runtime/operators.zig");
    _ = @import("runtime/text.zig");
    _ = @import("runtime/trace.zig");
    _ = @import("runtime/exports.zig");
    _ = @import("runtime/test.zig");
}
