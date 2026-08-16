//! Stage 1 — loading.  A module name in, registered source text out.
//!
//! Consumes: the root's bytes, and the name of every module the
//! program imports.
//! Produces: a `Sources` registry — one entry per file, holding its
//! identity, its text, and its line index — plus the positions
//! everything downstream points at (`Span`, `Place`).
//!
//! **One place answers "what are the bytes of module X".**  `load.zig`
//! is that place: the standard library and the host's filesystem
//! resolve through the same call, land in the same registry, and fail
//! with the same diagnostics.  The compiler still never opens a file
//! itself — `Loader` is the seam a host fills — but the *policy*
//! (std first and reserved, then the host; what a file may contain;
//! how a failure reads) is here rather than spread across the driver.
//!
//! Every byte that becomes source passes `encoding.prepare`, so later
//! stages may assume valid UTF-8, LF line endings, no BOM, no NUL, and
//! a size that fits comfortably in the `u32` arithmetic debug info
//! uses.  A `Span` therefore indexes the *prepared* text, not the file
//! on disk; the registry is the authority that turns one into a line
//! and a column.
//!
//! Flat pieces beside this file:
//!
//!   positions.zig — `Span`, `Place`, and `place()`: byte offsets and
//!                   the line/column derived from them.
//!   encoding.zig  — input hygiene: BOM, line endings, UTF-8, NUL,
//!                   the wrong-encoding sniff, and the size limit.
//!   sources.zig   — the registry: `FileId` -> name, path, text, an
//!                   indexed `place`, and the text of any line.
//!   load.zig      — resolution: the `Loader` seam, the embedded
//!                   standard library, and the diagnostics for every
//!                   way a load can fail.
//!
//! ## Where a span becomes something anyone can use
//!
//! A `Span` deliberately does *not* carry a `FileId`.  It is a byte
//! range in one file's prepared text, and the file is always known
//! where the diagnostic is made — `Diagnostics.scope` stamps it on.
//! Widening the span would cost every construction site in stages 2
//! and 3 and buy nothing, because nothing outside the compiler wants a
//! span: it wants a place it can print or jump to.  That is
//! `diagnostics.Rendered` — path, line, column, end line, end column,
//! the text of the line, the code, the message — the shape Python
//! gives `SyntaxError`, resolved once against this registry and
//! self-contained from then on.
//!
//! ## Status: locked
//!
//! Every way a load can go wrong is decided, and the decisions that
//! were *not* to act are written down where they were made:
//!
//!   * `encoding.zig` — UTF-16/UTF-32 byte-order marks are named;
//!     BOM-less UTF-16 is declined (guessing renames a real problem)
//!     and falls out as `luce.source.binary` at its first NUL.
//!   * `load.zig` — a `luce.source.*` message carries its own
//!     `path:line:column`, since the file it describes could not be
//!     registered for the renderer to place it against.  Declined: a
//!     note when a std name shadows a file beside the program — it was
//!     built, and in this repository it fired twice with two false
//!     positives; the reasoning and the right home for it are in that
//!     file's header.
//!   * `compile/modules.zig` — import cycles are allowed, on purpose;
//!     circularity is refused at the granularity where it means
//!     something (a constant that depends on itself, a struct that
//!     contains itself).
//!   * `src/apps/files.zig` — the host half: exact-case matching, an
//!     import must be a regular file, and the root may be a stream
//!     (`-`, a pipe, a process substitution).
//!
//! `prepare` and the loader are both property-fuzzed: they are the
//! first thing untrusted bytes touch, and the invariant every later
//! stage rests on is that there is no third answer.

const positions = @import("source/positions.zig");
const encoding = @import("source/encoding.zig");
const sources = @import("source/sources.zig");
const load = @import("source/load.zig");

// Positions.
pub const Span = positions.Span;
pub const Place = positions.Place;
pub const place = positions.place;

// Input hygiene.
pub const max_bytes = encoding.max_bytes;
pub const Problem = encoding.Problem;
pub const prepare = encoding.prepare;

// The registry.
pub const FileId = sources.FileId;
pub const root_file = sources.root_file;
pub const Kind = sources.Kind;
pub const File = sources.File;
pub const Sources = sources.Sources;

// Resolution.
pub const Loader = load.Loader;
pub const Found = load.Found;
pub const Origin = load.Origin;
pub const openRoot = load.openRoot;
pub const openImport = load.openImport;
pub const standard_namespace = load.standard_namespace;
pub const standard_list = load.standard_list;
pub const isStandard = load.isStandard;

test {
    _ = positions;
    _ = encoding;
    _ = sources;
    _ = load;
}
