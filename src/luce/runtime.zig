//! `libluce_rt` — the Luce runtime library, and re-export barrel.
//!
//! Luce's semantics below the instruction level live here: the object heap
//! and ARC (docs/MEMORY.md), containers, `str` and `bytes` storage, scalar
//! conversions, checked arithmetic, and the trap channel they all report
//! through.
//!
//! It exists as a library rather than a struct inside an engine
//! because a `.lc` is a shared library and a standalone executable has
//! no compiler process to call into: a running program still needs
//! something to call when it appends to a list (docs/CODEGEN.md).
//! There is exactly one implementation of every semantic, and both
//! generated code and the test suite's oracle reach it — generated
//! code through the C surface in `exports.zig`, the oracle through the
//! Zig surface below.
//!
//! Flat pieces beside this file:
//!
//!   value.zig      — the 24-byte C-layout `Value` every operation
//!                    takes, plus the tagged-union `view()` Zig callers
//!                    switch on.
//!   heap.zig       — `Runtime` (the two allocators a run draws on,
//!                    the object table, generations, weak handles, ARC, and
//!                    the trap channel) and object storage.
//!   containers.zig — list, map, array, and builder operations.
//!   text.zig       — `str`/`bytes` storage and pure conversions.
//!   operators.zig  — checked arithmetic, comparison, conversions, and
//!                    the math builtins.
//!   trace.zig      — the call trace a trapped compiled program builds
//!                    as it unwinds, and the tables that name it.
//!   exports.zig    — the `luce_rt_*` C entry points.
//!   test.zig       — the library proved on its own, before any engine.
//!
//! **It stands alone.**  Nothing under `runtime/` imports a compiler
//! stage: the four enums both sides have to spell the same way — trap
//! codes, error codes, binary operators, and which file service failed
//! — are `support/vocabulary.zig`'s, below both, and `mir.zig`
//! re-exports them so the compiler still says `mir.TrapCode`.  A
//! library that is linked into every artifact must not have a source
//! dependency on the front end, or a reader cannot tell from the import
//! graph where the library ends.

pub const Error = @import("runtime/heap.zig").Error;
pub const Trap = @import("runtime/heap.zig").Trap;
pub const Raised = @import("runtime/heap.zig").Raised;
pub const Runtime = @import("runtime/heap.zig").Runtime;
pub const Finalizers = @import("runtime/heap.zig").Finalizers;
pub const FinalizerRunFn = @import("runtime/heap.zig").FinalizerRunFn;
pub const Object = @import("runtime/heap.zig").Object;
pub const MapEntry = @import("runtime/heap.zig").MapEntry;
pub const Map = @import("runtime/heap.zig").Map;
pub const Memory = @import("runtime/heap.zig").Memory;
pub const flattenIndex = @import("runtime/heap.zig").flattenIndex;
/// The generation at which an object table row is retired instead of
/// reused, so that generations never wrap (docs/MEMORY.md).
pub const retired = @import("runtime/heap.zig").retired;
/// Where an object row's fields sit, for the one reader that cannot
/// call a function to ask: generated code walking an array inline.
pub const layout = @import("runtime/heap.zig").layout;
/// The most elements a container of one element kind may hold — the
/// per-width ceilings docs/VECTOR.md's proof needs, in place of the
/// flat element cap that used to stand here (docs/BYTES.md).
pub const maxElements = @import("runtime/heap.zig").maxElements;

/// File handles: the host's byte channel, the handle's own operations,
/// and the whole-file text conveniences defined over them
/// (docs/BYTES.md).  The oracle reaches these directly; a compiled
/// artifact reaches the same bodies through `exports.zig`.
pub const files = @import("runtime/files.zig");
pub const sockets = @import("runtime/sockets.zig");

/// Window and GPU handles: the backend-neutral host channel behind
/// `std.ui` and `std.gpu`.
pub const graphics = @import("runtime/graphics.zig");

/// Workers: the host's thread channel, this engine's nursery, the
/// argument and result transfers, the join, and the effect lock
/// (docs/THREADS.md).  Reached the same two ways `files` is.
pub const workers = @import("runtime/workers.zig");
pub const channels = @import("runtime/channels.zig");
pub const ffi = @import("runtime/ffi.zig");

pub const Tag = @import("runtime/value.zig").Tag;
pub const Value = @import("runtime/value.zig").Value;
pub const View = @import("runtime/value.zig").View;
pub const Handle = @import("runtime/value.zig").Handle;
pub const null_index = @import("runtime/value.zig").null_index;
/// Where a handle's generation sits in `Value.bits`, for the reader
/// that takes the two halves apart itself: generated code.
pub const generation_shift = @import("runtime/value.zig").generation_shift;
/// Where short text sits inside a `Value`, how much of it fits, and the
/// `inline_length` that says it is somewhere else instead.  Generated
/// code reads all three (`codegen/lower.zig`).
pub const inline_at = @import("runtime/value.zig").inline_at;
pub const inline_capacity = @import("runtime/value.zig").inline_capacity;
pub const text_outside = @import("runtime/value.zig").text_outside;
/// What a `str` knows about its own encoding.  Generated code carries
/// the same answer in the register a str travels in and writes it into
/// every box it builds (`codegen/lower.zig`).
pub const Encoding = @import("runtime/value.zig").Encoding;
pub const encodingOf = @import("runtime/value.zig").encodingOf;
pub const keyEquals = @import("runtime/value.zig").keyEquals;

pub const containers = @import("runtime/containers.zig");
pub const operators = @import("runtime/operators.zig");
pub const text = @import("runtime/text.zig");
pub const trace = @import("runtime/trace.zig");

/// The C surface itself.  Published so `codegen/runtime_effects.zig`
/// can read the real signatures back and hold its own description of
/// them to account: a C object file carries no types, so nothing but a
/// test comparing the two can catch a `declare` of the wrong shape.
///
pub const exports = @import("runtime/exports.zig");

pub const Status = exports.Status;

// Force the C surface to be analyzed even when nothing in Zig calls
// it.  Naming the file above is not enough — a namespace's `pub`
// declarations are analyzed when something reaches them, and the
// linker is not something Zig can see reaching one.  Without this the
// `luce_rt_*` symbols exist only in test builds and `libluce_rt.a`
// links empty, which shows up as an undefined symbol in a compiled
// artifact rather than as a compile error here.
comptime {
    _ = exports;
}

test {
    _ = @import("runtime/value.zig");
    _ = @import("runtime/heap.zig");
    _ = @import("runtime/containers.zig");
    _ = @import("runtime/operators.zig");
    _ = @import("runtime/text.zig");
    _ = @import("runtime/files.zig");
    _ = @import("runtime/graphics.zig");
    _ = @import("runtime/workers.zig");
    _ = @import("runtime/trace.zig");
    _ = @import("runtime/exports.zig");
    _ = @import("runtime/test.zig");
}
