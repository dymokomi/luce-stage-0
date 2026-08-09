# Language-lock audit

Point-in-time closeout of the living language description against commit
`25738aa` on 2026-08-08.  This ledger is evidence, not another reference:
`docs/LANGUAGE.md`, `docs/OWNERSHIP.md`, `docs/PIPELINE.md` and
`docs/MISSING.md` remain the current truth.

The pass read the repository contract, contribution and Zig guides, the
document catalogue, all four current language/status documents, the
THREADS closeout, the current site, the compiler-owned vocabulary tables,
and the SELF and constant-container implementation ledgers.  Frozen
decision records were used as provenance and not rewritten.  In
particular `docs/THREADS.md`, `docs/BYTES.md`, `docs/UNION.md`,
`docs/CONCURRENCY_RESEARCH.md` and the older numeric/failure records keep
the claims and measurements of their own runs.

## Closed in the lock pass

### L1 — resources were implemented but missing from the top-level taxonomy

At the audited commit, `docs/LANGUAGE.md:14-39` divided everything into
values and heap objects, called every user struct a value, and named only
four container shapes.  That contradicted the already-built `file` and
`task` handles and obscured the stricter rule for a struct carrying one.

The living reference now distinguishes values, container objects,
scope-owned resources and ownership-carrying structs
(`docs/LANGUAGE.md:14-52`; `docs/OWNERSHIP.md:13-36`).  A plain struct is a
value; a carrying struct follows what it carries, and any graph containing
`file` or `task` is non-copyable.  The root overview uses the same split
and verb boundary (`README.md:135-145`), as does the site.
Narrow-storage type syntax was corrected at the same boundary:
`array(byte, _)` is the rank-only type and its extent is supplied by the
construction; the enum example likewise uses the construction spelling
`new array(Method, n)` (`docs/LANGUAGE.md:755-760`).

### L2 — the trap reference and its coverage guard both stopped early

`TrapCode` has twenty members (`src/luce/support/vocabulary.zig:159-204`):
`integer_overflow`, `divide_by_zero`, `conversion_range`,
`assertion_failed`, `explicit_trap`, `missing_return`,
`call_depth_exceeded`, `string_bounds`, `string_boundary`,
`host_unavailable`, `index_bounds`, `key_missing`, `empty_collection`,
`use_after_free`, `null_object`, `bad_codepoint`, `not_owned`,
`shift_out_of_range`, `allocation_failed`, and `immutable_object`.

The old site reference omitted `allocation_failed`, while
`enumMembers` stopped at the first blank line
(`www/luce/src/coverage.zig:388-397` at `25738aa`).  The blank before
`allocation_failed` therefore made the coverage test certify only the
prefix it had read.  The reference now names all twenty and distinguishes
the two defense-only source paths, `missing_return` and `not_owned`.
Coverage now walks to the enum's structural closing brace, records only
depth-one members, and has a regression containing a blank line, a doc
comment, string braces, a nested function/switch with a comma-shaped
impostor, and tail members (`www/luce/src/coverage.zig:388-489`).

### L3 — `task.wait` fell between the method tables and the site

The compiler publishes six receiver tables, including `file_methods` and
`task_methods` (`src/luce/04_semantics/builtins.zig:196-217`).  At the
audited commit, site coverage read only through `file_methods` and its
highlighter omitted `wait` (`www/luce/src/coverage.zig:359-375` and
`www/luce/src/highlight.zig:89-98` at `25738aa`).

The coverage roster and highlighter now include `task_methods`, and the
builtin reference documents `wait()` as a consuming join.  The task type
and worker tour also state the resource boundary: only resource-free
answers cross; `file`, `task`, and graphs carrying either are refused at
`spawn`.

### L4 — the host, builtin and type rosters lagged the byte/thread runs

The old canonical host list ended at the whole-file and directory calls
(`docs/LANGUAGE.md:1008-1034` at `25738aa`), and the opening taxonomy had
no resource types.  The living references now identify raw
`file_open(path, mode) -> file!` as the primitive under `std.files.open`,
`create`, and `append_to`, and tell ordinary code to use those named doors
rather than mode numbers.  They include `file`'s `read`/`write`/`flush`
methods, the `file` and `task(...)` resource types, and pure
`parse_string(bytes) -> string?` (`docs/LANGUAGE.md:44-49,1068-1109`;
`www/luce/content/ref/types.md:350-362`).  They also say that command-line
arguments are handed to `main`; they are host table input slots, not an
`allow_host`-gated callable builtin.

### L5 — architecture shorthand had become false

`CLAUDE.md:45` at the audited commit said one numbered *folder* per stage
although stage 5 is a barrel, described four numeric types rather than
seven total/four arithmetic, and omitted newer MIR surfaces.  Its style
example pointed at the nonexistent `src/apps/loom/host.zig`
(`CLAUDE.md:81`).  `docs/PIPELINE.md:41-42` repeated the numeric count and
described the worker boundary only as “every object parameter says
`give`.”

The contract and pipeline now say numbered stage *surface* (folder or
barrel), seven numeric types/four arithmetic, the current MIR/runtime
surfaces, the real `src/apps/host.zig` path, and the separate iterative
resource-reachability walk.  Worker validation now distinguishes a
resource-free graph that can be re-owned from a resource graph that
cannot cross a runtime.

### L6 — current roadmap and performance prose still described an older tree

The old status lead claimed eighteen spec packages, “nothing designed is
unbuilt,” one open language question, and one benchmark row
(`www/luce/content/status/index.md:13-27` at `25738aa`).  The current
measurement is six of nine rows at C parity, with three separately named
gaps; package counts are deliberately no longer copied into prose.

The root and site now point to `docs/CODEGEN.md` as the single benchmark
table and state the current six/nine result.  The pipeline description
uses a registered executable specification rather than a volatile copied
count.

### L7 — union and D12 were both being rounded up

`docs/MISSING.md:193-220` at the audited commit called union simply “what
is left,” while the status page called tagged union ratified/not built.
That collapsed three different facts: the tagged direction is ratified,
the full design is drafted with three held questions, and the feature is
not scheduled.

Workers and owned tasks are shipped.  Typed channels are the approved
next design-and-implementation run, but D12 ratifies only typed pipes and
the ownership-moving `send(give x)` direction.  Endpoint construction,
capacity/back-pressure, receive, close and failure behavior remain
unratified.  Current roadmap prose now preserves both distinctions and
does not claim the global effect lock is a channel primitive.

### L8 — the document index described BYTES and concurrency before closeout

At `25738aa`, `docs/README.md:72-73` called a file an “owned object,”
marked BYTES only ratified, and described CONCURRENCY_RESEARCH as research
for a decision not yet taken.  The index now calls `file` a scope-owned
resource, marks BYTES built, and says the survey informed the built
THREADS design.  It also links this audit beside the SELF and constants
implementation ledgers.

### L9 — ownership diagnostics and resource graphs needed one rule

The resource taxonomy exposed two semantic holes: copying an outer
container/struct could duplicate a nested file or task, and spawn/wait
could ask `Runtime.copyFrom` to re-own a resource tied to another runtime.
Stage 4 closes both statically with the iterative, cycle-safe
`carriesResource` type-graph query
(`src/luce/04_semantics/declarations.zig:749-814`), the explicit-copy gate
(`src/luce/04_semantics/builder.zig:6251-6337`), and the worker result/input
gates (`src/luce/04_semantics/builder.zig:7997-8047`).  `not_owned` remains
a malformed-module defense rather than the source-language rule.

The diagnostic half uses the expression's source type and its local's
`OwnershipClass`, optional known owner, poison state and replacement
revision (`src/luce/04_semantics/context.zig:460-524`).  The common
ownership refusal and resource-specific move/copy advice live at
`src/luce/04_semantics/builder.zig:1847-2127`: only a live owning name is
offered `give`; a resource is never offered `copy`; a borrowed resource
parameter gets all three edits — signature, every caller, and retaining
site — and an ownerless field/index view is told to obtain a distinct owned
graph or restructure the handoff.  Focused specifications cover stores,
calls, returns, nested verbs, active loops, `free`, reassignment and stale
aliases (`src/luce/specs/errors_spec.zig:6405-7146`).  In particular,
`free(copy ...)` lowers the inner copy first, preserving its name, type,
absence, and resource errors; only a legal resource-free copy reaches
free's “bind this copy result” diagnostic
(`src/luce/04_semantics/builder.zig:2129-2142,10235-10285`;
`src/luce/specs/errors_spec.zig:6948-6977`).  The transitive-copy
and worker-boundary matrices live at
`src/luce/specs/errors_spec.zig:7148-7170,7219-7314`.

### L16 — implicit deep-copy reads also need the resource gate

The first transitive-resource pass covered the explicit `copy` verb and
worker transfer boundary, but two ordinary-looking reads also construct
independent owners: a list slice deep-copies each selected element, and
`map.values()` deep-copies each value into its fresh result list.  A
runtime-empty container is not itself a static safety proof; either path
could duplicate a nested `file` or `task` when it selects an element.

Stage 4 now applies the cycle-safe `carriesResource` query in
`lowerSliceRange` (`src/luce/04_semantics/builder.zig:6670-6691`) and the
map `values` method path
(`src/luce/04_semantics/builder.zig:9399-9414`).  `map.values()` is refused
whenever its value graph carries `file` or `task`.  A list slice with such
an element graph is refused unless both lowered bounds are equal
compile-time `long` constants: the narrow MIR proof that its copy loop runs
zero times, and the empty-list constructor required by `std.lists`' closed
`sort_by` specialization.

The focused specifications pin a cyclic `list(Node)` whose optional task
is reached by `[0:1]`, slice-bound type errors taking precedence over the
ownership refusal, the direct resource-list `[0:0]` success, resource
elements moving through `sort_by`, and
`map(string, array(file, _)).values()`
(`src/luce/specs/errors_spec.zig:7172-7217`, including the map case at
`src/luce/specs/errors_spec.zig:7209-7216`,
`src/luce/specs/threads_spec.zig:334-342`,
`src/luce/specs/functions_spec.zig:433-453`).  The language and site now
state exactly where these copy-producing reads are admitted.

### L20 — an annotated empty constant skipped the flatness boundary

The constant folder used to enforce R-E only while walking actual literal
elements.  An annotation could therefore make
`const TASKS: list(task(long)) = []` (or a nested-container/optional
counterpart) reach the program root, even though adding an element later
would be refused.
The folder now checks the annotated element type before the element loop:
top-level optional elements and every type graph carrying an owned object
or resource are rejected even at length zero
(`src/luce/04_semantics/constants.zig:350-367`).  Focused specifications pin
empty `list(task(long))`, `array(task(long), _)`, and `list(list(long))`
(`src/luce/specs/constants_spec.zig:537-559`).  Current reference and site
prose say that the annotation supplies a missing type, not an exemption
from flatness.

### L21 — same-root stores and shaped returns needed whole-operation checks

Locally valid ownership advice was unsafe in two operations the surrounding
statement made impossible.  A resource owner assigned bare from itself or
its alias was told to `give` that same name back to itself; an explicitly
written same-root `give` could poison the destination during lowering.
Stage 4 now refuses both redundant same-graph forms directly
(`src/luce/04_semantics/builder.zig:4130-4187`;
`src/luce/specs/errors_spec.zig:7005-7042`).  This is deliberately narrower
than the descendant-adoption gap in L17.

A shaped return also has facts no one slot can see.  It resolves visible
ownership roots for owner/alias/borrow/explicit-`give` conflicts, and records
each owning bare name's replacement revision when that operand is staged
(`src/luce/04_semantics/builder.zig:2840-2954,4805-4959`).  A writing
operation to the left is therefore accepted and the later bare result stages
the replacement; a nested handoff or writer to the right is rejected if it
invalidates an old value already staged
(`src/luce/04_semantics/builder.zig:5111-5253`).  The focused refusal
matrix covers distinct-owner advice, repeated borrows, owner/alias order,
explicit `give`, nested calls, diagnostic precedence and replacement
(`src/luce/specs/errors_spec.zig:6531-6796`), while the accepted writer-left
regression is pinned at `src/luce/specs/ownership_spec.zig:233-261`.  The
living ownership prose now states both the ordinary per-position S16/S17
rule and these cross-slot S23/S45 constraints.

### L19 — the invalid-entry invariant rounded one legal shape away

Luce admits `main(args: list(string))` with or without `-> !`, but the
backend's damaged-IR refusal said only “an entry function with
parameters” even though its condition is `parameter_count > 1`.
`CompileOptions` now names all four legal source entries
(`src/luce/support/types.zig:10-16`), and stage 4's `luce.sema.main`
return-type diagnostic enumerates all four rather than rounding either
command-line form away
(`src/luce/04_semantics/declarations.zig:2480-2535`;
`src/luce/specs/errors_spec.zig:1429-1507,1554-1575`).  The LLVM header,
CODEGEN prose, and internal refusal make the narrower correct invariant
claim: damaged IR with more than one entry parameter is refused
(`src/luce/08_llvm/lower.zig:1978-1984`).  These are wording and diagnostic
repairs only; the accepted program set did not change.

### L10 — the runtime table no longer overpromises `willreturn`

The runtime-effects header used to say every export terminates and the
table defaulted `willreturn = true`, even for host callbacks, waits and
release paths that can transitively close a file or join a task.  The
exhaustive false set is now `luce_rt_report`, `luce_rt_report_error`,
`luce_rt_args_list`, `luce_rt_file_open`, `luce_rt_file_read`,
`luce_rt_file_write`, `luce_rt_file_flush`, `luce_rt_file_read_text`,
`luce_rt_file_write_text`, `luce_rt_spawn`, `luce_rt_task_wait`,
`luce_rt_effects_enter`, `luce_rt_close`, `luce_rt_constants_abort`,
`luce_rt_discard_loose`, `luce_rt_unbind`, `luce_rt_free`,
`luce_rt_copy`, `luce_rt_index_set`, `luce_rt_list_slice`,
`luce_rt_remove`, `luce_rt_clear`, and `luce_rt_map_values`.  The three
copy-producing calls — `copy`, `list_slice`, and `map_values` —
temporarily withhold the attribute because a source-created ownership
cycle can make their recursive deep copy fail to terminate; `map_keys`
remains true because keys cannot own such a cycle.  A colocated
exhaustive test pins those twenty-three false and every other service
true (`src/luce/08_llvm/runtime_effects.zig:32-42,387-895,1026-1057`).

The living CODEGEN summary carries that exact termination boundary.  Its
memory account also keeps object-table rows and arrays in LLVM's default
location now that generated code reaches them directly, and names the
function table as the one retained pointer that cannot promise `nocapture`
(`docs/CODEGEN.md:791-831`).

`nounwind` behavior did not change: only final `report` and
`report_error` withhold it.  The corrected header also removed its stale
claim that only one reporting export did so
(`src/luce/08_llvm/runtime_effects.zig:23-30,1017-1024`).

## Channel prerequisites found by the lock

### L11 — closed: worker registries own their synchronization

The original real and spec hosts mutated their worker rows without a lock,
assuming D9's Effects guard also serialized lifetime machinery.  It does
not: spawn and join deliberately run outside Effects so a join cannot
deadlock a worker that is trying to print or spawn again.

The real growable registry and both fixed spec registries now own a
dedicated mutex and closing bit.  A thread starts before publication,
publication happens under the mutex, join detaches under it and waits after
unlocking, and teardown refuses new publication before repeatedly
detaching and joining one row.  The production table is append-only; the
fixed spec tables reuse physical rows but attach a monotonic identity, so
reuse invalidates the earlier handle rather than letting it join the next
occupant.  The Host keeps every other field alive until its drain completes
(`src/apps/host.zig:104-118,291-391`;
`src/luce/specs/hosts.zig:375-465,732-750,1172-1205`).  Raw contention,
closing/re-entry and stable-handle tests exercise both registry shapes
(`src/apps/host.zig:1453-1647`; `src/luce/specs/hosts.zig:1451-1638`);
`src/luce/specs/threads_spec.zig:518-540` also runs sibling nested spawns
through both engines.

### L12 — closed: every file callback obeys D9

Small callback helpers now put the recursive Effects guard around exactly
one host open, read, write or flush invocation.  Direct handle methods and
the whole-file loops share them; allocation, UTF-8 validation and loop
bookkeeping happen after the guard is released
(`src/luce/runtime/files.zig:112-162,182-257,326-386`).  Whole-file MIR
intrinsics are explicitly runtime-mediated rather than direct-host calls,
so the oracle does not wrap the entire loop in another recursive guard
(`src/luce/06_mir/defs.zig:288-342`; `src/luce/06_mir/test.zig:16-33`).
A two-thread runtime test checks that callbacks neither overlap nor observe
a recursive depth broader than that one invocation
(`src/luce/runtime/test.zig:967-1135`).

### L17 — an owner can still be adopted into its own descendant

The following source is accepted:

```luce
struct Node:
    children: list(Node)

func main():
    var root = Node(children = new list(Node))
    root.children.append(give root)
```

`Runtime.bind` first gives the descendant list the root binding's owner.
`append` stores the root, then `Runtime.adopt` rewrites that same list to
the container owner.  The root name is poisoned, scope unbind sees the
row owned by a container and skips it, and the compiled run ends with
the internal assertion “1 object escaped ownership.”  If the program
saves `let alias = root` before the append and then evaluates
`copy alias`, it instead segfaults after more than ten thousand
alternating `Runtime.copyFrom` list and struct frames
(`src/luce/runtime/heap.zig:1791-1813,1986-2114`;
`src/luce/runtime/containers.zig:155-167`).

This is not a new language choice: it violates S20's recursive release
and S33's promise that every owner has a death point.  L21's static refusal
of ordinary `x = x` and `x = alias_of_x` reassignment closes only a
same-root handback; it does not inspect an adopting destination's ancestry
and does not reject the program above.  The remaining repair is to reject
an owner entering its own descendant at every adopting door, with a direct
static diagnostic where stage 4 can see that ancestry and a new stable
`ownership_cycle` trap with message “attempted store would create an
ownership cycle” for alias-hidden cases.  That trap would bump
`module.format_version` 33 → 34; `abi.version` stays 13.  The invariant is
clear, but the trap surface and implementation are pending owner
ratification and therefore remain open in `docs/MISSING.md`.

### L18 — closed: file construction keeps the raw handle transactional

`files.open` now requires the open/close resource pair before touching the
host.  A successful raw handle remains locally owned until `Runtime.newFile`
has duplicated the path and attached its row; either allocation error
closes the raw handle once under Effects and returns the original
`OutOfMemory` (`src/luce/runtime/files.zig:182-201`).  Focused failing-
allocator tests refuse both allocation points and pin the open/close
census, handle identity, guard depth, live-row count and byte balance; an
open-only channel is refused before its callback runs
(`src/luce/runtime/test.zig:1137-1247`).

### L23 — closed: deep re-own and worker handoff are transactional

The audit that prepared the cross-runtime primitive for a queue found that
`Runtime.copyFrom` released only outer buffers on a later allocation
failure.  Already-copied child rows and nested String/struct storage could
survive until teardown; derived list builders had the same partial-result
hole, and a worker whose spawn or task-row construction failed could strand
argument/result storage.

Every partially built list, map, array and struct now walks its initialized
prefix with `freeValue` before releasing raw storage.  List slices, map
`values()` and the String/key list builders clean both their accumulated
run and the item that failed to append.  Spawn drops the storage of every
carried argument before closing the child runtime, and a joined worker whose
task row cannot be attached frees its unclaimed result.  Fail-index tests
pin immediate live-row rollback and full byte balance for each shape.  The
same review corrected packed-list copy to copy live cell bytes rather than
retained capacity (`src/luce/runtime/heap.zig:1979-2152`;
`src/luce/runtime/containers.zig:125-145,355-503`;
`src/luce/runtime/workers.zig:340-380`;
`src/luce/runtime/test.zig:636-792`).

## Deliberately deferred owner decisions

### L13 — S6 does not decide early release of a carrying struct

Scope teardown correctly walks a carrying struct, but the current
`free(x)` builtin accepts only a direct container, `file`, or `task`
handle (`src/luce/04_semantics/builder.zig:10235-10360`).  Whether explicit
early release should also walk a struct is a language decision, not a
wording fix.  `docs/OWNERSHIP.md` now states the current direct-handle
surface and `docs/MISSING.md` keeps the broader S6 question open.

### L14 — the contribution license policy contradicts itself

`CONTRIBUTING.md:138-150` contains two consecutive License sections: one
says no license exists and redistribution is not granted, the next says
contributions are dual MIT/Apache.  The repository also contains the two
license texts.  Choosing which statement reflects owner intent is a
governance decision, so the lock pass records rather than guesses it.

### L15 — stable trap messages retain pre-resource vocabulary

`use_after_free`, `null_object`, and defense-only `not_owned` say
“object” in the runtime's broad heap-handle sense, so each can also
describe `file` or `task`; `allocation_failed` says “container” even
when allocation of a resource row failed
(`src/luce/support/vocabulary.zig:222-231`).  Those outcomes remain
semantically correct, but their words are ambiguous now that the source
reference uses *container object* and *resource* as disjoint categories.
The site documents the legacy broad meaning.  Changing stable trap
output is deferred to one intentional diagnostic migration rather than
changing one message opportunistically in a prose pass.

## Deliberately deferred diagnostic precision

### L22 — ownership advice does not yet inspect every adopting operand batch

The original programs are all refused, but their first local repair can
poison a later use in the same operation.  For two `give task(long)`
parameters, `take(running, running)` advises `give running` at the first
argument; `[running, running]` does the same at its first retaining element.
Applying either edit makes the later occurrence a use of a poisoned name.
Likewise, when `consume` takes a first `give list(task(long))` parameter,
`consume(running, len(running))` recommends the locally correct handoff
before a later borrow of that name.

The common local refusal is
`src/luce/04_semantics/builder.zig:1847-2043`; the shared operand batch is
lowered at `src/luce/04_semantics/builder.zig:2702-2980`, while the
retaining meaning is applied by list literals at
`src/luce/04_semantics/builder.zig:6407-6492`, user calls at
`src/luce/04_semantics/builder.zig:8049-8131`, and constructors at
`src/luce/04_semantics/builder.zig:9597-9691`.  A later diagnostic pass
should examine all adopting slots and recursive later uses before
prescribing a move, and should instead name the conflict or recommend
staging/reordering when the edit would not compile.  This is diagnostic
quality only — no invalid ownership reaches MIR — and Tier 5b of
`docs/MISSING.md` holds the work.

## Verification

- `zig test www/luce/src/main.zig` — 35/35 generator, coverage, and
  highlight tests passed.
- `./www/luce/build.sh --fast` — 57 pages and 281 samples verified (191
  run, 23 trap, 5 raise, 59 refused, 3 shell); every sample and link
  passed on the final snapshot.
- `zig build grammar --summary all` — 5/5 steps passed, and regeneration
  left the committed VS Code grammar diff unchanged.
- `zig build test -j2 --summary all` — 65/65 steps and 1735/1735 tests
  passed in Debug.
- `zig build test -Doptimize=ReleaseSafe -j1 --summary all` — 65/65
  steps and 1735/1735 tests passed.
- Repository-wide `zig fmt --check src/ build.zig www/luce/src/ tools/`
  and `git diff --check` — clean on the final snapshot.

The ownership-cycle prerequisite L17, owner decisions L13–L15, and
diagnostic follow-up L22 remain explicitly recorded; none is silently
counted as fixed by the green closeout suites.  L11, L12, L18 and L23 are
closed by the implementation and tests cited above.
