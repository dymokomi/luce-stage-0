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

The first T0-OWN-3 corpus slice is now checked in as a four-seed, 2,800-step
list-forest state machine with a reference owner model.  It covers legal
append/pop/insert/remove/overwrite/clear transitions, binding and return,
cycle and second-owner rejection, stale handles, double release, row reuse,
and explicit zero-live teardown.  A companion matrix now covers map value
replacement, array object-cell cleanup, transactional array fills, and
nested struct fields.  A second four-seed plus fuzzed, 1,200-step mixed graph
now drives direct list, map, and array edges through the same reference audit,
including cycle/second-owner rejection, detach/remove/clear, deep-copy probes,
stale handles, and zero-live teardown.  The item remains open until the same
approach reaches unions, optionals, resources, worker graphs, and the
cross-stage/invariant lanes named above.  The MIR verifier now also rejects forged owner locals
whose `owns_storage` bit selects a physical representation incompatible
with their type, covering scalar, heap, optional, struct, and function
shapes, and refuses ownership walks on borrowed object parameters; broader
optimizer/encode/decode contract coverage remains open.
The runtime corpus now also has direct lanes for a
union-shaped optional callback whose receiver is borrowed, and for a worker
result that copies a nested object graph and closes the child runtime; broad
cross-engine randomized worker/resource generation remains open.  A new deterministic
worker/resource lifecycle lane now interleaves task-list wait, one-shot
re-wait, pop, remove, clear, nested worker, error/trap/exit, intentional
worker-leak, and parent-owned file-graph transitions across four fixed seeds
and a fuzz target; it checks child joins, host close-once behavior, exact
leak-census roll-up, and allocator bytes at teardown.  The allocator-failure
matrix now drives every parent allocation during task acquisition and every
object allocation while building a nested array/map/list/file resource graph,
in addition to nested worker results, parent-side result copies, and struct
construction with an object field.  It accepts the runtime's documented
`OutOfMemory` and located `allocation_failed` boundaries and checks the same
rollback contract at both.  The runtime also proves nested file close-once
behavior, stale resource handles after row reuse, and one-shot task waits.  The owner-graph reference model is
also a coverage-guided fuzz target now: mutated byte traces become
reproducible seeds for the same 700-step cycle, stale-handle, binding, and
teardown proof.  Randomized mixed resource and worker graphs remain open.
The runtime also has a checked-mode, allocation-free invariant assertion for
live-row census, free-row generations, program roots, exact container parent
edges, duplicate edges, acyclic ancestry, and borrowed function receivers;
its direct composite regression covers map, array, and nested struct doors.
The assertion now also checks live file handles, live task-to-child links,
child-runtime invariants at the post-join close seam, and a parent object
allocator baseline.  The allocator-failure lanes now invoke that assertion
while partial nested copies, array fills, C value/compound doors, file/task
acquisition, spawn, and task-result transfer are still live, catching owner
metadata damage before teardown.  Concurrent inspection of a still-running
child and source-level failure injection outside the direct runtime lanes
remain open.  A new format/spec regression now encodes
the already optimized ownership graph, decodes it, and runs the decoded
program through both engines; it covers the union/list/struct/bound-method
composition, a give parameter, and an inout receiver that shape-only round
trips could miss.  The wider optimizer, forged indirect-signature, and
allocator/invariant matrix remains open.  Direct verifier coverage now flips
both sides of a serialized indirect-call ownership verb and proves the
mismatch is rejected; the optimizer suite also pins owner facts to a basic
block and treats indirect calls as barriers.  The repository now exposes
repeatable
`test-sanitize-c` and `test-sanitize-thread` ownership lanes; the current
Zig/macOS arm64 toolchain does not provide a usable address/leak sanitizer or
Valgrind mode, so those remain environment-dependent rather than claimed
green here.  The focused exceptional lane now also drives nested worker error
propagation through two joins, worker trap and exit unwinds with union-owned
lists, and an unobserved worker error whose task is released at scope end.
The mixed worker/resource lifecycle corpus now supplies the randomized
runtime-side slice; differential specs for every generated lifecycle trace
and the remaining allocator-invariant combinations remain open.  A direct
barrier-controlled thread lane now holds four real children blocked after
spawn, releases the parent task-list root, and proves join-on-release while
each child builds a nested struct/list graph; child close sees zero live rows
and happens exactly once.  A companion concurrent matrix now leaves the same
children blocked while the parent has a pending trap or exit, and proves the
stop state survives every join.  It also frees one child slot, exhausts the
host thread channel, and proves the rejected spawn closes its provisional
child without an orphan.  A new barrier-controlled two-child case holds one
worker inside a blocked file read while its sibling waits for the effect lock,
releases the parent task root, and proves teardown does not deadlock: one file
closes in the normal body, the trapped sibling's file closes during
child-runtime sweep, and join/close/leak counts remain exact.  Sibling and
nested worker races now also have a real-thread matrix: two siblings each
spawn two nested children, all four nested bodies meet at a barrier, and the
parent tears the graph down once by bulk release and once by explicit wait
then release.  It proves all six joins and child closes, zero live rows, and
zero inherited leaks.  The shared fixed-capacity host registry now also
reserves a row before starting user code, and a full 16-row table rejects
the next spawn without running a speculative body; larger production-host
allocation-failure behavior remains a separate contract to audit.
The production `loom` registry now follows the same publication order under
dynamic table growth: a failing allocator rejects before starting user code,
preserves the output handle, and leaves no provisional row to drain.  The
remaining worker lifecycle permutations are tracked by T0-OWN-11; the
join callback's exact-answer contract is covered by the focused runtime
lane below.
The direct lifecycle regression now also places task rows inside struct-shaped
values held by a map, list, and array: a resource-bearing child result is
rejected before cross-runtime publication, nested wait consumes its worker,
and scope release joins the remaining tasks with exact child/file cleanup.
Arbitrary holder graphs, repeated row reuse, and allocator-failure lifecycle
permutations remain open.
The stale-handle slice now probes every list, map, array, and builder door
after row generation reuse, plus file read/write/flush/copy/give operations;
it checks that double release is inert and that stale file operations do not
reach the host.  Nested function-receiver and task-resource combinations
still need their own exhaustive matrix.
The retaining-store rollback slice now drives append, insert, map index-set,
and struct field replacement through an induced allocation failure after the
incoming graph has passed its ownership proof.  The runtime consumes the
accepted graph on that failure, while rejected aliases still release only
  their value storage and preserve the object owner; the full differential
  suite caught and fixed that distinction.  Broader failure injection for
  compound stores, C-export allocation points, and all early refusal boundaries remains open.
The independent ownership audit also found a distinct host-boundary slice:
callbacks that return negative or oversized byte counts must be rejected
before any runtime slice or progress update; zero-progress writes must
terminate fail-closed rather than spin, and repeated
close/report calls must remain fail-closed.  The runtime now bounds `read` and
`write` counts and whole-file convenience loops.  Public C scalar lengths,
counts, file modes, enum tags, and callback argument counts now fail closed
before slicing, allocation, or output publication; the focused regression
also proves rejected calls preserve their out/status slots.  The remaining
C-export matrix now also proves raw file handles close exactly once through
`file_open`, `file_read_text`, and `file_write_text`, and that C `spawn` does
not publish a task when parent acquisition fails.  C `task_wait` now proves
nested result transfer is transactional, detaches before copying, closes the
child on failure, and rejects a second wait without a second join.  The same
failure corpus now covers optional text, struct replacement, map placement,
array fill, long concatenation, and `parse_string`, including their distinct
source/borrow/consumption contracts.  C string slicing now covers outside
views, inline copies, UTF-8 boundary refusal, bounds refusal, and out-slot
preservation.  The byte-taking C exports now use null-tolerant C pointer
types and reject a null input before slicing, allocation, or host access;
the regression covers text materialization, directory names, key text,
whole-file paths/content, and all three raise helpers, while an absent
optional result proves an unused null buffer is not read.  Every exported
`Value` result slot now uses a C-nullable pointer and rejects null before
inputs are read, callbacks or host I/O run, allocation starts, or ownership
changes; the direct regression covers constructors, text/list materialization,
deep copy/give, task/file results, constants, container queries, and string
conversions, including void readers.  All C status slots for raw file
read/write/flush, whole-file open/read/write, and their success/count answers
now use C-nullable pointers and reject null before byte slicing or host work;
the regression checks every slot and preserves the other sentinels.  All
borrowed `Value` inputs and value arrays, plus dimension arrays, now use
C-nullable pointers and reject null before slicing, callbacks, host I/O, or
ownership work; the regression covers ownership verbs, constructors,
struct/function runs, workers, files, every container door, strings, and
comparison.  Callback outputs now fail closed too: an argument callback that
reports success with a null byte buffer is rejected before list publication,
and null trap/error report callbacks are safe no-ops that preserve the
original diagnosis.  The lower-level tables now also reject unknown
`Answer` values before output use, distinguish exact exhaustion from other
negative values, reject unknown argument-callback answers, and bound
`path_kind`'s payload to its documented 0..3 domain.  The file channel now
applies the same exact-answer rule across raw and whole-file open, read,
write, and flush paths, while preserving `-1` as exhaustion.  The worker
channel now treats only `yes` as a successful join; `wait` reports
`host_unavailable` for `no` and malformed answers while still consuming and
closing the child exactly once.  The remaining callback work is the
documented runtime/host installation contract and domain checks for other
plain-number services; the worker run callback now likewise rejects any
answer outside `survived`, `raised_trap`, and `raised_error` before result
adoption.
The differential specs now put a task inside a union's optional field, that
union inside a recursive struct with an optional callback and child list, and
consume the task through a `give`d helper; a companion file case puts an
optional file and callback in a struct, narrows the file receiver, reads it,
and verifies scope teardown closes it.  A second resource matrix builds both
absent and present optional-task variants inside a union, adds a map and array
to the enclosing struct, moves it through a `give`/return helper, invokes an
optional callback, consumes every task, and tears down both success and
failure paths.  The compiler also pins one-shot wait rejection after a
`match` binding.  An inout writer now also replaces a union carrying an
optional list and a separate optional list field after a deep copy, then
clears both; the copied graph remains independent.  Present/absent
transitions beyond these task/callback cases, return/give across more shapes,
generated cross-engine traces, and an exhaustive indirect stale
task/function-receiver matrix remain open.  Finally,
measure long mixed traces' live rows, retained capacities, peak bytes, and
post-run bytes, not only the final leak count, following the snapshot-diff
style of Python's `tracemalloc`.

The direct runtime function-value matrix now exercises one borrowed receiver
through a list element, map value, array fill, struct field, deep copies, and
stale-receiver teardown; the exhaustive generated receiver matrix and
allocation-failure permutations remain open.

The whole-file reader now caps its accumulation buffer at the documented
content limit and uses a one-byte EOF probe instead of allocating an extra
read chunk; a fixed-buffer regression covers both exact-limit and oversized
files with close-once cleanup.  Longer-run peak telemetry remains open.

The runtime now rejects rank-zero arrays before allocating their element
buffer.  The language verifier already refuses the shape, but the direct
runtime and C constructors must not let a forged module create one inaccessible
cell whose `len` is zero; the regression also preserves the C output slot and
proves that no object row is published.  The wider decoded-shape and
allocation-door matrix remains open.

Worker function, argument-count, and depth values now fail closed before the
interpreter narrows or indexes them, and the shared spawn seam rejects negative
function IDs and unrepresentable depth budgets before allocating or moving
ownership.  The malformed-entry regression preserves its output and proves no
worker starts; broader generated worker-channel fuzzing remains open.

File acquisition now rejects the runtime’s post-close `-1` sentinel even when
an open callback incorrectly reports success, and closes that malformed raw
handle exactly once before returning `host_unavailable`; otherwise a published
file would bypass scope teardown.  Other resource callback and handle-domain
permutations remain part of T0-OWN-15.

The open door now also closes any non-sentinel raw handle a callback publishes
alongside `no`, exhaustion, or a malformed answer, so a bad answer cannot leak
an external resource before a Luce file row exists.  The broader callback
protocol and handle-domain matrix remains open.

The shared worker effect lock now treats unmatched releases as inert and
rejects releases from non-owners before touching recursion state, so malformed
boundary calls cannot underflow or unlock a platform mutex.  Barrier-driven
cross-thread lock/interleaving coverage remains part of T0-OWN-11.

The optional-text runtime door now accepts only the compiler’s exact `0`/`1`
presence flag, rejecting malformed values before it reads the borrowed buffer
or writes the result slot.  Other callback payload and ownership-event parity
cases remain part of T0-OWN-13 and T0-OWN-15.

The array-fill failure lane now also copies a function run containing outside
text and a borrowed receiver through every observed replacement allocation
failure, preserving empty destination cells and the receiver graph while
reclaiming partial runs; other function-valued retaining doors remain open.

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
