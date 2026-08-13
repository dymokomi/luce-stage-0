# What Luce is still missing — the honest inventory

Rewritten 2026-08-12 after the language and pipeline audit.  This is a
living work list, not a history: resolved items belong in
[RESOLVED.md](RESOLVED.md), and the feature-by-feature review method lives
in [LANGUAGE_AUDIT.md](LANGUAGE_AUDIT.md).

The current tree has serialized module format 42 and host ABI 18.  The
interpreter and compiled path share `src/luce/runtime/` for dynamic
semantics, and `src/luce/specs/agree.zig` compares both engines on output,
ending, trace, leak census, and host world.  The repository suite is the
executable proof of that claim.

## Closed in the current pass

These are no longer missing, so they are listed only to make the audit
boundary visible:

- scope-end release of arbitrarily deep owned graphs uses an explicit
  worklist;
- deep copy, cross-runtime move, list slices, and map values use the same
  iterative copy path, with transactional rollback of rows, free-list state,
  and table allocation on failure;
- the dual-engine census is compared on normal completion, exit, traps, and
  uncaught errors, and `prints` requires normal completion;
- file handle position, writes, and open-handle state participate in the
  world comparison;
- literal `while true` without a break is recognized as non-falling-through;
- floating `%`'s boundary behavior is disclosed in the language and standard
  library documentation;
- empty string needles have one documented rule: `find` matches at the
  requested boundary and `count` counts all `len(s) + 1` boundaries.

The deep graph tests intentionally exceed ordinary native stack depth.  The
copy rollback test also checks allocator-visible state, not just `live` rows.

- a statement-level `{` now gets block-oriented guidance without
  changing the parser's one-diagnostic recovery rule;
- ownership advice inspects the complete source-order operand batch before
  suggesting `give`, so a repair cannot poison a later occurrence;
- a Python-style string `%` mistake now points to f-string interpolation.

## Tier 0 — decisions that can make a total function lie

### Large-angle `sin` and `cos`

`src/luce/std/math.luc` uses a compact range reduction whose accuracy falls
away beyond roughly `1e4`; large inputs still return plausible numbers.  The
owner decision is one of:

- refuse the unsupported domain with an honest optional/error result;
- implement a higher-precision reduction such as Payne–Hanek; or
- keep the total API and disclose an explicit accuracy domain to users.

Do not add more local series terms without measuring the reduction error and
recording the chosen contract.

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
- **Stale corpus workarounds.**  `examples/adventure/world.luc` still aliases
  fields into `var` locals in places where nested-place assignment now works.
  Remove the workaround and its explanatory comments as a cleanup change.
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

1. Decide and document the large-angle trigonometry contract.
2. Design typed channels, fallible function signatures, and the owning-bind
   alternative before implementation.
3. Finish the semantic audit of assertions, escapes, string iteration, and
   routed method landing.
4. Clean stale examples, compiler/backend never arms, generated vocabulary,
   and user-facing documentation.
5. Only then take on publishing packages, cross-compilation, or runtime-size
   optimizations.
