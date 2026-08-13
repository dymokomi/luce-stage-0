# What Luce is still missing — the honest inventory

Rewritten 2026-08-12 after the language and pipeline audit.  This is a
living work list, not a history: resolved items belong in
[RESOLVED.md](RESOLVED.md), and the feature-by-feature review method lives
in [LANGUAGE_AUDIT.md](LANGUAGE_AUDIT.md).

The current tree has serialized module format 43 and host ABI 18.  The
interpreter and compiled path share `src/luce/runtime/` for dynamic
semantics, and `src/luce/specs/agree.zig` compares both engines on output,
ending, trace, leak census, and host world.  The repository suite is the
executable proof of that claim.

## Tier 0 — ownership and memory hardening

Ownership is the load-bearing language invariant.  These are executable
hardening tasks, not new language designs: each remains open until it has
positive and rejection coverage, allocator-failure coverage, and a
differential or structural backstop at the earliest useful stage and at the
runtime/verifier boundary.

- **T0-OWN-1 — Exhaustive ownership-operation matrix.**  Exercise create,
  alias, borrow, `give`, copy, return, reassign, field/index store, overwrite,
  pop/remove/clear, slice, free, loop-carried values, and nested calls across
  scalars, strings, lists, maps, arrays, structs, unions, optionals, function
  values, files, and tasks.  Include every legal composition and the illegal
  moved/borrowed/aliased form.
- **T0-OWN-2 — Allocation-failure rollback matrix.**  Inject failure at every
  allocation point in nested copies, strings, map keys and values, function
  receivers, slices, worker transfers, task/file acquisition, constants, and
  C exports.  Prove destination preservation, rollback, no leak, no
  double-free, and a stable error/trap.
- **T0-OWN-3 — Randomized owner-graph state machine.**  Generate valid
  operation sequences and hostile mutations against a reference model that
  requires exactly one owner, forbids illegal cycles, makes stale handles
  stale, and reaches zero live objects after teardown.  Keep reproducible
  seeds and minimized failing traces.
- **T0-OWN-4 — Cross-stage ownership contracts.**  Run ownership cases through
  semantics, HIR, MIR encode/decode, verification, optimization, the
  interpreter, and LLVM.  Forge MIR for mismatched `give`, owner locals,
  `inout`, and indirect signatures and prove every consumer refuses or agrees.
- **T0-OWN-5 — Exceptional-control-flow cleanup.**  Cover normal and early
  return, `break`/`continue`, `try`/`catch`, uncaught error, trap, exit,
  failed call/store/join, and discarded results.  Assert release order,
  ownership census, and host-world cleanup on every path.
- **T0-OWN-6 — Stale-handle and double-release matrix.**  Probe indexing,
  length, mutation, copy, comparison, `give`, free, nested fields, function
  receivers, task waits, and file operations after move/free, including row
  reuse and generation-boundary behavior.
- **T0-OWN-7 — Worker ownership lifecycle.**  Test transfer, copy, failure,
  discard/free, scope join, worker trap/error/exit, nested workers, and
  values containing nested structs, unions, optionals, function values, and
  resources.  Check both engines and every join outcome.
- **T0-OWN-8 — Sanitizer execution lane.**  Run generated artifacts and the
  runtime under supported address, leak, and thread sanitizers, with the
  ownership specs and allocator-failure corpus as inputs.
- **T0-OWN-9 — Debug ownership invariants.**  Add checked-mode assertions for
  owner-tree validity, live rows, generation monotonicity, root/worker
  isolation, and allocator bytes returning to baseline after generated
  sequences.

The implementation order for this tier is allocator rollback, the randomized
owner graph, exceptional cleanup, cross-stage contracts, worker lifecycle,
then sanitizer and invariant lanes.  The research basis includes the
[Zig testing and allocator documentation](https://ziglang.org/documentation/master/),
[Go fuzzing](https://go.dev/doc/security/fuzz/) and its
[race detector](https://go.dev/doc/articles/race_detector), Python's
[test support](https://docs.python.org/3.11/library/test.html),
[tracemalloc](https://docs.python.org/3/library/tracemalloc.html), and
[unittest cleanup](https://docs.python.org/3/library/unittest.html), plus
[Swift ownership parameters](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/declarations/)
and [parameterized testing](https://developer.apple.com/documentation/testing/parameterizedtesting).

The first T0-OWN-3 corpus slice is now checked in as a four-seed, 2,800-step
list-forest state machine with a reference owner model.  It covers legal
append/pop/insert/remove/overwrite/clear transitions, binding and return,
cycle and second-owner rejection, stale handles, double release, row reuse,
and explicit zero-live teardown.  A companion matrix now covers map value
replacement, array object-cell cleanup, transactional array fills, and
nested struct fields; the item remains open until the same approach reaches
unions, optionals, resources, worker graphs, and the cross-stage/invariant
lanes named above.  The MIR verifier now also rejects forged owner locals
whose `owns_storage` bit selects a physical representation incompatible
with their type, covering scalar, heap, optional, struct, and function
shapes, and refuses ownership walks on borrowed object parameters; broader
optimizer/encode/decode contract coverage remains open.
The runtime corpus now also has direct lanes for a
union-shaped optional callback whose receiver is borrowed, and for a worker
result that copies a nested object graph and closes the child runtime; broad
randomized worker/resource generation remains open.  The allocator-failure
matrix now drives every child allocation in a nested worker result, the
parent-side result copy, and struct construction with an object field; the
runtime also proves nested file close-once behavior, stale resource handles
after row reuse, and one-shot task waits.  The owner-graph reference model is
also a coverage-guided fuzz target now: mutated byte traces become
reproducible seeds for the same 700-step cycle, stale-handle, binding, and
teardown proof.  Randomized mixed resource and worker graphs remain open.
The runtime also has a checked-mode, allocation-free invariant assertion for
live-row census, free-row generations, program roots, exact container parent
edges, duplicate edges, acyclic ancestry, and borrowed function receivers;
its direct composite regression covers map, array, and nested struct doors.
Extending that assertion through live worker/resource graphs and allocator
baseline snapshots remains open.  A new format/spec regression now encodes
the already optimized ownership graph, decodes it, and runs the decoded
program through both engines; it covers the union/list/struct/bound-method
composition, a give parameter, and an inout receiver that shape-only round
trips could miss.  The wider optimizer, forged indirect-signature, and
allocator/invariant matrix remains open.  The repository now exposes
repeatable
`test-sanitize-c` and `test-sanitize-thread` ownership lanes; the current
Zig/macOS arm64 toolchain does not provide a usable address/leak sanitizer or
Valgrind mode, so those remain environment-dependent rather than claimed
green here.

## Tier 1 — design gaps before implementation

### Typed worker channels

`docs/THREADS.md` D12 reserves ownership-moving `send(give x)` between worker
runtimes, but does not decide the channel type, buffering/back-pressure,
receive result, close behavior, or failure surface.  This needs a design memo
before code.

### Fallible function values

`func(T) -> R!` is currently refused.  Decide whether fallibility is part of
function signature identity and how `try`/`catch` compose through indirect
calls before allowing it to bind or land in a stored function field.

### Owning bound methods

`give receiver.method` remains refused.  A bound function currently borrows its
receiver graph; making it own that graph would change copying and lifetime
rules for every struct containing a handler.  Reopen only with an explicit
per-value ownership representation.

## Tier 2 — language surface and ergonomics

- **Non-returning user functions.**  Literal infinite loops are handled, but
  flow analysis still recognizes only the built-in `trap`, `error`, and `exit`
  names as calls that never fall through.  Infer this property transitively
  only if recursion and cycles have a clear fixed-point contract.
- **Escape additions.**  `\r` and `\u{...}` need coordinated lexer/parser
  changes; `\xNN` remains incompatible with the UTF-8 invariant unless the
  language adds a byte-string type.
- **Direct string iteration.**  `strings.characters(s)` is the current
  allocation-bearing spelling; a codepoint iterator needs a representation and
  ownership decision, not just a new loop branch.
- **Assertion narrowing.**  `assert(x != none)` does not currently narrow `x`.
  Decide whether assertions are proof-producing flow guards or only runtime
  checks before changing `flow.zig`.
- **Reserved `files.append`.**  The list-method namespace reserves `append`,
  so the file API uses names such as `append_text` and `append_bytes`.
  Releasing that name needs a namespace rule, not a one-off exception.
- **Library/type questions.**  `wordcount` still uses `""` as a missing
  result; there is no `set(T)`, array slicing, environment mutation, or date
  library.  These are demand-driven extensions, not runtime defects.
## Tier 3 — deliberate non-goals

Generics for user code, closures with anonymous captured environments,
iterators as a protocol, interfaces/inheritance, operator overloading,
reflection, async/await coloring, shared mutable state, locks, atomics, and
thread identifiers remain outside the ratified language.  The design reason
for each is recorded in `TYPES.md`, `BINDING.md`, and `THREADS.md`; do not
smuggle one in as a convenience feature.

## Tier 4 — compiler and verifier follow-up

- F-strings and `elif` are still desugared upstream of the typed tree;
  moving them later would be a deliberate stage-3/4 seam change.
- Whole-array operations are not preserved as high-level nodes, so later
  stages cannot recover them for vectorization.
- The LLVM program-root proof is conservative beyond fresh `heap_new` rows;
  widening it requires a runtime-contract test and hostile-MIR proof.
- Constant arrays of value structs currently zero-fill then replace cells;
  optimize only if startup measurements justify a new constructor seam.
- Routed string methods type their arguments before routing to `std.strings`.
  They are safe for today's uniform signatures but need a landing rule before
  a routed method accepts width-polymorphic, optional, or function arguments.

## Tier 5 — tools, packaging, and documentation

- `luce fmt`, an LSP, and a debugger are not built.
- Packages can be consumed from a vendored store but cannot yet be published,
  fetched, signed, or yanked.
- There is no cross-target build flow; artifacts carry one host target and
  each artifact carries its own copy of `libluce_rt`.
- `luce ir` prints enum members in constant containers as raw numbers.
- The VS Code grammar is generated, but brace-aware indentation and recursive
  f-string highlighting remain editor approximations.
- The standard-library comment for `std.os.cpu_count`, the top comment in
  `std.math`, and the `strings.width` API table need wording corrections.
- The lexical reference and editor constants still contain hand-maintained
  vocabulary copies; derive or test them against the compiler tables.
- Stable resource-related trap wording, the exact scope of `free` on
  resource-carrying structs, and nested constant-container flatness need an
  owner decision before their diagnostics or representations change.

## Tier 5b — diagnostic precision

No known diagnostic-harness follow-up remains in this tier.

## Order of work

1. Design typed channels, fallible function signatures, and the owning-bind
   alternative before implementation.
2. Finish the semantic audit of assertions, escapes, string iteration, and
   routed method landing.
3. Clean stale examples, compiler/backend never arms, generated vocabulary,
   and user-facing documentation.
4. Only then take on publishing packages, cross-compilation, or runtime-size
   optimizations.
