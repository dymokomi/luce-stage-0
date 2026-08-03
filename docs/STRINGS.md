# String storage: values copy, literally

> **The rule.** A String's bytes have exactly one owner — the binding,
> container element, struct field, or map key that holds them, or the
> statement that produced them — and any store into something that
> outlives the current statement copies the bytes, so no owner ever
> holds a view of bytes it did not allocate.

`docs/MEMORY.md` records why scope ownership won for objects and then
refuses, permanently, every automatic manager for values. This is the
memo for what replaces them. It is `docs/MISSING.md` Tier 0 item 1,
second bullet.

Nothing in the language changes. No verb, no trap, no diagnostic, no
change to the leak census. S1–S43 keep every decision; three lines of
`docs/OWNERSHIP.md` need a clarifying clause and are quoted below. A
program cannot observe the difference except in RSS — which is the
test, and which is what makes this an implementation decision rather
than a model change.

## What is wrong

`runtime/heap.zig:45-62` splits a run's memory in two. Object storage
goes to a freeing allocator. **Values — String bytes and struct field
runs — go to `Memory.arena`, a `std.heap.ArenaAllocator` created per
run in `loom/runner.zig:489` and dropped whole at the end.** Nothing
between those two moments gives a byte back.

`runtime/value.zig` says it plainly: *"Nothing here owns memory. String
and struct payloads are borrowed from the program's constants or from
the runtime arena, and they stay valid for the whole run — a value is a
view, never a handle to free."*

Measured consequences, both in MISSING.md:

- A loop building and discarding one string per iteration, retaining
  nothing: **28 / 36 / 54 / 90 MB RSS at 0.5M / 1M / 2M / 4M
  iterations.** Dead linear, ~18 bytes an iteration, forever.
- `programs/editor.luc` peaks at **976 MB after 20,000 keystrokes into
  a 40 KB file** — 49 KB retained per keystroke. `Editing.splice` is
  `value[0:cursor] + extra + value[cursor:len(value)]`, two concats
  into the arena, and `Handle.key` then does four to six `struct_set`s,
  each of which allocates a fresh eight-field run (`heap.zig:693`) that
  is also never reclaimed. The strings dominate; the runs are tens of
  megabytes on their own.

Every program with a main loop has this shape. It is the difference
between a memory *footprint* and a memory *lifetime*.

## Why regions failed, and why they stop failing

MEMORY.md's objection to a per-statement scratch arena was not the
relief it gives (33% mid-file, 50% at end of file — still linear). It
was correctness: *"resetting would dangle every view already stored,
because containers, struct fields, `s[a:b]` and `m[k]` all hold borrows
of bytes they did not allocate. Whether a string escapes cannot be
decided at the producer, because the producer is usually a borrow of
something whose region is not known there."*

That is exactly right, and copy-on-store deletes its premise. Under
real copies **there is no stored view of bytes it did not allocate**,
so nothing a statement produced can still be reachable when the
statement ends. The escape question never has to be answered at the
producer, because the answer is always the same at the *consumer*: a
store copies.

## Does it close the leak?

The design stands or falls on the store-site list being complete. A
`Value` can come to rest in exactly seven places: a register, a local
slot, a struct field run, a container's element storage, a map entry, a
`Runtime` field, or a program constant. Registers never cross blocks
(`06_mir.zig`), so a register is statement-scoped by construction.
Constants are static and owned by nobody. That leaves five, and every
door into them:

| # | site | how it gets there | today | after |
|---|---|---|---|---|
| 1 | local binding, and reassignment | `local_set` (+ `object_bind`) | shares bytes | copies; the scope frees, S5 frees the old |
| 2 | list append | `.append_value` → `containers.append` | shares | copies |
| 3 | list insert | `.insert_value` → `containers.insert` | shares | copies |
| 4 | list / array element store | `.index_set` → `containers.indexSet` | shares | copies, frees the old (S22) |
| 5 | map value store | `.index_set` | shares | copies, frees the old |
| 6 | map **key** store | `.index_set` → `Map.insert` | shares | copies, freed with the entry |
| 7 | list literal element | lowers to `.append_value` (`builder.zig:1790-1815`) | — | as (2) |
| 8 | struct construction | `struct_make` → `Runtime.makeStruct` | shares run *and* bytes | copies both |
| 9 | struct field assignment | `struct_set` → `Runtime.setField` | fresh run, shared bytes | copies both |
| 10 | function return | `ret` | shares | copies, or moves an owned local (S16's `moved`) |
| 11 | `xs[a:b]` on `List(String)` | `containers.listSlice` → `deepCopy` | shares (`heap.zig:959`) | copies |
| 12 | `m.keys()` | `containers.mapKeys` | shares | copies |
| 13 | `m.values()` | `containers.mapValues` → `deepCopy` | shares | copies |
| 14 | `copy x` on a String-bearing object | `Runtime.deepCopy` | shares | copies |
| 15 | Builder append | `containers.append` → `ArrayList.appendSlice` | **already copies** into the Builder's own buffer | unchanged |
| 16 | `key_text` | `luce_rt_set_key_text` | already copies — into the arena | copies into one owned slot, frees the old |
| 17 | host text in (`file_read`, `arg`) | `luce_rt_intern_text` | copies into the arena | copies into an owned temporary |
| 18 | trap message | `Runtime.failMessage` | arena | at most one per run; a run ends on a trap |
| 19 | evaluator Port output | `output_store` | arena | interpreter-only; `08_llvm` refuses it, and the caller already copies out what it publishes |
| 20 | `Array(String)` zero fill | `Runtime.newArray` | the static `""` | static, no owner |

Rows 11–14 are the ones easiest to miss: `deepCopy`'s `else => return
held` arm passes a String through by pointer, so `copy` of a
`List(String)` today produces a second container holding the first's
bytes. Under the rule it duplicates them.

**With that list, the theorem holds.** No owned storage contains a
pointer it did not allocate; every allocation therefore has exactly one
death point, and the churn loop and the editor both go flat.

### The one residual hazard

A *register* can hold a borrow of container or field bytes across a
mutation of that container, inside one statement:

```luce
f(pieces[0], drop_first(pieces))    # drop_first calls pieces.remove(0)
```

`pieces[0]` yields a view into the list's element cell; `remove` frees
that element's bytes (S22); the first argument now dangles. Today this
is safe only because element bytes are arena-lived. A String has no
handle and no generation, so unlike S9 this cannot be turned into a
trap.

It closes statically, and cheaply: a read out of a container or field
materialises a copy when the same statement also contains a call that
could mutate the source. `07_optimize/effects.zig` already answers
"can this instruction free an object or change who owns one"
(`ownershipTransparent`), which is the same question one type wider.
The conservative version — copy whenever a container read is live
across any impure call in the statement — is what should ship, and it
should ship *with* the core change, not after it. Prediction to check:
it fires on zero lines of `programs/` and `src/luce/std/`.

## What it costs

Measured on this host (Apple M4 Max, `-O2` C, optimisation barrier
between iterations so nothing folds away):

| operation | cost |
|---|---|
| 40 KB memcpy (L2-resident) | **392 ns** (104 GB/s) |
| 4.7 MB memcpy | **50 µs** (92.5 GB/s) |
| 12-byte memcpy | **0.29 ns** |
| `malloc` + `free`, 12 bytes | **7.8 ns** |
| `malloc` + `free`, 48 bytes | **9.5 ns** |

Read those two columns against each other, because they decide the
whole design: **the copy is free and the allocation is not.** That is
also the oldest published result in this area. Herb Sutter's 1999
harness, the measurements that eventually got copy-on-write banned from
`std::string`, put plain deep-copy strings at 1726 ms, atomically
refcounted COW at 1949 ms — COW *lost* — and deep copy with nothing
changed but a better allocator at **642 ms**, beating every COW variant
by 2.5× to 52×. His conclusion was that the fix is *"to optimize the
memory allocation, not the copying"*
(https://www.gotw.ca/publications/optimizations.htm). Google's
`automemcpy` measurements say the same thing from the other end: 96% of
`memcpy` calls in their fleet are ≤128 bytes, so *"the size
distribution is strongly skewed towards small sizes advocates
optimizing for latency instead of throughput"* (ISMM'21,
https://dl.acm.org/doi/10.1145/3459898.3463904).

### The editor

Per keystroke, at a 40 KB buffer, with statement temporaries owned and
freed:

- `var next = state` — copies the run plus every String field: ~40 KB.
- `next.quit_pending = false`, `next.message = ""`, `next.content =
  …`, `next.dirty = true` — each `struct_set` builds a new struct
  value, so each copies the run and its String fields again. Four to
  six of these in `Handle.key`, more in `Handle.adjust` and
  `Handle.vertical`.
- `Editing.splice` itself: `cursor` bytes for the first concat, 40 KB
  for the second, both temporaries, both freed at the end of the
  statement.

Ten to fifteen 40 KB copies, so **400–600 KB moved per keystroke ≈
4–6 µs**, against today's ~60 KB. Ten times the traffic, and still
three orders of magnitude inside a 16 ms frame. RSS goes from 976 MB
and climbing to one owned buffer, one statement's temporaries, and a
few struct runs — **well under 1 MB, flat in keystrokes.**

Most of that 10× is removable and is step 4 below: `next.field = v`
lowers to `r1 = struct_set r0, field, v` where `r0` is dead
immediately after, so the new run can reuse the old allocation and the
untouched String fields move rather than copy. That is provable from
MIR liveness, needs no counter, and takes the editor to roughly 3×
today's traffic.

Worth saying separately: `Editing.splice` is O(n) per keystroke
*today*. Copy-on-store makes the constant worse and the complexity
identical. The editor wants a Builder or a gap buffer, and that is a
userland fix, not a language one.

### `bench/strings`

400,000 iterations of `b.append("item-"); b.append(str(i));
b.append(";")`, then split / count / upper / replace over the ~4.69 MB
result. Currently **1.73× C**.

- 400,000 `str(i)` temporaries: each becomes one allocation and one
  free instead of an unreclaimed bump. **~3.1 ms.**
- Builder appends already copy into the Builder's own buffer
  (`containers.append`). Unchanged.
- `let text = str(b)` — one extra 4.7 MB copy. **50 µs.**
- `text.split(";")` — 400,001 pieces, each an `s[at:word_end]` borrow
  appended into a `List(String)`. Every one becomes an owned
  allocation: **~3.1 ms**, plus 400,000 twelve-byte copies at 0.29 ns,
  which is 0.1 ms and beneath notice.
- `upper` and `replace` return `str(out)` — one fresh buffer each,
  moved out rather than copied.

**Predicted: 57 ms → 63–70 ms, i.e. 1.73× C → 1.9–2.1× C**, the wide
end allowing for Zig's GPA being slower than macOS `libmalloc`. Every
milligram of that is allocator, not memcpy. Small-string optimisation
takes essentially all of it back, because the average piece is 11.7
bytes.

### The parity benchmarks

Verified, not assumed. `matmul`, `arrays`, `stats`, `loops` and `math`
each mention String exactly once, on the last line:

```
matmul.luc:25:  print(str(Int(checksum)))
arrays.luc:22:  print(str(Int(dot)))
loops.luc:10:   print(str(total))
stats.luc:25:   print(f"{Int(math.sum(a))} {low} {high} {Int(checksum)}")
math.luc:23:    print(str(inside))
```

Zero String traffic inside any hot loop. `stats`'s f-string desugars to
a left-leaning `+` chain (`builder.zig:1524`), so it is seven concats,
once, at program exit. **0.97–1.07× C is untouched.** This is the
decisive difference from Swift, whose refcount channel is measured at
32% of execution time averaged over its suite — 25 points of it purely
the atomics, despite over 99% of objects being thread-private (Biased
Reference Counting, PACT'18,
http://iacoma.cs.uiuc.edu/iacoma-papers/pact18.pdf). Under copying,
a program that holds no strings pays exactly nothing.

## Small-string optimisation

**Yes, and it is load-bearing, not a garnish.** It is the answer to the
one real cost the design introduces — 800,000 allocations in the
strings benchmark, none of them larger than 12 bytes. It is also not
refcounting by any reading: there is no shared bit and no counter, only
a second storage class for bytes that fit in the slot they are stored
in.

`Value` is 24 bytes: `{ tag: u64, bits: u64, length: u64 }`, offsets
asserted at 0/8/16 (`runtime/value.zig`). Eight tag values are in use.
Demote `tag` to one byte and the remaining 23 are addressable: with a
distinct `string_inline` tag and the inline length in the tag word's
second byte, **22 bytes** fit inline — the same number libc++ reaches
in the same 24 bytes
(https://github.com/llvm/llvm-project/blob/main/libcxx/include/string;
libstdc++ and MSVC get 15 in 32). Without demoting the tag, `bits` plus
`length` give a 15-byte threshold, which is libstdc++'s and Swift's.

Either threshold covers what this corpus actually stores: split pieces
(~11 bytes), `str(Int)` results (≤20), wordcount's English map keys
(~5). **Take 22 if the tag demotion is clean; 15 is enough.** fbstring
draws the same line at 23 in-situ
(https://github.com/facebook/folly/blob/main/folly/docs/FBString.md).

Two costs, both honest:

- Reading a String *out of storage* into a register becomes two
  selects, not one load — but only there. Once the register holds
  `{ptr, len}`, `len`, `byte_at` and `s[a:b]` are as they are today, so
  `find_from`'s inner loop over a parameter is untouched.
- An inline string's bytes live in the cell, so a `{ptr, len}` derived
  from one points into container memory that moves on `append`. The
  fix is to materialise inline reads into a statement temporary — a
  ≤22-byte copy at 0.29 ns — which keeps the register form uniform and
  removes the hazard rather than documenting it.

It costs an `abi.version` bump (4 → 5) and a `.lc` `format_version`
bump (10 → 11). Both are cheap: an artifact already carries a tag and
is refused by name when foreign, and modules recompile from source.
Because of that ABI cost and because the core change is worth shipping
without it, SSO goes last — after the measurement that says how much of
the predicted 1.9–2.1× it recovers.

## `s[a:b]` on a String

It is a **borrow today, on both engines**, and it stays one.
`text.slice` returns `Value.ofString(text[start..end])` — pointer
arithmetic into the original bytes — and `08_llvm/lower.zig`'s
`emitStringSlice` is a bounds check, two UTF-8 boundary checks, and a
`getelementptr`. No allocation on either path.

`docs/LANGUAGE.md:137` already says the right thing and needs no
change: *"Slices copy: `xs[a:b]` allocates a new list the receiver owns
— deeply, when elements are objects…; `s[a:b]` on a String stays a
value."* What changes is not the slice, it is what happens when you
keep one. `pieces.append(s[at:word_end])` copies at the append. That is
`strings.split`'s whole cost, and it is the difference between Luce and
Go, which shipped `strings.Clone` in 1.18 precisely because a
50-byte substring pins its 1 MB parent
(https://pkg.go.dev/strings#Clone).

## Function returns

`src/luce/std/strings.luc` settles this by itself:

```luce
func trim(s: String) -> String:
    ...
    return s[first:last]        # a borrow of a parameter

func replace(s: String, old: String, replacement: String) -> String:
    if len(old) == 0:
        return s                # the parameter itself
```

`fold_case` does the same. A String-returning function may hand back a
view of a parameter, a view of a constant, or freshly-made bytes, and
Luce has no annotation that distinguishes them. Rust does distinguish
them, and pays for it with lifetimes — `Cow<'a, B>` is the escape hatch
and `'a` is the price. Luce does not have lifetimes and will not add
them.

So **`ret` copies** — except where the returned register is provably
the frame's own: a statement temporary, or an owned local being moved.
`emitScopeReleases(from, moved)` already takes exactly that `moved`
parameter for S16, so `Editing.splice`'s concat result moves out with
no copy and `strings.trim`'s slice is copied out. Both decisions are
static.

Extending S17 ("returning a borrowed parameter is a compile error") to
Strings would make `trim`, `replace` and `fold_case` illegal. It is an
object rule and it stays one.

## OWNERSHIP.md: three clarifying clauses, no rule changes

Everything the specification says stays true. Two situations become
*more* true than the implementation had made them:

**S37** already promises the outcome:

> `x.append(i)` — *"appends a COPY of the Int value; `i` "dying" each
> iteration is irrelevant — values are copied, never owned"*. `var
> names: List(String) = []` / `names.append("ada")` — *"String is a
> value: same story."*

**S3** already provides the death point:

> *"Unbound temporary dies at the end of its statement."* … *"Precise
> wording: 'end of the outermost statement containing the
> expression.'"*

**S32** already forbids the verbs, which is what keeps the surface
identical:

> *"Values never take verbs."* … `give name` — *"COMPILE error: give
> applies to List/Map/Array/Builder (and carrying structs), not to
> values."*

Three places need a clause added, and nothing else in S1–S43 moves:

1. **The vocabulary line.** *"Everything else (`Int`, `Float`, `Bool`,
   `String`, `Bytes`, structs) is a value: copied freely, never freed,
   never verbed."* — "never freed" is a statement about the *program*,
   and stays true; the runtime does free value storage, at the point
   its owner dies. Add: *"never freed by the program — the runtime
   reclaims a value's storage when the place holding it dies."*

2. **S17.** *"Returning a borrowed parameter is a compile error."*
   Add: *"This is a rule about objects. A String return copies instead
   of erroring, because a String has no verb to demand (S32)."*

3. **S26.** *"Struct copies alias the same objects."* Add: *"Object
   fields alias; value fields — Strings and nested plain structs —
   copy, so a struct copy is O(bytes of its value fields)."*

**S33** ("Nothing can leak") becomes true of values as well as objects
for the first time. **S22**'s "an element overwrite frees the old
element" and **S31**'s "`copy` duplicates the object and everything it
owns" both already say what the runtime must now do; they were
under-implemented, not mis-specified.

## Does the LLVM unboxing survive?

**Yes, untouched.** The unboxing that got the benchmarks to parity is
about *reads*, and copy-on-store touches only *stores*.

`08_llvm/lower.zig` holds a String as `string_type = { ptr, i64 }`
(line 590), an unboxed SSA aggregate; `len` is an `extractvalue`,
`byte_at` is a GEP and an `i8` load, `s[a:b]` is a GEP and a subtract,
and a String local is an `alloca` that `mem2reg` promotes. None of
those instructions moves.

Every store site in the table above *already* crosses into
`libluce_rt` as a boxed 24-byte `Value` through `luce_rt_index_set`,
`luce_rt_append`, `luce_rt_insert`, `luce_rt_struct_make`,
`luce_rt_struct_set`, `luce_rt_list_slice`, `luce_rt_map_keys`,
`luce_rt_map_values` or `luce_rt_copy`. The copy happens inside those
functions, behind a call that is already being made, so the generated
code for a store does not change at all. `boxed`'s trick of hoisting
the tag and length stores into the entry block (`lower.zig:1413-1424`)
keeps working, because the shape of a boxed String is still
`{ tag = string, ptr, len }`.

Two genuinely new emissions, both outside loops that matter:

- A String local acquires a `luce_rt_bind` at its store and a
  `luce_rt_unbind` at scope exit — the same pair objects already carry,
  and `07_optimize/ownership.zig` already deletes the dead ones.
- `ret` of a borrow gains one runtime call. A function returning a
  fresh or owned String gains nothing.

SSO would change reads, which is the reason it is sequenced last and
gated on measurement.

## MIR and the analyzer: what has to be added

**MIR has no statement, scope or region concept, and needs none.**
Confirmed: `06_mir/defs.zig`'s `Instruction` union is 23 tags and none
of them delimits anything; blocks are the only structure and registers
never cross them. What exists instead is better — stage 4 knows where
statements end and *emits the release explicitly*:

- `builder.zig:257` `registerTemp` parks a fresh value in a hidden
  local and binds it.
- `builder.zig:274` `flushTemps` releases and forgets the temporaries
  above a floor — called at the end of every statement, condition and
  loop body.
- `builder.zig:234` `emitScopeReleases(from, moved)` unwinds scopes
  innermost-first, skipping a moved binding.
- `06_mir/build.zig:239` `release` is `local_get` + `object_unbind`.

So the minimal honest addition is **not a new instruction**. It is:

1. A second predicate beside `carriesObjects`. Confirmed as MEMORY.md
   states: `declarations.zig:487` answers true only for `.heap` and for
   structs whose shape carries one, so `.string` answers false and
   `registerTemp` (gated on it at `builder.zig:1544`) never sees a
   String. The new predicate — call it `ownsStorage` — is true for
   `.string`, `.strukt` and `.heap`, and drives *release emission
   only*. It must not be wired to the verb rule: widening
   `carriesObjects` itself would make `xs.append(name)` demand `give
   name` under S21, which is a language change and is forbidden.
2. `libluce_rt` freeing String bytes in `unbind`, `freeValue` and
   `freeObject`, and copying in the store sites of the table.
3. Every String producer allocating from `Memory.objects` rather than
   `Memory.arena`. `Memory.arena` then holds nothing but the trap
   message and can be retired.

An owned String local always owns its bytes, because every path into it
either moves a fresh allocation in or copies. That means `unbind` is an
unconditional `free` with no flag, no header, and no side table
mapping bytes to owners — which is the property that keeps this from
becoming bookkeeping. Constants are copied on store like anything else;
`let s = "hello"` allocates five bytes, and SSO makes that free later.
Parameters are `.alias` in `declareLocal` already and are never
released.

Ordering inside the runtime, three places where it matters:
`containers.append` must copy before `ArrayList.append` may realloc;
`containers.indexSet` must copy before it frees the old value (`m[k] =
m[k]` is legal); and a `local_set` that reassigns must compute, then
free the old, then store.

`.lc` `format_version` bumps: the instruction set is unchanged but the
meaning of `object_unbind` is not, and a stale module would simply not
release its strings.

`Bytes` gets the same treatment mechanically. It is v1 machinery on the
way out, `08_llvm` does not lower it, and it has no producer in the
language today.

## Order

Each piece is independently valuable and independently shippable.

1. **Object table row reuse.** Not this document's subject, and it goes
   first anyway: it is small, self-contained, already designed in
   MEMORY.md, and it is the other half of MISSING.md Tier 0 item 1.
2. **The core: owned String bytes and copy-on-store**, rows 1–20,
   including the mutation-during-statement read rule. This cannot be
   split further — half-done it double-frees. It closes the churn loop
   (28/36/54/90 MB → flat) and every container case. Measure the
   strings benchmark here.
3. **Struct field runs.** Separable, because struct values are a
   distinct tag and the analyzer already tracks their shape. Closes the
   editor's remaining tens of megabytes and makes S26's clarified
   wording true.
4. **Destructive `struct_set`** when the source register is dead after
   it. Pure optimisation, provable from MIR liveness, no semantic
   change. Takes the editor from ~10× today's copy traffic to ~3×.
5. **Small-string optimisation.** ABI 5, format 11. Gated on step 2's
   measurement.
6. **Move-instead-of-copy for statically fresh stores.** `xs.append(a +
   b)` and `next.content = Editing.splice(…)` hand over the temporary's
   allocation instead of duplicating it. Removes one 40 KB copy per
   keystroke and the `let text = str(b)` copy. Pure optimisation.

## Refused, with reasons

**Reference counting, ARC, and any hidden per-value counter.** Refused
permanently by directive (MEMORY.md), and this document does not
relitigate it. What is being given up is real and should be written
down: under counting, `var next = state` is O(1) instead of O(40 KB),
`split` allocates once per piece with no copy, and `return s` is free.
Swift proves it works. It also measures: 32% of execution time on
average, 25 points of it the atomics alone, on a runtime where over 99%
of objects are thread-private and the compiler still cannot prove it
(PACT'18). Luce has no threads, so a counter here would be non-atomic
and cheaper than Swift's — and it would still be a second memory
manager underneath a model that already has one.

**Copy-on-write.** A shared/unique bit is a reference count with one
bit of range, and it fails the same directive. It also has the worst
measured record of anything in this memo: Sutter's harness put atomic
COW *behind* plain deep copy, WG21 N2668 made it non-conforming in
C++11, and GCC broke its own ABI to comply
(https://gcc.gnu.org/onlinedocs/libstdc++/manual/using_dual_abi.html).
fbstring keeps COW only above 255 bytes, which is the one range where
this design's copies are also rare.

**Tracing GC.** MEMORY.md's engineering argument stands and is the
strongest one available: there is no root set, and acquiring one costs
what the backend just bought. Compiled code holds Strings as unboxed
`{ptr, len}` in whatever registers LLVM chose and hoists Array element
pointers into loop preheaders; making those enumerable means stack maps
or a shadow stack at every safepoint, in exactly the loops
`08_llvm/loops.zig` exists to keep clean (52 ms → 10 ms, against 10 ms
for C).

**A per-statement region as the whole answer.** 33–50% relief, still
dead linear. Refused as *the* answer; adopted as the *enabling*
insight, since copy-on-store is what makes any bulk reclamation sound.

**A bump arena with marks for temporaries, alongside owned bytes.**
Tempting — a temporary would cost ~2 ns instead of 7.8 — and refused
for v1 on two grounds. A callee's marks sit above its caller's, so a
returned value cannot be handed down and every String return would copy
unconditionally, including `splice`'s. And a per-frame scratch means a
`luce_rt_frame_enter/leave` pair on calls, which has to be suppressed
for every function with no String temporaries or it taxes programs that
hold no strings. Reuse `registerTemp`/`flushTemps`, which already exist
and already carry the temporary list as hidden locals, and revisit this
only if allocation shows up in a profile that SSO did not fix.

**Owned/borrowed as a type distinction — Rust's `String`/`&str`.** It
is the correct answer for Rust and it needs lifetimes. `strings.trim`
returning `s[first:last]` is the counterexample in our own std, and it
would need a lifetime parameter to typecheck. The Rust Book's own
verdict on the ergonomics: *"This trade-off exposes more of the
complexity of strings than is apparent in other programming
languages."* Luce is not paying that for a memcpy that costs 0.29 ns.

**Making `String` an object** — a heap type with a handle, `give`,
`copy` and `free`. It would give exact reclamation with no copies at
all, and it is the strongest alternative here. It is refused because it
stops String being a value: S32 and S37 both die, LANGUAGE.md's first
page stops being true, `xs.append(name)` starts demanding `give name`,
and every `let a = b` becomes an ownership question. That is precisely
the Rust ergonomics the project already refused, arrived at from a
different direction.

**A per-container byte pool** — one bump arena per List or Map, freed
with the container. One allocation per growth instead of per element,
which would make `split` free. Refused because overwrite and remove
cannot reclaim into a bump, so `for i in range(0, 1_000_000): m["k"] =
str(i)` grows without bound. It trades a run-lifetime leak for a
container-lifetime leak, which is smaller and still a leak.

**Interning.** Deduplicates and never frees. It is the current arena
with a hash table in front of it.

**Explicit copy at the call site — Zig's `dupe`, Odin's
`strings.clone`, Hare's `strings::dup`, Go's `strings.Clone`.** This is
what every other manual-memory language in the survey actually does,
and it is refused for one reason: Luce has already promised that values
copy on assignment, and a language that says so and then requires
`copy` on a String store is lying on its first page. Nim is the
precedent that goes the other way and it is the right one — *"The
assignment operator for strings always copies the string"*, with move
elision doing the work and no refcount on the string itself
(https://nim-lang.org/docs/manual.html,
https://nim-lang.org/docs/destructors.html). Steps 4 and 6 above are
Nim's move elision, arrived at independently.

## What is not measured, and what to check

Every number in the cost section for the *new* design is a prediction
built on measured primitives, not a measurement of the design. Four
things need checking once step 2 exists, with the prediction stated so
it can be falsified:

1. **The churn loop.** 0.5M/1M/2M/4M iterations should show constant
   RSS within noise of the 4M point of a run that allocates nothing —
   call it flat at 8–10 MB — and should cost ~25–30 ns/iteration more
   than today (three allocation/free pairs and two small copies).
2. **The editor.** 20,000 keystrokes into a 40 KB file: **under 2 MB
   peak RSS**, and per-keystroke wall time up by 4–6 µs, which is
   unmeasurable against terminal I/O.
3. **`bench/strings`.** 57 ms → **63–70 ms**, i.e. 1.73× C → 1.9–2.1×
   C. If it lands above 2.1×, the allocator is the reason and SSO is
   the fix; if it lands below 1.9×, Zig's GPA is doing better on
   12-byte requests than macOS `libmalloc` did in the table above.
4. **`matmul`, `arrays`, `stats`, `loops`, `math`.** Unchanged to three
   digits. If any of them moves, something was wired to
   `carriesObjects` that should have been wired to `ownsStorage`, and
   that is the first place to look.

The one thing that cannot be predicted from here is how often the
mutation-during-statement read rule fires on real code. The
measurement is a count of copies it inserts across `programs/`,
`bench/` and `src/luce/std/`. Prediction: zero.
