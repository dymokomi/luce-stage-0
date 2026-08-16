# Roadmap — finish ARC, then build the intended language

This is a plan, not the current language reference. The current compiler is
described by [LANGUAGE.md](LANGUAGE.md), [MEMORY.md](MEMORY.md), and the other
documents under **Current reference** in [README.md](README.md). Syntax shown
here is fenced as `text` until the compiler accepts it.

The destination is deliberately small:

> Luce values copy. Luce references share identity. ARC keeps references
> alive. Weak references break cycles. Resources close at the last strong
> release. Workers never share object identity.

That rule must be enough to explain a list alias, a class model, a callback,
an interface value, a file, and a task. If a feature needs a second lifetime
language, the design is not finished.

## Where the repository is now

The ARC pivot is partially implemented on both execution paths:

- the old source-level `give`, `copy`, and `free` language is gone;
- runtime objects carry a reference count, MIR has `retain` and `release`, and
  the interpreter and LLVM path implement those instructions;
- common local, assignment, parameter, return, aggregate, optional, error, and
  container paths now share reference identity and pass simple zero-census
  differential specs; and
- the compiler and oracle still use one runtime implementation.

It is not yet honest to call that full ARC:

- `bytes_spec.zig` and `zip_spec.zig` skip four file lifecycle tests because a
  file opened in a function is not reliably closed at the function's last
  release;
- the synthesized test entry and adventure spec relax their zero-census
  assertions around remaining container reclamation gaps;
- the damaged-module byte-mutation hardening test is skipped around two
  decoder/verifier panic paths.

Those are the first milestone, not cleanup to postpone. After them:

- `class` is a front-end scaffold. It parses and carries a reference-kind bit,
  but still lowers with value-struct behavior.
- Interfaces work for explicit struct conformance, multiple methods,
  multi-value answers, directional failure effects, return values, optionals,
  and heterogeneous containers. Dispatch is intentionally read-only today,
  and the representation is not yet the final owned existential model.
- Lambdas are one expression and cannot capture a local.
- `weak` references do not exist.
- The public scalar spellings are still `byte`, `short`, `int`, `long`,
  `half`, `float`, `double`, and `string`.
- [MISSING.md](MISSING.md) contains a damaged-module validation bug that must
  be fixed before the serialized format changes again.

That inventory is the baseline. A plan item is not allowed to migrate into a
current reference until its acceptance program and negative matrix pass on
both engines. A skipped feature or hardening test counts as unfinished work,
not as a green result.

## The target language

### Values, references, and resources

The type kind is observable and simple:

| Kind | Examples | Assignment and passing | Lifetime |
|---|---|---|---|
| Value | numbers, `bool`, `char`, `str`, `bytes`, `struct`, `enum`, `union` | copy the value | inline or owned by the containing value |
| Reference | `class`, `list`, `map`, `array`, closure environments, interface existentials | share one identity | ARC; free at the last strong reference |
| Resource reference | files, tasks, windows, GPU surfaces | share one identity | ARC plus deterministic close/join/release at zero |

A value may contain references; copying it copies its value fields and retains
its reference fields. A reference may contain values and other references.
Recursive container graphs can already form strong cycles; classes and
capturing closures make them common, so `weak` lands before either feature is
considered complete.

Workers keep the existing isolation rule: permitted value/container graphs
are rebuilt in the receiving runtime, while object identity never crosses.
Resources, classes, weak references, and capturing closure environments are
not sendable in this milestone. There are no locks, atomics, shared heaps, or
thread identities.

### Classes

A `class` is a final ARC reference type with identity and ordinary mutation:

```text
class Counter:
    count: i64

    func increment():
        self.count += 1

func main():
    let first = Counter(count = 0)
    let second = first
    second.increment()
    print(str(first.count))       # 1
```

The first complete class release includes:

- heap allocation and reference lowering from the declaration's kind;
- sharing on assignment, parameters, returns, fields, optionals, collections,
  interfaces, and function environments;
- mutation through a `let` binding, because the binding is stable while the
  object is mutable;
- memberwise construction, including defaults and visibility already shared
  with structs;
- reference identity with Python-familiar `is`; `==` remains value equality
  and is not synthesized recursively for classes;
- an optional `deinit` that runs exactly once at the last strong release,
  while fields are still alive, after which fields release;
- a ban on resurrection from `deinit`; and
- deterministic behavior on success, recoverable error, and normal worker
  cleanup.

Explicit `init` bodies can follow after memberwise construction is solid. They
must use the same call syntax, establish every field before `self` escapes,
and not introduce Swift's two-phase initializer hierarchy.

Classes have no inheritance, subclassing, `override`, or `super`. Reuse comes
from composition and interfaces. Interface default methods are also outside
this milestone: they are not needed to make polymorphism whole, and they would
mix implementation inheritance into the first existential design.

### Interfaces as owned existentials

The target representation is one existential value, not one copied receiver
per method:

```text
{ payload, concrete metadata, witness table }
```

- A struct conformer is copied into existential storage.
- A class conformer is retained as the existential payload.
- The witness table is static and has one slot per required method.
- Each element in a heterogeneous `list[Interface]` or `map[K, Interface]`
  carries its own payload and witness identity.
- Dispatch may call a mutating concrete method. A value payload mutates the
  existential's boxed copy; a class payload mutates the shared object.
- Existing multiple-method, multi-value-return, named-argument, and fallible
  contract rules remain.
- A non-fallible witness may satisfy a fallible requirement; the reverse is
  rejected.

Interfaces remain nominal and explicit. The first complete model has no
interface inheritance, default implementations, associated types, or runtime
casts. Generic constraints arrive later and reuse the same conformance table.

### Weak references

`weak` applies to ordinary ARC object references: classes, lists, maps,
arrays, builders, and reference-backed interface values. Limiting it to
classes would leave the recursive struct/container cycles that Luce can
already express with no way to break a back-edge.

```text
class Node:
    weak parent: Node?
    children: list[Node]
```

A weak reference does not increment the strong count, always reads as `T?`,
and becomes `none` before the target's storage can be reused. It never dangles.
The runtime representation and zeroing behavior must agree on the compiled and
oracle paths. Resource references and function values are not weak in the
first model: resource disappearance should not become an implicit API, and a
closure cycle is broken by weakly capturing the object on its back-edge.
There is no unsafe `unowned` form.

The debug leak census must report surviving strong cycles with enough type and
allocation context to diagnose them. ARC does not pretend to collect cycles.

### Capturing closures

Plain functions and closures share one function type. Whether a closure
escapes is inferred; it does not color the function type.

- Immutable value bindings capture a value snapshot.
- Mutable local bindings are promoted into one shared environment cell, so
  the closure and surrounding scope observe the same variable.
- Reference values are strongly captured by default. Strong capture is the
  ordinary safe case, even when a closure escapes.
- A capture list requests weak or snapshot behavior where it matters:

  ```text
  [weak model] () -> model?.refresh()
  [name = current_name] () -> print(name)
  ```

- The compiler diagnoses an obvious stored self-cycle and points at the weak
  capture that breaks it; it does not require weak capture for every escaping
  reference.
- Closure environments are ARC objects and release every captured reference
  exactly once.
- A closure environment cannot cross a worker boundary in this milestone.

The current single-expression lambda is not enough for UI callbacks. Capturing
closures therefore land with a block form, using the same statements and
return checking as a function body. A trailing-closure call form is optional
ergonomics after the core representation is proven, not a prerequisite for
closure correctness.

### The explicit type vocabulary

The target core vocabulary is:

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
array[T, N, ...]
func(T, ...) -> R
T?
```

User-declared `struct`, `class`, `enum`, `union`, and `interface` types remain
TitleCase. Files, tasks, windows, and GPU surfaces are opaque library/runtime
types rather than a reason to add more scalar keywords.

The migration is intentionally atomic:

| Current | Target |
|---|---|
| `byte` | `u8` |
| `short` | `i16` |
| `int` | `i32` |
| `long` | `i64` |
| `half` | `f16` |
| `float` | `f32` |
| `double` | `f64` |
| `string` | `str` |

The new integer family adds `u16`, `u32`, `u64`, and `i8`. There is no plain
`f8`: if an 8-bit floating representation is ever justified, its format is in
the name, such as `f8e4m3` or `f8e5m2`. `bf16` is likewise a distinct future
format, not an alias for `f16`.

The semantic rules must be frozen before spelling changes:

- literals are contextual; an unconstrained integer defaults to `i64` and an
  unconstrained floating literal to `f64`;
- every integer type is a real checked arithmetic type at its own width;
- operations on two concrete numeric values require the same type;
- changing width, signedness, or integer/float domain is explicit;
- a literal may land directly on a target type only when it fits;
- narrowing, overflow, invalid shifts, and out-of-range conversions remain
  defined traps, never wrapping or undefined behavior; and
- FFI/platform-sized integers are added only when a real boundary requires
  them, not as aliases that make program behavior machine-dependent.

`none` is the absence value of `T?`, not a type. `char` is one Unicode scalar
value, copied by value; it is not a borrowed view into a string and not an
extended grapheme cluster. `str` is immutable UTF-8. Iterating a `str` yields
`char`; byte-oriented work is explicit through `bytes`. `bytes` is immutable
binary data; mutable buffers use `list[u8]` or `array[u8, N]` until a measured
need justifies a dedicated buffer.

There is one general associative container, `map`; `dict` and `hash` are not
synonyms. `tree`, `stack`, and matrix types belong in libraries after
generics. `vec2`, `vec3`, and `vec4` are aliases or library types, not core
keywords. A compiler type `vec[T, N]` earns a place only with real SIMD
operations and ABI semantics; otherwise `array[T, N]` is the honest name.

`builder` may remain an internal/runtime specialization while the migration
is underway, but the target user surface is a library `strings.Builder`, not
another primitive scalar name.

### Generics and library data structures

Generics are a later, separate milestone. They are not a workaround for the
class, interface, weak, or closure representation, and none of those phases
waits for them.

The first generic system is monomorphized and supports generic functions,
structs, classes, and interface bounds. It does not include higher-kinded
types, specialization syntax, variadics, associated types, or generic
interface existentials. [GENERICS.md](GENERICS.md) owns the detailed proposal
and must be reconciled with the final bracket type syntax before work begins.

Once generics exist, standard packages—not the core language—may provide
`Stack[T]`, `Deque[T]`, tree variants named for their guarantees, `Matrix[T]`,
and fixed-size vector aliases. Each type must justify its own invariant and
complexity; a bag of collection synonyms is not a standard library.

## Build order

Each phase below must land green and remain usable on its own. Focused tests
run during development. `zig build test` runs once before the phase commit is
considered complete, not after every prose or local implementation edit.

### Phase 0 — finish ARC and restore the release gate

1. Fix every confirmed current bug in [MISSING.md](MISSING.md); the remaining
   one is the damaged-module verifier panic.
2. Remove every feature-related skip and relaxed census assertion. Keep only
   genuine platform capability skips, and make the test summary distinguish
   them from product gaps.
3. Complete retain/release emission for every current reference shape:
   local, assignment, argument, return, aggregate field, optional, failure,
   loop binding, interface, bound method, container element, synthesized test
   entry, file, task, and worker teardown.
4. Keep the completed bound-function and interface receiver ARC proofs green:
   a stored callable retains reference fields in its copied receiver and
   releases them exactly once.
5. Keep the completed collection ARC proofs green: list slices and
   `map.values()` retain reference elements, and reference-valued array fill
   retains once per cell. Recursive copying remains isolated to a worker
   boundary, where identity cannot cross.
6. Keep the completed worker-boundary proofs green: nested argument snapshots,
   caller liveness, aliases within and between roots, both-runtime zero census,
   rollback, and transitive resource/function refusals.
7. Prove last-release destruction and rollback under success, recoverable
   error, trap, allocation failure, host failure, and runtime teardown on both
   engines. Include file close and unfinished-task join counts.
8. Remove retired ownership terminology from source comments, test names,
   diagnostics, coverage assertions, and generated grammar categories.
9. Record compile-time, artifact-size, runtime, and peak-memory baselines for
   representative value-heavy and reference-heavy programs.
10. Make the current public Guide and Library build clean against this exact
   compiler. Future syntax appears only in Status.

Exit: no feature-gated skip or relaxed leak assertion; no confirmed ARC or
hardening bug; zero live objects after every clean differential spec; exact
file-close/task-join counts; no user-visible legacy ownership language; and
reproducible baseline numbers.

### Phase 1 — freeze the new type contract

1. Write the numeric, `char`, `str`, `bytes`, container-application, and
   conversion rules as a target specification.
2. Decide the exact block-closure and capture-list grammar in the same small
   grammar note.
3. Extend the diagnostic taxonomy for conversion, class lifecycle, weak
   access, closure capture, and worker-boundary refusals.
4. Create the migration manifest: compiler tables, runtime tags, MIR encoding,
   ABI surfaces, standard library, examples, packages, editor grammar, public
   docs, and installer samples.

Exit: there is no semantic question left hidden inside the mechanical rename.

### Phase 2 — migrate the type vocabulary atomically

1. Add the complete internal type table and real arithmetic behavior for all
   widths.
2. Update parser, semantic types, constant folding, HIR, MIR, serializer,
   verifier, oracle, LLVM lowering, runtime values, host ABI conversions, and
   diagnostics.
3. Rewrite all Luce source, specs, packages, examples, benchmarks, generated
   syntax data, and public documentation in the same cut.
4. Refuse every retired spelling with direct replacement advice. Do not keep a
   long-lived alias period in a pre-release language.
5. Bump the module format for type-tag or instruction changes and the host ABI
   only if its published representation changes.

Exit: the old vocabulary is absent outside migration tests and history; the
full width/conversion matrix agrees on both engines.

### Phase 3 — build the weak-reference foundation

1. Design the runtime weak table/control block so zeroing precedes storage
   reuse and cannot race with ordinary release inside one runtime.
2. Implement weak fields, locals, optionals, and copies for built-in heap
   references on both engines.
3. Integrate zeroing with ordinary object teardown and add debug
   leak-cycle reports.
4. Reject weak value types, resources, function values, non-optional weak
   reads, and worker crossing.

Exit: a recursive value-struct/container graph can use a weak back-edge and
reach zero live objects without dangling access.

### Phase 4 — complete class reference semantics

1. Lower reference-kind layouts through one heap-object path shared with the
   existing ARC machinery.
2. Implement sharing, aggregate/container storage, optionals, returns, and
   reference mutation.
3. Add `is`, memberwise construction, visibility behavior, and deterministic
   `deinit`.
4. Prove unwinding and partial construction do not double-release or leak.
5. Keep inheritance, computed properties, synthesized class equality/hashing,
   and advanced initializer forms out.

Exit: aliasing a class observes shared mutation, `deinit` runs once on every
normal release path, and parent/child graphs use the already-proved weak
storage rather than shipping a cycle-prone partial class model.

### Phase 5 — replace interface values with owned existentials

1. Introduce one payload/metadata/witness representation.
2. Support struct and class conformers, returns, optionals, fields, arrays,
   heterogeneous lists/maps, and multiple conformances.
3. Enable mutable dispatch and weak existential storage with precise value-box
   versus shared-class behavior.
4. Preserve multiple methods, multi-value returns, defaults at call sites,
   and directional fallibility.
5. Reject incomplete, duplicate, static, mutability-incompatible, and
   signature-incompatible witnesses with focused diagnostics.

Exit: one heterogeneous collection can hold stateful values of different
concrete types and dispatch every method without lifetime dependence on the
creating frame.

### Phase 6 — add capturing closures

1. Lower capture analysis to an explicit environment layout.
2. Implement value snapshots, shared mutable cells, strong reference capture,
   weak capture, and named snapshot capture.
3. Make environments ARC objects and integrate them with function values,
   collections, interfaces, optionals, errors, and bound methods.
4. Add block closure bodies; consider trailing syntax only after the core is
   complete.
5. Diagnose obvious stored self-cycles and refuse worker crossing.

Exit: a returned closure safely retains and mutates captured state, and a weak
capture breaks its intentional cycle.

### Phase 7 — add only the optional ergonomics the model proves necessary

Candidates are optional chaining and an optional-binding form for a single
checked unwrap. They land only with examples showing that existing narrowing
is materially worse. Forced unwraps, unsafe unowned references, and a second
error mechanism remain out.

### Phase 8 — prove the model in userland

1. Build the retained higher-level UI layer above `std.ui`, `std.gpu`, and the
   existing low-level termui renderer.
2. Use class state, owned interface values, capturing callbacks, and weak
   back-edges in ordinary Luce—not compiler-known framework syntax.
3. Move the editor onto that layer and compare code size, allocation count,
   responsiveness, and clarity with the current implementation.
4. Treat every friction point as evidence: fix a general language/library
   seam or keep the explicit userland code; do not add a framework-only
   special case.

Exit: a button callback mutates shared model state, redraws the view, and
leaves no reference cycle; the editor is the end-to-end proving program.

### Phase 9 — generics, then library collections

Implement the separately reviewed generics plan, then use it to build and
benchmark the small set of library structures that real programs require.
Generics are not part of the ARC/classes/closures completion milestone.

### Phase 10 — release lock

1. Rebuild every internal and public reference from the accepted semantics.
2. Run the full deterministic gate, hardening corpus, site generator, package
   tests, editor product tests, installer smoke test, and benchmark comparison.
3. Audit diagnostics by simulating common mistakes, not only valid programs.
4. Verify a clean macOS ARM64 install can compile, run, edit, and test without
   repository access.
5. Publish only when the docs, binaries, extension, libraries, and Status page
   carry the same version and feature boundary.

## Verification contract for every language phase

Every phase carries the smallest relevant subset of this matrix while it is
being developed and the whole relevant matrix at its exit:

| Layer | Required evidence |
|---|---|
| Lexer/parser | accepted grammar, recovery, depth limits, precise refusals |
| Semantics | positive programs plus wrong type, effect, mutability, lifetime, visibility, and worker-boundary cases |
| HIR/MIR | structural tests, verifier rejection, print/decode round trip, format bump when required |
| Runtime | direct count/lifecycle tests, zero/double release defense, resource teardown, leak census |
| Differential spec | identical output, traps, errors, frames, host world, and live-object census on both engines |
| LLVM | structural IR tests where ARC placement or ABI shape matters |
| Optimizer | retain/release elimination never changes observables or teardown order |
| Documentation | internal fences compile; public samples run or refuse as claimed; links and surface coverage pass |
| Hardening | deterministic fuzz corpus plus a reduced regression for every discovered failure |
| Performance | compile time, runtime, allocations, peak memory, and artifact size compared with the Phase 0 baseline |

Tests belong with the layer whose claim they observe. Any Luce program whose
observable behavior is being asserted belongs in `src/luce/specs/` and runs on
both engines. Focused commands (`test-language`, `test-stdlib`, `test-host`,
`test-backend`, `test-editor`, `test-tools`) are the inner loop; the full gate
is the phase boundary.

## Acceptance programs for the north star

The roadmap is complete only when all of these are ordinary, heavily tested
programs:

1. Two class references observe the same `Counter` mutation.
2. A class `deinit` runs exactly once through return, optional, interface, and
   container paths.
3. A parent owns children strongly; each child holds a weak parent; dropping
   the root leaves no live objects and weak reads become `none`.
4. A recursive value-struct/container graph uses a weak container back-edge
   and reaches zero live objects when its root is dropped.
5. A returned closure captures a local counter and mutates it on successive
   calls.
6. A stored callback captures its owner weakly and does not form a cycle.
7. A heterogeneous list and map hold different stateful `UIElement`
   conformers and dispatch several mutating and multi-value methods.
8. Every numeric pair, literal boundary, conversion, overflow, and shift has a
   positive or rejection/trap case.
9. Unicode scalar iteration and `char`/`str`/`bytes` round trips distinguish
   text from binary data.
10. A worker copies a nested container graph without sharing identity and
   rejects resources, classes, weak references, and capturing closure
   environments.
11. A retained termui button callback updates model state and the editor uses
    the same public library surface.

## Explicit non-goals for this roadmap

- class inheritance;
- interface default methods or inheritance;
- garbage collection;
- unsafe pointers or user-visible manual retain/release;
- unsafe `unowned` references;
- shared mutable state between workers;
- operator overloading;
- reflection, macros, or metaclasses;
- higher-kinded or variadic generics; and
- collection synonyms promoted into primitive types.

The point is not to reproduce Swift or Zig. They are sources of proven
implementation ideas. Luce's advantage is the smaller surface: Python-shaped
syntax, explicit types, native code, and one memory rule a user can carry from
their first list to their first UI.
