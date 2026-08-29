# Where Luce stands

Updated for release 0.23. This page separates the language implemented today
from work that is still design. The [Tour](/tour/), [Guide](/guide/), and
[Library](/library/) describe current behavior only.

## Available today

### Language

- Explicit scalar types: `bool`; `u8`, `u16`, `u32`, `u64`; `i8`, `i16`,
  `i32`, `i64`; `f16`, `f32`, `f64`; `char`, `str`, and `bytes`.
  Arithmetic is checked at its concrete width and conversions are explicit.
- Transparent `alias Name = Type` declarations, including chains, forward
  references, visibility, constructors, member namespaces, and re-exports.
- Structures, enumerations, tagged unions, and final ARC classes. Classes
  share mutable identity, compare identity with `is`, support definite custom
  initialization and weak edges, and run `deinit` once at the last strong
  release.
- Named functions, one-expression lambdas, bound methods, and ARC block
  closures. Closures retain immutable captures, share mutable cells, and
  support explicit snapshot and zeroing weak captures.
- Nominal interfaces with multiple methods, multi-value answers, directional
  failure matching, heterogeneous collections, and mutable class dispatch.
  `mutating` requirements also support writing value-structure witnesses when
  the call has a mutable bare local receiver.
- Lists, maps, fixed-shape arrays, builders, optionals, recoverable errors,
  multiple returns, constants, modules, access control, packages, and tests.
- ARC across reference objects, resources, class instances, bound methods,
  interface dispatch values, and closure environments. Files close and
  unfinished tasks join at the last strong release.
- Zeroing `weak` locals, fields, and closure captures for weak-capable ARC
  objects. A live read becomes an owned optional snapshot; a dead target reads
  `none`; generation checks prevent stale handles from reviving.
- Isolated workers. Permitted values and container graphs are copied into a
  private runtime while preserving aliases inside the snapshot. Object
  identity is never shared between workers.
- Bounded `channel[T]` conduits between workers — the one reference a worker
  boundary admits. Send parks a deep copy and receive rebuilds it, so no
  identity crosses; blocking, try, and timed forms; close is idempotent and
  drains before it refuses. Element sendability is checked where the channel
  is written.
- Selective imports: `from geo import Point, area` binds named public members
  bare, with a per-member `as` rename.
- `match` over integer, character, string, and boolean values with literal,
  multi-value, range, and constant arms, beside the enumeration and union
  dispatch it always had.
- Construction is an ordinary call for every kind of value — `Point(x = 1)`,
  `Counter()`, `list[i64]()`. There is no `new` keyword.

There is no source-level retain, release, give, copy, free, move, clone, or
borrow operation. Every successful differential language specification must
finish with zero live runtime objects, and malformed serialized modules must
trap or be rejected without a host-language panic.

### Toolchain and libraries

`luce build FILE.luc` creates a native executable named after the source by
default; a bare `luce build` under a project builds the manifest's `main:` or
runs the project's compiled `build.luc` plan. `luce install` fills the package
store from the manifest's own `url:` + `sha256:` rows. `luce check`,
`luce ir`, `luce query diagnostics`, and `luce test` provide focused
development workflows. `loom` loads a compiled `.lc` library when that
artifact form is useful. The release also contains the terminal editor, the
`luce-lsp` language server, and a local VS Code or Cursor extension. One checked installer publishes that toolchain for macOS 15
or newer on ARM64 and glibc Linux 2.28+ on ARM64 and x86-64; the compiler
contains its pinned LLVM and uses the host `cc` only for the final native link.
`luce --build-info` and `loom --build-info` report the archive's immutable
source revision, target, optimization mode, module format, and host ABI.
Each archive also carries a `BUILD-MANIFEST` with its source timestamp,
toolchain and bundled-package versions, and reproducible archive format. The
published SHA-256 file names the exact bytes the installer verifies.

The embedded standard library includes `std.io`, `std.math`, `std.files`,
`std.strings`, `std.lists`, `std.paths`, `std.os`, `std.term`, `std.zip`,
`std.json`, `std.gpu`, `std.ui`, `std.network`, `std.http`, and `std.build`.
The maintained TermUI 0.5 package provides
declarative terminal applications from panels, stacks, labels, rows, styles,
events, and one library-owned application loop. The shipped editor uses that
public surface.

The current serialized-module format is 64 and the host ABI is 30. Loaders
refuse incompatible artifacts rather than guessing.

## The memory model

The language is organized around one sentence:

> Values copy. References share identity. ARC keeps references alive. Weak
> references break cycles. Resources close at the last strong release.
> Workers never share object identity.

| Kind | Examples | Assignment and passing |
|---|---|---|
| Value | numbers, `bool`, `char`, `str`, `bytes`, structs, enums, unions | copy the value |
| Reference | classes, lists, maps, arrays, builders, closure environments | retain and share one identity |
| Resource reference | files, sockets, processes, tasks, channels, windows, GPU surfaces | retain and share; clean up at zero |

An interface owns one concrete payload and a static witness identity: a
structure conformance copies its value and a class conformance retains shared
identity. A `mutating` value call writes the updated payload back to a mutable
bare local. [Memory and ARC](/guide/memory/) teaches the model; [Memory
Management](/guide/reference/memory/) states its exact rules.

## Explicit type names

The completed core vocabulary is:

```text
bool

u8  u16  u32  u64
i8  i16  i32  i64
f16 f32  f64

char
str
bytes

list[T]
map[K, V]
array[T, _, ...]
channel[T]
func(T, ...) -> R
T?
```

These are the only built-in type names. A second spelling for any of them does
not exist.
`none` is an absence value, not a type. `char` is one Unicode scalar, `str` is
immutable UTF-8, and `bytes` is immutable binary data. There is no generic
`f8`; a future 8-bit floating representation must name its format.

Trees, stacks, matrices, and specialized vectors belong in libraries after
generics rather than in the primitive vocabulary. `map` is the associative
container; `dict` and `hash` are not aliases.

## Post-1.0 language work

### Interfaces {#interfaces}

The first interface design is complete. A conformance is nominal and explicit;
all required instance methods, parameter and result shapes, and fallibility
direction are checked before conversion. `mutating` requirements permit
writing value-structure witnesses, while non-mutating calls cannot write a
value receiver. Multiple methods, multiple results, class identity, copied
struct payloads, closure captures, and heterogeneous list/map/array elements
are covered by the executable specifications.

The implementation uses one owned existential payload and a static witness
identity. It deliberately excludes interface inheritance, default methods,
associated types, generic bounds, and runtime casts.

### User-defined generics and library data structures

User-defined generics remain design work and are deliberately outside the
first release. The intended post-1.0 direction is monomorphized generic
functions and types with interface bounds. Trees, stacks, matrices, and other
data structures can then be ordinary library types rather than compiler
keywords.

Generics are not required for the current classes, closures, interfaces,
containers, standard library, or applications.

## Deliberate non-goals

- class inheritance, `override`, and `super`;
- interface default methods or interface inheritance;
- garbage collection or user-visible manual retain and release;
- unsafe pointers or unsafe non-owning references;
- shared mutable state between workers;
- operator overloading, reflection, macros, or metaclasses; and
- higher-kinded or variadic generics.

## Known bugs

There are no confirmed bugs in the current tree. The internal bug ledger stays
empty until behavior is reproducibly wrong; plans and feature requests are
tracked separately.
