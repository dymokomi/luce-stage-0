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
  double-free, and a stable error/trap.  The fresh-key `mapPlace` path now
  proves key-copy, zero-copy, hash-index, and entry-run rollback; Builder
  growth and `str(builder)` snapshots prove their destination stays
  unchanged; and the common C constructor, owned-storage, and host
  string/list materialization doors now preserve out slots, live rows, and
  allocator bytes at every observed failure point.  A second C matrix now
  covers exported inline text, deep copy, list slices, map keys and values,
  `str`, and transactional `key_text` replacement, including nested source
  graphs.  Raw file/task acquisition and task-result transfer now have their
  own rollback matrices too.  Value-shaped union/optional copies now cover
  nested discriminant/payload records, present and absent optional fields,
  map and array siblings, long text, source-field inspection on every
  failure, and checked owner invariants while the destination is partial.
  The inout receiver lane now builds that same graph as a replacement while
  the old receiver is bound, refuses every replacement allocation in turn,
  and proves the old graph's fields, binding owner, rows, and bytes survive;
  the successful edge performs the release/bind handoff.  The remaining
  matrix is allocating C exports not yet in these direct corpora.
- **T0-OWN-3 — Randomized owner-graph state machine.**  Generate valid
  operation sequences and hostile mutations against a reference model that
  requires exactly one owner, forbids illegal cycles, makes stale handles
  stale, and reaches zero live objects after teardown.  Keep reproducible
  seeds and minimized failing traces.  The current runtime corpus is
  synchronous; the differential version still needs mixed generated
  programs containing structs, unions, optionals, files, tasks, `give`,
  `copy`, returns, nested calls, joins, and exceptional exits, compared with
  the same shadow ownership model on both engines.
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
  resources.  Check both engines and every join outcome.  Add barrier-
  controlled tests where children are blocked or completing while the parent
  waits, releases, traps, exits, or tears down, including sibling/nested
  workers and spawn/join-table exhaustion.
- **T0-OWN-8 — Sanitizer execution lane.**  Run generated artifacts and the
  runtime under supported address, leak, and thread sanitizers, with the
  ownership specs and allocator-failure corpus as inputs.
- **T0-OWN-9 — Debug ownership invariants.**  Add checked-mode assertions for
  owner-tree validity, live rows, generation monotonicity, root/worker
  isolation, and allocator bytes returning to baseline after generated
  sequences.
- **T0-OWN-10 — Typed cross-feature ownership traces.**  Generate valid and
  hostile traces that combine lists, maps, arrays, structs, unions, optionals,
  strings, function values, bound receivers, `give`, borrow, copy, return,
  reassignment, field/index stores, worker spawn/wait/release, files, traps,
  errors, exit, and allocation failure.  The shadow model must track owner
  edges, generations, value-storage runs, task/file ownership, and host events,
  with the same result, trap, trace, census, and cleanup on both engines.
- **T0-OWN-11 — Worker/resource lifecycle permutations.**  Extend the current
  real-thread cases to arbitrary worker counts, repeated wait/release/discard
  orders, stale task handles, row reuse, resource-bearing child results,
  child OOM during result/error finalization, join failure, and channel
  exhaustion followed by reuse.  Prove at-most-once joins, child finalization
  before worker destruction, exact inherited-leak transfer, allocator
  baselines, and a bounded no-deadlock teardown.
- **T0-OWN-12 — Allocation-door inventory.**  Replace the remaining fixed
  failure offsets with counting/failing-allocator coverage for key-text
  replacement, every exported constructor and derived container, map slot and
  entry growth, joined text, argument lists, file text, worker error messages,
  trace/diagnostic storage, table growth, and row reuse.  Each refusal must
  preserve destinations and sources, leave no partial child reachable, and
  clean host resources.
- **T0-OWN-13 — Ownership-event parity.**  Add a test-only event trace beside
  the existing outcome/census comparison and compare allocation/destruction,
  give/adopt/borrow, stale-handle refusal, file-close, worker-join,
  child-finalization, and allocator-failure events between the interpreter and
  LLVM paths.
- **T0-OWN-14 — Function-value receiver lifetime.**  Exercise function values
  and bound receivers inside every value-shaped container, across copy/give,
  return, reassignment, worker arguments/results, stale receiver use, receiver
  destruction, and function-storage allocation failure.  A function copy or
  release must never implicitly own or release a borrowed receiver.
- **T0-OWN-15 — Resource callback protocol.**  Specify and test exact behavior
  for `0`, `1`, `-1`, other positive/negative answers, null outputs, zero
  progress, oversized counts, close/flush/read/write failure, and repeated
  join.  The lower-level callback paths must distinguish host unavailability,
  exhaustion, and ordinary absence consistently rather than relying on
  truthiness.
- **T0-OWN-16 — Retention and peak-memory telemetry.**  Measure live rows,
  table capacity, free rows, retained container capacity, current/peak bytes,
  open files, active workers, and inherited leaks throughout long generated
  traces, not only at teardown; prove documented retention bounds and return
  to baseline.

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

The completed hardening batches are recorded in [RESOLVED.md](RESOLVED.md).
Only the acceptance gaps below remain active; they are intentionally kept
under the Tier 0 rows until the broader criteria in those rows are met.

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
