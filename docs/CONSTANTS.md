# Constant containers — the object that is the program, not the run

**Ratified in principle by the owner, 2026-08-07**: *"Yes — we need
constant containers obviously."*  What is ratified is the feature; what
this memo is for is the shape, because the shape turns on one question
the corpus cannot answer by itself and the owner has to (§6 below).

The model this extends is `docs/MEMORY.md`: value types (scalars,
`string`, struct, enum) copy, while reference types (`class`, `list`,
`map`, `array`, `builder`, `file`, `task`) are shared and freed
automatically at their last reference.  Until now a file-scope constant
could only hold a value, so a table — a `list`, a reference type — had
no constant form and was rebuilt per call.  What this memo observes is
that a reference object materialized once before `main` and held by the
program root never reaches a last reference until the program ends: it
is the program, not the run, and it lives for the whole of it by
construction.

## The evidence

Three files, all written under the current language by authors trying
to use it well, all paying the same rent.

- **`src/luce/std/zip.luc:84-101`** — the CRC-32 table, and the comment
  is the memo's own case: *"The table is built per call, because a
  top-level `let` is a value constant and a table is a list: 256 rows
  of eight steps in front of one pass over the data."*  That is
  **2,048 shift-and-xor steps and 256 appends per `crc32` call**, and
  `crc32` is called once per entry read (`:307`) and once per entry
  written (`:330`).  A four-entry archive rebuilds the same 256 rows
  eight times.
- **`src/luce/std/zip.luc:417-440`** — the four DEFLATE tables of
  RFC 1951 §3.2.5, **118 elements across four `list(long)`
  allocations**, with the same confession attached: *"They are
  functions rather than constants for the reason the CRC table is."*
  They are rebuilt in `codes` (`:576-579`) — which runs **per
  compressed block** — and again in `deflate` (`:778-781`).  These are
  literally printed tables from a 1996 RFC.  Nothing about them is a
  computation.
- **`examples/editor/editor.luc:178-230`** — the workaround that shipped
  *this week*, and the best one the language currently permits: two
  **space-fenced string constants** searched with `find`, because
  *"Luce has no sets and no constant containers (docs/MISSING.md
  tier 3 §1): a top-level `let` folds a value, so a list or a map
  cannot stand here, and building one per call would cost far more
  than the comparisons it replaced."*  Every word is fenced with a
  space on both sides so that a substring search can serve as a
  membership test — `in` must not match inside `int`.  It is measured
  *faster* than the 46 `==` comparisons it replaced (0.15 µs a word
  against 0.22–0.29 µs, 156,000 classifications, ReleaseSafe), which
  is the honest part; the dishonest part is that a membership test is
  spelled as a fenced scan, and `listed`'s doc comment has to reason
  about `at - 1` and `at + len(word)` never leaving the string.

`docs/MISSING.md` tier 3 §1 already names both halves and prices them:
*"A frozen `set(string)` a top-level `let` could hold would make
membership constant-time and let the compiler refuse a duplicate word.
Cheap if scoped to a frozen container."*  This memo takes the frozen
container and, on the evidence, declines the set (§4).

Note what the evidence does **not** contain: not one nested table.  The
CRC table is flat, the four DEFLATE tables are flat, both word lists
are flat, and a canonical Huffman table is two flat lists.  That is
what decides §2.

## §1 — The program-root object

**A file-scope `const` may hold a container.**  It is built by the
constant folder, baked into the artifact beside the interned strings,
materialized once per run before `main`, and held by the program root
for the whole run.

```text
private const crc_table: list(long) = [0, 1996959894, 3993919788, ...]

const length_bases: array(long, _) = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13,
    15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163,
    195, 227, 258]

private const keywords = {"and": true, "break": true, "catch": true}
```

**How the model extends.**  A constant container is a reference object
like any other; what makes it a constant is that the program root holds
the one reference, so its last-reference point is program teardown and
never earlier.  It is not a new kind of ownership — it is an ordinary
program-root reference materialized once, and the release walk touches
it last with the rest of the heap.

**Immutable, refused at compile time, per container** — the whole
method table, split by whether it writes:

```text
list      append  insert  remove  pop  clear  sort  reverse   refused
          find  contains  len  [i]  [a:b]  for x in xs         allowed
array     fill  sort  reverse                                  refused
          dim  find  contains  len  [i]  [a:b]  for            allowed
map       remove  clear                                        refused
          has  get  keys  values  len  [k]  for k in m         allowed
builder                                     the type is refused entirely
```

Plus the two element stores — `TABLE[i] = v` and `TABLE[k] = v` — which
are refused for the same reason and with the same sentence.  The
sentence names the constant and what it is: *"`crc_table` is a
constant; `append` would write the program"*.  `keys()` and `values()`
allocate fresh lists and are therefore fine; a slice `TABLE[a:b]`
copies and answers a fresh mutable object, which is fine
for the same reason.

**`builder` is refused entirely**, and the sentence is short: every one
of its four methods writes or consumes, and a builder that is never
appended to is a string.  Write the string.

## §2 — What may stand there, and what may not

**Elements: scalars, `string`, enum members, and object-free value
structs.**  Each of these is something the folder already produces —
`constants.zig` answers `ConstantValue` with `.long`, `.double`,
`.boolean`, `.string`, `.strukt` and `.absent` — so the element rule is
not a new judgment, it is the existing one applied per element.  An
enum member is a constant by ENUMS.md D8 and needs nothing.  A struct
that holds a reference object is already refused as a constant and stays
refused as an element by the same check (`carriesObjects`).

**Run one is flat: a constant container may not hold a container.**
This is the memo's one deliberate narrowing, and it is taken on the
evidence rather than on difficulty.  A baked list of baked lists is
*buildable* — the outer program-root object would hold references to
inner ones, all released together at teardown — but nothing in the
corpus asks for one, and it is where questions bite that flatness
avoids entirely, from how a fresh mutable copy of a nested constant is
built to how a mutable container holds a program-root one.  Refusing
nesting now costs nothing and can be relaxed later without breaking a
single program, which is the test that decides which way a restriction
should default.

**The three shapes:**

| written | what it is |
|---|---|
| `const xs = [a, b, c]` | a `list(T)`, `T` from the elements or from the annotation |
| `const xs: array(long, _) = [...]` | a rank-1 `array`, the literal supplying the dimension |
| `const m = {k: v, ...}` | a `map(K, V)`, `K` from §3 |

The bracket literal already exists at runtime and already parses; what
it gains is a constant position.  An array needs the annotation to say
it is one, because the bracket literal alone says `list`.
Multi-dimensional arrays are out with nesting, since a rank-2 literal
is a list of lists.

**Types land the way they already do.**  A constant has no type until
it lands on one: `const xs = [1, 2, 3]` is `list(int)` by the literal
default, `const xs: list(long) = [1, 2, 3]` is `list(long)` because the
annotation is the landing type — `constants.zig` resolves the
annotation *before* the fold for exactly this reason, and the rule
carries to elements unchanged (docs/TYPES.md D3).

## §3 — The map literal

Maps have no written form today.  They need one here, because a
constant map is the container the editor's evidence actually wants.

**The neighbors.**  Python's `{k: v}` is the spelling most readers
know, and it carries the language's most famous wart: `{}` is an empty
*dict*, so an empty set has no literal at all.  Go writes
`map[string]int{"a": 1}` — the type, then braces; unambiguous and
verbose, and Luce's version would be `map(string, long){...}`, which
puts a call-shaped thing in front of a brace-shaped thing for no gain.
Swift writes `["a": 1]`, reusing the array brackets and telling the two
apart by the colon — elegant, and it needs `[:]` for the empty case.
Ruby's `{"a" => 1}` spends a two-character token to avoid a colon it
did not need to avoid.  **Zig has no map literal at all**, and its
answer to precisely this problem — `std.StaticStringMap`, built at
comptime from a slice of pairs — is the closest neighbor to what this
memo builds; what Zig lacks is a spelling, which is what makes it the
argument for having one rather than against.

**Recommended: `{key: value, ...}`.**

```text
private const keywords: map(string, bool) = {
    "and": true, "break": true, "catch": true,
}

const method_names = {0: "stored", 8: "deflated"}
```

Four reasons, in the order they matter.  **Braces cost nothing**: they
are used by no construct today, and the lexer's refusal of a stray one
(`"blocks are indentation; braces belong to f-strings"`) is a sentence
that refines to name map literals — it was never protecting a future
block syntax, because Luce's blocks are indentation and always will be.
**The colon is unambiguous**: `paren_depth` already suppresses
indentation inside `(` and `[`, braces join it, and a block-opening
colon is the last token on its line while this one is followed by an
expression.  **It is what every reader expects**, from six languages.
And **the empty-map wart never arises**, because `{}` is refused with a
sentence naming `new map(K, V)` — an empty *constant* map holds nothing
and is a mutable map a function should build — which leaves `{}`
unspoken and free for a set literal if a set ever arrives (§4).

**Keys are `long`, `string` or an enum, as they already are.**
ENUMS.md's build first read this narrowly — `hashOf` and `keyEquals` in
`libluce_rt` read exactly two payloads, and a third would be a new
runtime semantic — and then found (2026-08-12) that an enum key needs no
third payload: it travels as the `long` it already is and comes back at
its own width, so `const bindings = {Key.left: Intent.move_left}` folds
into the program root like any other constant map.  A constant map keyed
by anything else is refused by the sentence `map(int, V)` already gets.

**Duplicate keys are refused at compile time**, naming the key and both
lines.  This is a real win a runtime map cannot give, and it is half of
what MISSING.md wanted from a set.

**Constant-only, or both positions?  Both — take the runtime literal
too.**  A grammar that works in one position and not another is a wart
the language carries forever, and the honest question is only what the
runtime form costs: it lowers to `new map` plus *n* stores, which is
exactly what the bracket literal already lowers to for a list.  One
grammar, one lowering pattern, two positions.  This is the memo's one
piece of scope beyond the ratified feature, and it is offered as such
in R2 — if the owner wants the run narrower, constant-only is a clean
cut and the runtime form is a later half-day.

**Compile time does not hash, ever.**  The baked map stores its entries
*in written order* and the materialization pass (§5) calls
`libluce_rt`'s own insert once per entry, so the hash and the probe
are the runtime's, computed the way every other map's are.  There is
no frozen layout, no sorted layout, no second hash function to keep in
agreement with the first — the question "do compile-time keys hash the
same as runtime keys" is answered by never asking it.  The only
compile-time judgment is duplicate detection, and it calls
`value.keyEquals` rather than keeping a copy of it, exactly as
`constants.zig` already calls `operators.compareLongDouble` rather
than re-deriving comparison (docs/NUMERICS.md §5).

## §4 — Sets: not now, and the reason is arithmetic

`set(T)` is a fifth heap type.  It needs a row in `types.HeapType`, a
`new set(T)`, a method table (`add`/`remove`/`has`/`len`/iteration),
MIR intrinsics for each, `libluce_rt` implementations, memory rules,
two-engine specs, and a literal whose spelling collides with §3's on
the empty case — Python's exact wart, arriving fresh.  That is a
feature-sized run, and the run this memo describes is the **last
feature before the language locks**.

The honest alternative is already in hand: **a constant `map(T, bool)`
is a set with a spelling problem**, and it gives constant-time
membership through the same hash index every map has, plus the
compile-time duplicate refusal.  The editor's evidence becomes
`keywords.has(word)` — constant-time, no fencing, no `at - 1`
reasoning, and a compiler that refuses the same word twice.  A
30-element constant `list(string)` and `.contains(word)` is the other
honest answer for tables that small, and it is also better than what
ships today.

**Recorded for later, because it is cheaper than it looks:** the
runtime's `Map` is already a set with a value column, so `set(T)` is a
flag on an existing structure rather than a new mechanism.  When a
corpus bleeds for it, that is the shape.

## §5 — How the object travels

Nothing here is a new runtime semantic, and nothing here counts
anything.

**The module gains a second constant pool.**  Today
`06_mir/module.zig` serializes `constants: []const []const u8` — a
pool of text blobs.  Beside it goes a pool of container constants: the
heap-type index (element type, rank, dims), the element kind, and the
elements as folded `ConstantValue`s, or for a map the key/value pairs
in written order.  `format_version` bumps; the wire fingerprint test
catches anyone who forgets.

**One new instruction, `const_container K`**, answering a
handle-typed register.  The verifier checks `K` is in range and that
the register's type matches the pool row's heap type — the same
discipline every other pool reference gets, and it is what keeps a
hand-made `.lcm` from putting a `list(long)` handle where a
`map(string, bool)` is expected.

**Materialization is a synthesized prologue, and it is driven from the
engine side.**  `libluce_rt` deliberately does not know a program's
type table (BYTES.md B2), so the prologue does not hand it one: it
calls the ordinary exports — `luce_rt_new_list` with the element zero,
`list_append`, `map_put` — once per element, in pool order, before
`main`.  The handles land in a per-run table that `const_container`
indexes.  This is B2 and B3's precedent applied whole: **both engines
run the same prologue against the same exports**, so what a constant
list *is* has one implementation, and the differential oracle compares
it for free.

- **Eager, not lazy.**  Lazy needs a per-use presence branch and gives
  the program an observable first-use order.  Eager gives a fixed cost
  before the first line of `main` and nothing after it.
- **`prune` extends to the pool.**  A constant no reachable function
  names is dropped from the artifact and never materialized, so an
  unused constant container costs nothing to ship *and* nothing to
  start — the sentence LANGUAGE.md already makes for value constants,
  kept true.
- **One trap can fire before `main`**: `allocation_failed`, because RAM
  decides (BYTES.md's folded ruling).  Debug builds report it at the
  constant's declaration site.
- **The generation story is that there is no story.**  A program-root
  row takes an ordinary generation, never advances it because nothing
  frees it before teardown, and is never on the free list.  `resolve`
  is untouched; `retired` is never approached.
- **The user leak census does not count them.**  The census exists to
  catch a run's objects that outlive the run, and a constant container
  is deliberately live for the whole run — it is the program, not the
  run.  Both engines exclude them identically because both get them
  from the same prologue, which is what keeps `agree` honest.
- **Teardown releases them last**, with the rest of the heap, so a
  run's memory still all comes back.
- **The only new field is one tag** in a union that already exists
  (`Owner`, §6) marking the program-root row, and it is read, never
  written on the execution path.  `docs/MEMORY.md`'s reference counting
  covers a constant container the way it covers any reference object;
  a program-root reference simply never reaches its last release until
  teardown.

**`abi.version` does not move.**  Nothing in `LuceHost` changes —
materialization is generated calls into runtime exports that already
exist.  BYTES.md spent a version; this run spends none.

## §6 — The hard question: frozen through a call

`f(TABLE)` where `f` takes `xs: list(long)` and calls `xs.append(v)`.
Stage 4 refuses `TABLE.append(v)` at the constant's own name and
refuses it through an alias, because the aliasing it needs is machinery
the analyzer already had.  It cannot see it through a call — the
parameter's type is `list(long)`, and `list(long)` is what a mutable
list is too.

This is not a corner: **the first evidence file passes one.**
`editor.luc`'s `listed(keyword_words, word)` hands a constant to a
function, and every table in `zip.luc` would be passed the moment the
tables stop being rebuilt in the function that reads them.  A design
that cannot pass a constant container to a function has not shipped
this feature.

**(a) Frozen is in the type** — `frozen list(T)`, Rust's `&`/`&mut`
answer, and the honest one in a language built for it.  The cost in
*this* language: every function that only reads a list must be written
against the frozen type or written twice, and there are no generics to
write it once; making mutable-to-frozen an implicit coercion then owes
a variance rule for `list(frozen list(T))` that nothing else in Luce
needs; and it reopens, one week later and one feature before the lock,
the sentence `docs/SELF.md` D6 just ratified — *"a reference argument
is shared, and its contents still mutate through the object's own
methods — that is what a reference is."*  Adding a mutability
dimension to the type system as the last thing before a lock is the
wrong shape of change at the wrong moment.

**(b) A runtime trap on mutating a frozen object** — Java's
`List.of(...)` answering `UnsupportedOperationException`, and the
pattern this language already uses where a static rule cannot reach.
Cost: one new trap code, one variant on a union that exists, and a
check at mutation sites.  The cautionary neighbor is JavaScript's
`Object.freeze`, which in sloppy mode *silently drops the write* — the
failure mode a trap exists to prevent, and the reason this must be a
trap and never a no-op.

**(c) Constants may not be passed as parameters.**  Refuted by the
evidence above in one line.

**(d) Copy at the call boundary.**  A hidden allocation per call,
silently defeating the entire purpose of not rebuilding the table.

**(e) Whole-program frozen-flow inference.**  Genuinely available —
Luce compiles whole programs and `prune` already walks from the entry —
and rejected on diagnostics: adding a call site in one file would make
a function in another file stop compiling, with a message that has to
explain a path.  Rust declined exactly this by making the signature the
contract, and it was right to.

**Recommendation: (b), with a static front line that makes the trap
nearly unreachable.**  Stage 4 refuses, by name and at the site:

```text
TABLE.append(v)            constant; the method writes
TABLE[i] = v               constant; the store writes
let x = TABLE  →  x.sort() the alias carries the fact
return TABLE               the caller's binding would write the program
xs.append(TABLE)           the container's element would be written
```

A program that wants a mutable list builds one the ordinary way and
fills it from the constant; the constant itself is read-only.  Plain
aliasing (`let x = TABLE`) is free — it shares the same reference — and
carries the fact that the shared object is a constant.

The only genuinely dangerous operation is a write, which is why exactly
one trap code is needed — **`immutable_object`**, named for the state
like `null_object` — and why it fires in exactly one situation: a write
through a parameter.  It is defense-only: unreachable from source today,
kept because a `.lc` is an executable and a `.lcm` reaches the backend
without the analyzer.

**Where the flag lives, and what it costs.**  `Owner` marks the
program-root row — it already answers "who holds this", and the answer
for these is *the program, until teardown*.  A boxed mutation
(`append`, `insert`, `sort`, `map_put`) already resolves the handle and
reads the row; a tag compare on a row that is already in a register is
not measurable.  The site
that needs an argument is the **inline element store**: `xs[i] = v`
and `grid[r, c] = v` are generated without a runtime call
(docs/CODEGEN.md, "Inline access"), and a check there would sit in the
hot loop `bench/`'s `arrays` and `matmul` rows measure.

Two things make that acceptable, in order.  First, **the check is
emitted only where the analyzer cannot prove the receiver is fresh** —
a store into an array the same function created with `new` needs
nothing, which is every store in every hot loop in the corpus and in
both benchmarks.  Second, where it *is* emitted, it is a compare and a
predictable branch against a field in the row the bounds check just
loaded, beside the bounds check already there: the `%depth` precedent,
which is one subtract and one branch per function and measured as
noise.  The obligation is stated rather than assumed — `bench/run.sh`'s
`arrays` and `matmul` rows are the guard, and `bench/compare.sh` against
the pre-run commit is the check.

## §7 — The memory rule

For `docs/MEMORY.md`: a constant container is a reference object owned
by the program root.  It is built at compile time, materialized once
before `main`, and never reaches a last reference before program
teardown, when it is released with the rest of the heap.  It is
excluded from the user leak census precisely because it is deliberately
live for the whole run — it is the program, not the run.  Aliasing
shares the reference and carries the constant fact; returning one or
storing one into a container is refused, because a fresh owner would
then be free to write the program; every mutating operation is refused
at compile time, and a write that reaches the runtime anyway traps
`immutable_object`.

## Surface interactions

Everything below is a consequence rather than a decision, and each is
one line because each already works.

- **`module.name` across imports** is unchanged: a constant container
  is reachable through an import exactly as a value constant is, and
  the visibility gate is the reference site's module (VISIBILITY.md).
  `private const TABLE` works, and the existing "a public constant may
  not hold a private type" check in `constants.zig` applies to the
  element type with no new code.
- **Indexing, slicing and iteration just work** — they are what the
  feature is for.  A slice copies and answers a fresh list; iteration
  reads the shared object.
- **A parameter default may be a constant container.**  It would be the
  first reference-typed default, and it is the same program-root
  reference at every call site, shared like any argument (docs/ARGS.md
  D8, unchanged).
- **A lambda may name one.**  `docs/FUNCTIONS.md` lets a capture-free
  lambda name module-level constants; a constant container is the one
  "outer" thing it can honestly reach, because reaching it captures
  nothing.
- **Threads: each runtime materializes its own.**  `docs/THREADS.md` D1
  is structural — *"nothing allocated in one runtime is addressable
  from another"* — and a shared read-only region would be the one
  exception through which share-nothing dies.  The cost is one prologue
  per worker; if it measures on small workers, the fix is a measurement
  away and does not change what a program can say.

## Where it lands

Stage 2: `{` and `}` leave the refusal list and join `paren_depth`, so
a multi-line map literal needs no continuation parentheses (the
f-string hole scanner's own brace tracking is separate and untouched).
Stage 3: a map-literal expression beside the list literal.
Stage 4: `constants.zig` grows container construction — elements folded
through the existing `fold`, duplicates refused through
`value.keyEquals` — and the alias tracker gains one bit.  MIR: a second
pool, `const_container`, a verifier rule, `format_version`.
`07_optimize/prune`: pool rows.  Both engines: the prologue, over
existing `libluce_rt` exports, and the program-root tag in `Owner` with
the mutation checks behind it.  Specs: two-engine rows for
materialization at every element type, indexing/iteration/slicing, a
fresh mutable copy, the refusals (each mutating method, each container),
duplicate keys, the `immutable_object` backstop driven from hand-made
IR, the census exclusion, and the artifact-refusal row for the version
bump.  Site: the Guide's language chapters and its exact-rules
appendix.

**Sequencing.**  After threads → lambdas → the self revision, on a
quiet tree, as the final feature before the lock.  Threads and lambdas
both move `format_version` and so does this; racing two runs through
one seam is how both are lost (the BITWISE.md lesson).  Nothing here
moves `abi.version`, so there is no contention with threads' worker
slots.  Nothing here touches the self revision, which has no receivers
in common with a constant.  The two files that pay for it first are
`std/zip.luc` — six tables, deleted as computations and written as
what they are — and `examples/editor/editor.luc`, where a fenced scan becomes
`keywords.has(word)` and a doc comment about `at - 1` goes away.

## Ratified (owner, 2026-08-07/08, in conversation)

The feature in principle first ("we need constant containers
obviously"), then the details as the conversation sharpened them:

| | ruling |
|---|---|
| **R-A** | **The `const` keyword** (*"so we have const, let and var"*): file scope declares with `const` — values as before, containers as this memo designs.  Top-level `let` retires for one-spelling-per-meaning; the refusal teaches (`file scope declares with const`).  `let` and `var` stay function-scope, unchanged.  Three keywords, three disjoint jobs. |
| **R-B** | **The dictionary literal is ratified**: braces belong to dictionaries — `{"jan": 1}` — with `map` confirmed as exactly the Python-dict sense.  Empty `{}` stays refused naming `new map(K, V)`. |
| **R-C** | **Constants are owned by the program's root** (the owner's framing, adopted over the memo's ownerless draft): everything keeps an owner, constants die when the program ends, and the future where modules load and unload at runtime inherits "unloading frees its constants" for free.  Implementation unchanged — nothing is freed mid-run; teardown reclaims. |
| **R-D** | **Enforcement through calls: the dynamic backstop** (§6's recommendation, taken on non-objection): the compiler refuses every mutation it can see; one trap code (`immutable_object`) covers the one shape it cannot — a write through a parameter. |
| **R-E** | **Scope defaults stand**: flat tables (no nesting) and no set type this version — a `const` dictionary of `word: true` is the membership answer.  Both revisitable without breaking a program. |

## Ratification

Four, and the first two decide the shape.

| | question |
|---|---|
| **R1** | **Frozen through a call.**  Recommended: the dynamic backstop — every case stage 4 can see refused by name, one new trap (`immutable_object`) for the write that reaches the runtime through a parameter, and no mutability dimension in the type system.  The alternatives are `frozen list(T)` in signatures (honest, infectious, and it reopens SELF.md D6 a week after ratifying it) and refusing to pass constants at all (refuted by the editor's own call). |
| **R2** | **The map literal: `{key: value, ...}`**, claiming braces and refining the lexer's sentence about them; `{}` refused with `new map(K, V)` named, which keeps braces free for a future set.  And: **legal in both constant and runtime position** (recommended — one grammar, and the runtime form is the list literal's lowering said again), or constant-only if the run should be narrower. |
| **R3** | **The memory rule as written above**: a constant container is a program-root reference materialized once and released at teardown, refused as a return or a stored element, and read-only — a program that wants a mutable list builds one and fills it. |
| **R4** | **Run one is flat** — scalars, strings, enum members and object-free value structs as elements; no container inside a constant container (relaxable later without breaking a program) — and **`set(T)` does not enter**, with a constant `map(T, bool)` serving membership at constant time in the meantime. |

## As built — 2026-08-08

This is a frozen decision record: the proposal and its measurements
above remain as written.  The final ratification table is authoritative,
and this appendix records the implementation where the proposal's
earlier examples or mechanisms disagree with it.

- **Declaration.**  File scope uses `const`; top-level `let` is retired
  and the diagnostic teaches `const`.  Function-scope `let` and `var`
  are unchanged, and there is still no top-level `var`.
- **Ownership.**  Each materialized row is owned by the program root,
  excluded from the user leak census while it is deliberately live, and
  released at runtime teardown.  Each worker has a runtime of its own
  and materializes roots of its own.
- **Surface.**  `{key: value}` is an expression in runtime and constant
  positions.  A runtime literal is a fresh mutable map; entries evaluate
  in order and a later equal key replaces the earlier value.  An
  unannotated integer key lands on `long`.  A constant map rejects an
  equal folded key and names both written sites.  Empty `{}` is refused
  naming `new map(K, V)`.
- **Shapes.**  A bracket constant is a `list(T)` unless an
  `array(T, _)` annotation makes it a rank-1 array; the literal supplies
  the dimension.  The proposal's `array(T, 29)` examples were never
  made into a sized type.  Empty lists and arrays work with an
  annotation.  Containers stay flat: scalars, strings, enums and
  object-free structs are elements; an optional field inside such a
  struct may be absent or present, while an optional top-level element
  is refused.  Nested containers, builders, structs that hold a
  reference object, multidimensional arrays and sets remain out.  Contrary to the
  proposal's earlier broad slicing example, only a list constant may
  be sliced, producing a fresh list.  Constant arrays support indexing
  and iteration, and a program can build a fresh mutable copy, but the
  language has no array slice expression.
- **Identity and defaults.**  The compiler emits one pool row per
  written construction rather than interning equal contents.  Aliases,
  imports, uses and a shared parameter default share that row;
  separately written equal constructions compare as different objects.
- **Visibility.**  Constant containers obey the ordinary file boundary.
  A public container cannot expose a private element or map-value type;
  marking the container private or making the type public closes the
  surface.  A public folded value may still be computed from a private
  constant because the value, not the private name, crosses the boundary.
- **Enforcement.**  Stage 4 tracks visible roots through aliases and
  control flow, refusing mutating methods (including `sort_by`), indexed
  and nested stores, `file.read` destinations, returns and retaining
  stores.  A parameter boundary hides provenance, so all runtime
  mutation paths, including LLVM's inline stores, trap
  `immutable_object` before changing the row.  A program that wants a
  fresh mutable object builds one and fills it from the constant.
- **Representation.**  Verified MIR carries a distinct
  `container_constants` pool and `const_container` instruction.  Dead
  rows are compacted after dead instructions, then both engines eagerly
  materialize the surviving rows before user code.  Allocation failure
  cleans partial rows and names the declaration in debug mode.  The
  serialized module was `format_version = 33`; the published host table
  did not change at that point; the current `abi.version` is 16 after
  the later `shell_run`, `term_event_data`, `dir_create` and `epoch_ms`
  host services, and the current module format is 43.
- **Customers and proof.**  `std.zip` now holds the CRC table, four
  length/distance base and extra tables, and the code-length order as
  six file-scope constants.  The editor's keyword and builtin sets are
  immutable `map(string, bool)` literals.  `constants_spec.zig` is the
  eighteenth feature package in the dual-engine executable
  specification and covers materialization, identity, imports,
  defaults, workers, every static escape and mutation family, and the
  dynamic backstop.
