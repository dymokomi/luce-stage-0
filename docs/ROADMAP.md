# Roadmap — from the current language to 1.0

This is the living plan for Luce. It begins with the language that exists in
the repository, names the remaining boundaries precisely, and orders the work
that can move those boundaries. It is not a bug list. Confirmed incorrect
behavior belongs in [MISSING.md](MISSING.md); proposed syntax stays in `text`
fences here until the compiler accepts it.

The destination remains deliberately small:

> Values copy. References share identity. ARC keeps references alive. Weak
> references break cycles. Resources close at the last strong release.
> Workers never share object identity.

That sentence already explains the current language from a scalar to the
editor. The remaining work must preserve it rather than add a second lifetime
model for generics, interfaces, UI, or packages.

## Audit baseline — 2026-08-19

The baseline below was checked against the compiler stages, the executable
specifications, the public documentation, the TermUI package, and the shipped
editor. “Complete” means the supported boundary works on the compiled engine
and the differential oracle, including refusals and zero-object cleanup. It
does not mean Luce implements the corresponding feature set of Swift, Python,
or another language.

| Area | State | What is true now | Honest boundary |
|---|---|---|---|
| Compiler pipeline | Complete | UTF-8 source passes through lexer, parser, semantic analysis, typed HIR, mechanical lowering, verified MIR, optimization, and LLVM code generation. | The interpreter is a test oracle, not a shipping fallback. |
| Limits and hostile inputs | Audited | Ordinary operand batches, command-line arguments, import graphs, and dynamic collections grow until their allocator, address space, or declared ABI width is the honest boundary. The old fixed import/argument ceilings are gone; serialized list counts are checked against the remaining bytes before allocation. | Structural safety budgets remain deliberately: source bytes, indentation/parser/semantic recursion, diagnostic volume, flattened value-structure size, serialized nesting, and trace output. Each has a diagnostic or fail-closed boundary test. |
| Artifacts and ABI | Complete | `.lc` is native machine code; `.lcm` is a verified internal seam. The module format and host ABI are declared in source (`mir/module.zig`, `codegen/abi.zig`; 64 and 30 at this audit). | Artifacts are target- and ABI-specific and are deliberately refused when stale. |
| Scalar types | Complete | `bool`; eight fixed-width integers; `f16`, `f32`, `f64`; `char`, `str`, and `bytes`; contextual literals; checked integer arithmetic; explicit conversions. | No platform-sized integers, implicit numeric promotion, `f8`, or alternate spellings. |
| Declared value types | Complete | Structures, enumerations, and tagged unions copy by value and may contain retained references. | No tuples, nested type declarations, computed properties, extensions, or user-defined subscripts. |
| Reference types | Complete | Lists, maps, arrays, builders, final classes, files, tasks, windows, surfaces, and closure environments use ARC. | No inheritance, unsafe pointers, manual retain/release, or tracing collector. |
| Classes | Complete | Shared identity, mutation through stable `let`, `is`, memberwise or one custom `init`, definite initialization, weak fields, interfaces, and one deterministic `deinit`. | No overloads, initializer delegation, subclassing, `override`, or `super`. |
| Functions and closures | Complete | Named/default arguments, multiple returns, function values, expression lambdas, block closures, strong/weak/snapshot captures, shared mutable cells, and bound methods. | Function values have no equality and cannot cross workers. |
| Interfaces | Complete inside the current boundary | Explicit struct/class conformance, multiple methods, multi-value and fallible requirements, directional effects, returns, optionals, closure captures, and heterogeneous lists/maps/arrays. Class witnesses share identity; `mutating` requirements support writing value-structure witnesses. | No inheritance, default methods, associated types, generic bounds, or runtime casts. |
| Memory management | Complete for the current type system | Retain/release covers locals, temporaries, aggregates, errors, traps, loops, closures, interfaces, resources, and workers. Zeroing weak storage breaks supported cycles. | Strong cycles still require an intentional weak back-edge; ARC is not cycle collection. |
| Concurrency | Complete inside the isolated-worker model | `spawn` and `wait` copy permitted graphs between independent runtimes while preserving aliases inside each snapshot. Bounded `channel[T]` conduits cross the boundary by deep copy, with blocking, try, and timed forms. | No shared heap, locks, atomics, async functions, cancellation, select over channels, or worker identity. |
| Modules and packages | Consumer and local-authoring path complete | Rootless siblings, governed projects, import graphs bounded by available memory rather than a fixed module count, exact package versions, path overrides, stores, shelves, `package new`, and `package version` work. | `luce install` fetches manifest `url:` rows under mandatory tree hashes. There is no registry, version solver, signing, or upload path; `package publish` refuses honestly. |
| Standard library | Complete for its documented roster | Fifteen embedded modules cover byte streams, math, strings, lists, paths, files, OS facts and subprocesses, terminals, JSON, ZIP, GPU surfaces, windows, TCP, HTTP, and build plans. | The UI/GPU host is implemented for macOS; other hosts fail closed. The APIs are intentionally low level. |
| TermUI and editor | Complete terminal proof | TermUI 0.5 owns the application loop and composes `Panel`, stacks, labels, rows, styles, events, and cursor placement. The editor is an ordinary declarative Luce application. | This proves terminal UI and the class/callback model. It is not yet a native GUI framework over `std.ui` and `std.gpu`. |
| Toolchain and release | Implemented | `luce` builds (bare, scripted via `build.luc`, or by file), checks, prints IR, answers editor queries, tests, installs packages, and maintains local ones; the release ships the `luce-lsp` language server; no-argument help pins that full command surface, and the test runner flushes per-test progress before entry. One checked installer supplies the compiler, editor, runtime libraries, TermUI, and VS Code extension on macOS 15+ ARM64 and glibc Linux ARM64/x86-64. Every archive names its immutable source commit and timestamp, target, optimization mode, module format, host ABI, pinned toolchain, bundled package versions, reproducible archive format, and required third-party notices; `luce --build-info` and `loom --build-info` report the binary identity. Linux releases contain pinned static LLVM. | Windows and musl Linux are not published. Luce remains pre-1.0 and promises no source compatibility between 0.x releases. |

The release gate at this baseline completed 554 internal tests and 1,436
differential specifications with zero failures, skips, or leaked Luce objects.
Package, editor, example, tooling, and documentation checks completed in the
same clean gate. The public release has a separate, slower proof for macOS
ARM64 and glibc Linux ARM64/x86-64 so an ordinary language change does not
rebuild two pinned LLVM containers. Counts are a dated audit snapshot, not a
target to inflate; the test claim and its layer matter more than the number.

## What is actually missing

There is no remaining language feature required by the first release. User-
defined generics remain a post-1.0 proposal: they may make reusable typed
algorithms and data structures more convenient, but the current classes,
interfaces, containers, standard library, TermUI, and editor do not require
them. Everything else below is optional ergonomics, a library/product layer,
a platform expansion, or release hardening. Keeping those categories
separate prevents a desired package registry or native widget set from
turning into a fictional compiler bug.

## 1. Owned interface existentials — complete

The interface representation milestone is complete. Interface syntax and
nominal conformance are unchanged; the runtime now stores one existential value:

```text
{ owned payload, concrete metadata, static witness table }
```

- A structure conformer is copied into owned existential storage.
- A class conformer is retained as the payload and keeps its shared identity.
- One static witness table has one slot per interface requirement.
- Every heterogeneous collection element carries its own payload and witness
  identity.
- Dispatch passes the one payload to the selected witness. A writing
  structure method mutates the existential’s boxed copy; a class method
  mutates the shared class object.
- Copies, optionals, fields, returns, errors, containers, closures, and weak
  storage use the same ARC operations as every other reference-bearing value.

The acceptance matrix is now executable and green on the compiled engine and
differential oracle:

- a multi-method interface whose value witness mutates state through several
  calls;
- different mutable structures and classes in the same list, map, and array;
- copies that make independent value boxes but retain shared class identity;
- replacement and unwinding that release exactly one payload;
- returned, optional, field-held, closure-captured, and weakly observed
  existentials;
- malformed MIR and serialized values that fail closed; and
- diagnostics for incomplete, duplicate, static, mutability-incompatible,
  parameter-incompatible, result-incompatible, and fallibility-incompatible
  witnesses.

The milestone still excludes interface inheritance, default bodies, associated
types, compositions, generic bounds, and runtime casts. Those are separate
features, not prerequisites for a sound existential.

## 2. Post-1.0: add monomorphized generics

Generics build on the owned existentials so interface bounds reuse the final
conformance representation. The separate
[GENERICS.md](GENERICS.md) proposal owns the design and acceptance matrix.

The first useful surface is intentionally narrow:

```text
func first[T](values: list[T]) -> T?:
    ...

struct Stack[T]:
    items: list[T]
```

Generic declarations specialize to concrete checked code before MIR. The
runtime, host ABI, ARC rules, optimizer, and LLVM calling convention should
not gain a second “generic value” representation. Interface bounds provide
the operations a type parameter may use.

The milestone earns completion with generic functions and declared types,
inference and explicit arguments, cross-module use, recursive instantiation
guards, visibility, precise diagnostics, ARC across value and reference
arguments, and measured control of compile time and code growth.

The first release has no higher-kinded types, variadics, specialization,
associated types, generic interface existentials, or implicit structural
bounds.

## 3. Build libraries that justify those features

Language features are only complete when ordinary Luce code uses them without
a privileged compiler path.

### Generic collections

After generics, build only structures with a distinct invariant and a real
customer: likely `Stack[T]`, `Deque[T]`, one or more explicitly named tree
types, `Matrix[T]`, and fixed-size vector aliases or structures. Do not add
`dict`, `hash`, or other synonyms for `map`, and do not promote library types
into primitive keywords.

Each collection must document ordering, mutation, complexity, iterator
behavior, ARC semantics, and failure modes, and must be benchmarked against
the direct `list` or `array` implementation it replaces.

### Native declarative UI

TermUI already proves that a class application, interface boundary, captured
callbacks, and a recursive view value can hide an event loop without
generics. The next UI layer is a different product: a native package above
`std.ui` and `std.gpu` with windows, input, layout, controls, accessibility,
focus, and rendering.

That package should reuse the vocabulary TermUI has made familiar—`Panel`,
`VStack`, `HStack`, `ZStack`, `Label`, and explicit state—without pretending a
terminal cell and a native control have identical behavior. It should be
built after the owned-interface work so heterogeneous controls and stateful
component contracts exercise the final language rather than create
framework-only compiler exceptions. Generic data structures can be added
later when released programs demonstrate that they earn their complexity.

## 4. Finish the package and platform products

These are toolchain and host projects, not language syntax:

- define a registry format and trust model before enabling
  `luce package publish`;
- add fetch/install/update commands with exact hashes and reproducible local
  stores;
- decide whether a lockfile adds information beyond exact manifest versions;
- publish and test a Windows toolchain, and decide whether musl Linux should
  be a separate static release;
- implement a Vulkan window/surface host on Linux and Windows; and
- give Windows the same one-command install, editor discovery, package shelf,
  and uninstall story already used by macOS and glibc Linux.

No client should report success before a real registry, authentication model,
hash policy, and end-to-end test server exist.

## 5. Add ergonomics only when real programs ask for them

Optional chaining and a concise optional-binding form remain candidates. They
are not scheduled merely because another language has them. A proposal must
show repeated current code from the editor, TermUI, native UI, or another
substantial package; explain why existing narrowing and `else` are materially
worse; and preserve the one optional and one recoverable-error model.

Forced unwraps, unsafe `unowned`, a second exception mechanism, implicit
numeric conversion, and ownership annotations remain outside the roadmap.

## 6. Lock the 1.0 contract

Luce is deliberately free to break before 1.0. The release lock begins only
after the current language contract, its userland proof, and the toolchain and
platform release gates are complete. Post-1.0 generics are not a release
prerequisite.

The lock requires:

1. one current language guide and one exhaustive reference generated from the
   same implemented vocabulary;
2. diagnostics audited from common user mistakes, not only valid programs;
3. a complete deterministic gate, hardening corpus, installer smoke, package
   tests, editor tests, site build, and benchmark comparison;
4. clean installs that can build, run, edit, test, and consume shipped
   packages without repository access;
5. documented source, module-format, host-ABI, and package compatibility
   policies; and
6. no planned syntax presented as current behavior.

## Proof contract for every language milestone

| Layer | Required evidence |
|---|---|
| Lexer and parser | Accepted grammar, recovery, nesting/depth limits, and precise near-miss refusals. |
| Semantics | Positive programs plus wrong type, effect, mutability, lifetime, visibility, and worker-boundary cases. |
| HIR and MIR | Structural tests, verifier rejection, print/decode round trips, and a format bump only when the serialized contract changes. |
| Runtime | Direct count/lifecycle tests, allocation rollback, double-release/use-after-free defense, resource teardown, and leak census. |
| Differential specification | Identical output, errors, traps, traces, host effects, and live-object census on both engines. |
| LLVM | Structural IR tests wherever ownership placement, layout, or ABI shape matters. |
| Optimizer | Rewrites preserve lifetime, cleanup order, errors, traps, and observable output. |
| Documentation | Internal fences compile; public samples run or refuse as claimed; links, anchors, and public surface rosters match. |
| Hardening | Deterministic property corpus plus a reduced regression for every discovered failure. |
| Performance | Compile time, runtime, allocations, peak memory, and artifact size compared with the current baseline. |

Any Luce program whose observable behavior is asserted belongs in
`src/luce/specs/`, runs on both engines, and finishes with a zero-object census
when successful. Focused lanes are the development loop; `zig build test` is
the phase boundary.

## North-star acceptance programs

- [x] Two class references observe the same mutation.
- [x] A custom initializer establishes every field or publishes no object.
- [x] `deinit` runs exactly once through optionals, interfaces, and containers.
- [x] Weak parent/back edges break class and recursive container cycles.
- [x] Returned closures retain and mutate captured state; weak captures break
  stored callback cycles.
- [x] Heterogeneous interfaces dispatch multiple and multi-value methods for
  value witnesses and mutable class witnesses through one owned existential
  payload.
- [x] Every numeric width, conversion, overflow, shift, Unicode scalar, and
  byte/text boundary has executable proof.
- [x] Workers copy nested graphs without sharing identity and reject resources,
  classes, interfaces, weak references, and capturing environments.
- [x] TermUI hides its application loop and the editor uses its public
  declarative component surface.
- [post-1.0] A generic library type and bounded generic algorithm work across
  modules on both engines without a runtime generic representation.
- [ ] A native UI package uses the final interface surface without
  compiler-known framework syntax.

## Explicit non-goals

- class inheritance, `override`, and `super`;
- interface default methods or inheritance;
- garbage collection or user-visible manual retain/release;
- unsafe pointers or unsafe non-owning references;
- shared mutable state between workers;
- operator overloading;
- reflection, macros, or metaclasses;
- higher-kinded or variadic generics; and
- collection synonyms promoted into primitive types.

Swift and Zig remain useful implementation and documentation references. They
are not feature checklists. Luce’s advantage is the smaller surface: familiar
indentation, explicit types, native code, and one memory rule that continues
to work as programs grow.
