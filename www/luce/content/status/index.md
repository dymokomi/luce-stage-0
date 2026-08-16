# Where Luce stands

Updated for release 0.18. This page is the boundary between the language you
can use now and the language being designed. The [Tour](/tour/),
[Guide](/guide/), and [Library](/library/) describe the current toolchain only.

## Available today

### Language

- Static types with inference, checked fixed-width integer arithmetic,
  contextual literals, and explicit representation conversions.
- The current scalar names `bool`; `u8`, `u16`, `u32`, `u64`; `i8`, `i16`,
  `i32`, `i64`; `f16`, `f32`, `f64`; `char`, `str`, and `bytes`.
- Value structs, enums, tagged unions, nominal interfaces, named functions,
  bound methods, and capture-free one-expression lambdas.
- Transparent file-scope type aliases, including chains, forward references,
  constructors, static/member namespaces, visibility, and module re-exports.
- Lists, maps, fixed-shape arrays, builders, optionals, recoverable errors,
  and multiple returns.
- ARC for lists, maps, arrays, builders, files, and tasks. Assignment shares
  reference objects; the last strong release reclaims containers, closes
  files, and joins unfinished tasks on both engines.
- Zeroing `weak` fields and locals for optional lists, maps, arrays, and
  builders. Live reads become owned snapshots; dead targets read `none`; row
  reuse cannot revive a handle; weak storage never crosses a worker.
- Explicit nominal interfaces with multiple methods, multi-value answers,
  directional failure matching, returns, optionals, and heterogeneous
  containers. Interface dispatch is read-only today.
- Isolated workers. Permitted container graphs are copied between runtimes and
  object identity is never shared. Aliases remain aliases inside the worker's
  independent snapshot, and the caller keeps its source graph.
- Modules, visibility, constants, exact-version package consumption, and Luce
  tests.

The old source-level ownership operations do not exist. There is no `give`,
`copy`, or `free` syntax and no borrow annotation. Every successful
differential specification requires zero live objects, resource lifecycle
tests are active, and the serialized-module mutation corpus must reject or run
cleanly without a host-language panic. [Memory Management](/guide/reference/memory/#implementation-evidence)
lists the evidence.

### Toolchain and libraries

`luce build FILE.luc` creates a native executable named after the source by
default. `luce check`, `luce ir`, and `luce test` provide focused development
workflows. `loom` runs a native `.lc` library when that artifact form is useful.
The release also includes the terminal editor and local VS Code/Cursor syntax
extension.

The shipped standard library includes `std.math`, `std.files`, `std.strings`,
`std.lists`, `std.paths`, `std.os`, `std.term`, `std.zip`, `std.json`,
`std.gpu`, and `std.ui`. The maintained `termui` package is a low-level,
deterministic terminal renderer and layout library.

## The language we are building

The north star is one memory sentence:

> Values copy. References share identity. ARC keeps references alive. Weak
> references break cycles. Resources close at the last strong release.
> Workers never share object identity.

### Classes

`class` will be a final ARC reference type with shared identity and ordinary
mutation. Assignment will share the same object; methods will be callable
through a `let` reference; `deinit` will run once at the last strong release.
There is no planned class inheritance.

`class` already parses as a front-end scaffold, but it still lowers with value
behavior. That is not a usable class implementation and the Guide does not
present it as one.

### Interfaces

Interface values will become one owned existential payload plus concrete
metadata and a witness table. A struct payload will be boxed as a value; a
class payload will retain the shared object. That representation enables
mutable dispatch and keeps heterogeneous lists and maps independent of the
frame that created each value.

The first complete model does not include interface inheritance, default
method bodies, associated types, or runtime casting.

### Capturing closures

Weak storage is current for built-in ARC containers and will also accept
classes once class heap lowering exists. Resources, function values, current
interface values, and value types remain strong-only. A weak reference never
dangles, and there is no unsafe `unowned` form.

Capturing closures will share the ordinary function type. Immutable values
capture a snapshot; mutable locals share an environment cell; references are
strongly captured by default. Explicit capture lists request a weak reference
or a named value snapshot when needed. Strong capture remains the normal safe
case—the compiler will not demand weak capture merely because a closure
escapes.

### Explicit type names

The current core type vocabulary is:

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
func(T, ...) -> R
T?
```

The migration is complete. Retired spellings are not aliases; the compiler
rejects each one with its direct replacement so a pre-release language does
not carry two vocabularies.

`none` remains an absence value, not a type. `char` is one Unicode scalar,
not a borrowed view or a grapheme cluster. `str` is immutable UTF-8 and
`bytes` is immutable binary data. There is no generic `f8`; any future 8-bit
float names its format explicitly.

`tree`, `stack`, matrices, and specialized vectors are library types after
generics, not primitive keywords. `map` is the one associative container;
`dict` and `hash` are not aliases. A compiler `vec[T, N]` is justified only by
real SIMD and ABI semantics.

## Ordered work

The implementation order is chosen to avoid rewriting the same compiler and
documentation seams twice:

1. **ARC foundation — complete.** Every feature-related skip and relaxed
   census gate is gone; resources close or join exactly once, bound receivers
   retain their graphs, worker snapshots preserve aliases, derived collections
   retain elements, and malformed modules fail closed.
2. **Transparent type aliases — complete.** `alias Name = Type` works through
   type positions, constructors, members, constants and modules; cycles,
   privacy violations and namespace collisions have exact diagnostics.
3. **Freeze the type and closure contracts — complete.** Decide literal, conversion,
   Unicode, container-type, block-closure, capture-list, and diagnostic rules
   before changing code.
4. **Migrate type names atomically — complete.** Update compiler, runtime, module format,
   standard library, examples, editor grammar, packages, and documentation in
   one pre-release cut; old spellings become direct diagnostics rather than
   long-lived aliases.
5. **Build weak references — complete.** Safe zeroing for built-in ARC objects, lifecycle
   integration, cycle diagnostics, and both-engine agreement.
6. **Complete classes.** Heap lowering, sharing, mutation, identity,
   construction, teardown, weak fields, errors, optionals, containers, and
   workers.
7. **Replace interface storage.** Owned existentials for structs and classes,
   then weak storage, mutable dispatch, and the full negative conformance
   matrix.
8. **Add capturing closures.** ARC environments, shared mutable captures,
   strong/weak/snapshot capture, block bodies, and cycle diagnostics.
9. **Prove the model in userland.** Build a retained UI layer over `std.ui`,
   `std.gpu`, and termui; migrate the editor as the end-to-end proof.
10. **Add generics later.** Monomorphized generic functions and types with
   interface bounds, followed by a small library of justified data structures.
11. **Lock the release.** Full deterministic tests, hardening, site build,
    installer smoke test, benchmark comparison, and a final documentation and
    diagnostics audit.

During a phase, focused language, library, host, backend, editor, or tools
tests are the inner loop. The complete release gate runs at the phase boundary,
with visible progress and heartbeat output. A feature is complete only when
positive programs, common user mistakes, runtime lifetime checks, both
engines, public examples, and performance evidence agree.

## Not part of this roadmap

- class inheritance;
- interface default methods or inheritance;
- garbage collection or user-visible manual retain/release;
- unsafe pointers or unsafe non-owning references;
- shared mutable state between workers;
- operator overloading, reflection, macros, or metaclasses; and
- higher-kinded or variadic generics.

There is no release date implied by this order. The purpose of the list is to
make dependencies and completion criteria visible before implementation
starts.
