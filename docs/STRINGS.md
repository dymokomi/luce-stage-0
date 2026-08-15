# String storage: values copy, literally

> **Spellings, since this was decided.**  The builtin type names are
> lowercase (`long`, `double`, `string`, `list`, `map`, `array`,
> `builder` — docs/TYPES.md D8), and the two numeric types became four:
> `int` and `float` are 32 bits and are what a literal takes with
> nothing to tell it otherwise, `long` and `double` are the 64-bit
> types this memo calls `Int` and `Float`.

> **The rule.** A string is a value. Storing it into anything that
> outlives the current statement — a binding, a container element, a
> struct field, a map key — copies the bytes, so no place ever holds a
> view of bytes it did not allocate. The one store that does not copy
> is the one where the statement hands over its own freshly-made bytes
> and keeps nothing: the allocation moves rather than being duplicated
> (step 6).

`docs/MEMORY.md` records the memory model — values copy, reference
types are shared and reference-counted. This memo is how string values
are stored. It was `docs/MISSING.md` Tier 0 item 1, second bullet.

**A note on the measurement tables.** Rows labelled *interpreter* are
the reference implementation the test suite compares against — the
differential oracle, which ships in nothing (`docs/ENGINE.md`). They
are here because a second implementation of the same semantics is a
second reading of the same experiment, and because several of these
steps were taken while it was still an engine. The row that describes
what anybody runs is always the compiled one.

Two findings below name `07_optimize/values.zig`, which no longer
exists: it was block-local value numbering written for the dispatch
loop, and it went with the retirement (`docs/ENGINE.md` step 7). Both
findings survive it — `struct_make`, `str`, `chr` and String `+` are
still `impure` in `07_optimize/effects.zig`, and the store-to-load
forwarding that had to stop at owning slots is now a private fact
`07_optimize/ownership.zig` computes for itself.

> **Steps 2, 3, 5 and 6 shipped.** Owned String bytes, copy-on-store
> across every store site, owned struct field runs, the
> mutation-during-statement read rule, small-string optimisation — a
> String of twenty-two bytes or fewer lives inside the `Value` holding
> it and costs no allocation at all — and now move-instead-of-copy: a
> store that is handed this statement's own fresh value takes its
> allocation instead of duplicating it. What actually landed, what it
> measured, and where the design met the code are in **What shipped**,
> **What SSO shipped** and **What move-instead-of-copy shipped** at the
> foot of this document. Step 4 is still queued.

Nothing in the language changes. No trap, no diagnostic, no change to
the leak census. Every decision in the memory model holds; the memory
model restated for values is below. A program cannot observe the
difference except in RSS — which is the test, and which is what makes
this an implementation decision rather than a model change.

## What is wrong

`runtime/heap.zig:45-62` splits a run's memory in two. Object storage
goes to a freeing allocator. **Values — String bytes and struct field
runs — go to `Memory.arena`, a `std.heap.ArenaAllocator` created per
run in `loom/runner.zig:489` and dropped whole at the end.** Nothing
between those two moments gives a byte back.

`runtime/value.zig` says it plainly: *"Nothing here owns memory. String
and struct payloads are views into the program's constants or into the
runtime arena, and they stay valid for the whole run — a value is a
view, never a handle to free."*

Measured consequences, both in MISSING.md:

- A loop building and discarding one string per iteration, retaining
  nothing: **28 / 36 / 54 / 90 MB RSS at 0.5M / 1M / 2M / 4M
  iterations.** Dead linear, ~18 bytes an iteration, forever.
- `examples/editor/editor.luc` peaks at **976 MB after 20,000 keystrokes into
  a 40 KB file** — 49 KB retained per keystroke. `Editing.splice` is
  `value[0:cursor] + extra + value[cursor:len(value)]`, two concats
  into the arena, and `Handle.key` then does four to six `struct_set`s,
  (`Handle`'s four functions are `struct State`'s `var self` methods
  now — docs/METHODS.md — and every measurement below names the code
  as it stood when it was taken, which is the only honest way to
  record one)
  each of which allocates a fresh eight-field run (`heap.zig:693`) that
  is also never reclaimed. The strings dominate; the runs are tens of
  megabytes on their own.

Every program with a main loop has this shape. It is the difference
between a memory *footprint* and a memory *lifetime*.

## Why regions failed, and why they stop failing

MEMORY.md's objection to a per-statement scratch arena was not the
relief it gives (33% mid-file, 50% at end of file — still linear). It
was correctness: *"resetting would dangle every view already stored,
because containers, struct fields, `s[a:b]` and `m[k]` all hold views
of bytes they did not allocate. Whether a string escapes cannot be
decided at the producer, because the producer is usually a view into
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
| 1 | local binding, and reassignment | `local_set` (+ `object_bind`) | shares bytes | copies; the scope frees, a reassignment frees the old |
| 2 | list append | `.append_value` → `containers.append` | shares | copies |
| 3 | list insert | `.insert_value` → `containers.insert` | shares | copies |
| 4 | list / array element store | `.index_set` → `containers.indexSet` | shares | copies, frees the old |
| 5 | map value store | `.index_set` | shares | copies, frees the old |
| 6 | map **key** store | `.index_set` → `Map.insert` | shares | copies, freed with the entry |
| 7 | list literal element | lowers to `.append_value` (`builder.zig:1790-1815`) | — | as (2) |
| 8 | struct construction | `struct_make` → `Runtime.makeStruct` | shares run *and* bytes | copies both |
| 9 | struct field assignment | `struct_set` → `Runtime.setField` | fresh run, shared bytes | copies both |
| 10 | function return | `ret` | shares | copies, or moves a local this frame produced |
| 11 | `xs[a:b]` on `List(String)` | `containers.listSlice` → `deepCopy` | shares (`heap.zig:959`) | copies |
| 12 | `m.keys()` | `containers.mapKeys` | shares | copies |
| 13 | `m.values()` | `containers.mapValues` → `deepCopy` | shares | copies |
| 14 | a deep copy of a string-bearing object | `Runtime.deepCopy` | shares | copies |
| 15 | Builder append | `containers.append` → `ArrayList.appendSlice` | **already copies** into the Builder's own buffer | unchanged |
| 16 | `key_text` | `luce_rt_set_key_text` | already copies — into the arena | copies into one owned slot, frees the old |
| 17 | host text in (`file_read`, `arg`) | `luce_rt_intern_text` | copies into the arena | copies into an owned temporary |
| 18 | trap message | `Runtime.failMessage` | arena | at most one per run; a run ends on a trap |
| 19 | `Array(String)` zero fill | `Runtime.newArray` | the static `""` | static, no owner |
| 20 | `catch NAME:` binding | `Runtime.raise` already copied the words into the arena; `error_message` views them out | arena | copies into the binding's owned slot, which its scope frees |

Rows 11–14 are the ones easiest to miss: `deepCopy`'s `else => return
held` arm passes a String through by pointer, so a deep copy of a
`list(string)` today produces a second container holding the first's
bytes. Under the rule it duplicates them.

**With that list, the theorem holds.** No owned storage contains a
pointer it did not allocate; every allocation therefore has exactly one
death point, and the churn loop and the editor both go flat.

### The one residual hazard

A *register* can hold a view into container or field bytes across a
mutation of that container, inside one statement:

```text
f(pieces[0], drop_first(pieces))    # drop_first calls pieces.remove(0)
```

`pieces[0]` yields a view into the list's element cell; `remove` frees
that element's bytes; the first argument now dangles. Today this is
safe only because element bytes are arena-lived. A string has no handle
and no generation, so unlike a reference type's stale handle this
cannot be turned into a trap.

It closes statically, and cheaply: a read out of a container or field
materialises a copy when the same statement also contains a call that
could mutate the source. `07_optimize/effects.zig` already answers
"can this instruction free an object or change who owns one"
(`ownershipTransparent`), which is the same question one type wider.
The conservative version — copy whenever a container read is live
across any impure call in the statement — is what should ship, and it
should ship *with* the core change, not after it. Prediction to check:
it fires on zero lines of `examples/` and `src/luce/std/`.

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

400,000 iterations of `b.append("item-"); b.append(String(i));
b.append(";")`, then split / count / upper / replace over the ~4.69 MB
result. Currently **1.73× C**.

- 400,000 `String(i)` temporaries: each becomes one allocation and one
  free instead of an unreclaimed bump. **~3.1 ms.**
- Builder appends already copy into the Builder's own buffer
  (`containers.append`). Unchanged.
- `let text = b.build()` — one extra 4.7 MB copy. **50 µs.**
- `text.split(";")` — 400,001 pieces, each an `s[at:word_end]` view
  appended into a `list(string)`. Every one becomes an owned
  allocation: **~3.1 ms**, plus 400,000 twelve-byte copies at 0.29 ns,
  which is 0.1 ms and beneath notice.
- `upper` and `replace` return `out.build()` — one fresh buffer each,
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
matmul.luc:25:  print(String(Int(checksum)))
arrays.luc:22:  print(String(Int(dot)))
loops.luc:10:   print(String(total))
stats.luc:25:   print(f"{Int(math.sum(a))} {low} {high} {Int(checksum)}")
math.luc:23:    print(String(inside))
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
`length` yield a 15-byte threshold, which is libstdc++'s and Swift's.

Either threshold covers what this corpus actually stores: split pieces
(~11 bytes), `String(Int)` results (≤20), wordcount's English map keys
(~5). **Take 22 if the tag demotion is clean; 15 is enough.** fbstring
draws the same line at 23 in-situ
(https://github.com/facebook/folly/blob/main/folly/docs/FBString.md).

Two costs, both honest:

- Reading a String *out of storage* into a register becomes two
  selects, not one load — but only there. Once the register holds
  `{ptr, len}`, `len`, `byte_at` and `s[a:b]` are as they are today, so
  `find`'s inner loop over a parameter is untouched.
- An inline string's bytes live in the cell, so a `{ptr, len}` derived
  from one points into container memory that moves on `append`. The
  fix is to materialise inline reads into a statement temporary — a
  ≤22-byte copy at 0.29 ns — which keeps the register form uniform and
  removes the hazard rather than documenting it.

It costs an `abi.version` bump and a `.lc` `format_version` bump. Both
are cheap: an artifact already carries a tag and is refused by name
when foreign, and modules recompile from source. Because of that ABI
cost and because the core change is worth shipping without it, SSO goes
last — after the measurement that says how much of the predicted
1.9–2.1× it recovers.

## `s[a:b]` on a String

It is a **view today, on both engines**, and it stays one.
`text.slice` returns `Value.ofString(text[start..end])` — pointer
arithmetic into the original bytes — and `08_llvm/lower.zig`'s
`emitStringSlice` is a bounds check, two UTF-8 boundary checks, and a
`getelementptr`. No allocation on either path. It is a value with no
ownership verbs; at the low level it is a view into the same bytes.

`docs/LANGUAGE.md:137` already says the right thing and needs no
change: *"Slices copy: `xs[a:b]` allocates a new list — deeply, when
elements are reference types…; `s[a:b]` on a String stays a value."*
What changes is not the slice, it is what happens when you
keep one. `pieces.append(s[at:word_end])` copies at the append. That is
`strings.split`'s whole cost, and it is the difference between Luce and
Go, which shipped `strings.Clone` in 1.18 precisely because a
50-byte substring pins its 1 MB parent
(https://pkg.go.dev/strings#Clone).

## Function returns

`src/luce/std/strings.luc` settles this by itself:

```text
func trim(s: string) -> string:
    ...
    return s[first:last]        # a view of a parameter

func replace(s: string, old: string, replacement: string) -> string:
    if len(old) == 0:
        return s                # the parameter itself
```

`fold_case` does the same. A string-returning function may hand back a
view of a parameter, a view of a constant, or freshly-made bytes, and
Luce has no annotation that distinguishes them. Rust does distinguish
them, and pays for it with lifetimes — `Cow<'a, B>` is the escape hatch
and `'a` is the price. Luce does not have lifetimes and will not add
them.

So **`ret` copies** — except where the returned register is provably
the frame's own: a statement temporary, or a local this frame produced
being moved. `emitScopeReleases(from, moved)` already takes exactly
that `moved` parameter, so `Editing.splice`'s concat result moves out
with no copy and `strings.trim`'s slice is copied out. Both decisions
are static.

There is no rule against returning a view of a parameter for strings,
because a string return copies. `trim`, `replace` and `fold_case` are
all legal.

## The memory model, restated for values

Everything the memory model says stays true. A string is a value, and
the value rules already imply this memo's outcome:

- **A store copies.** `x.append(i)` appends a copy of the value; `i`
  dying each iteration is irrelevant, because values are copied.
  `var names: list(string) = []` / `names.append("ada")` is the same
  story — a string is a value.
- **A temporary dies at the end of its statement** — precisely, at the
  end of the outermost statement containing the expression that made
  it. That is the death point every fresh string's storage rides on.
- **Values take no verbs.** There is nothing to hand over or release on
  a string; assignment and passing copy it.

Three things the value model now makes concrete, all of them already
implied:

1. **A value's storage is reclaimed by the runtime, not the program.**
   The program never frees a value; the runtime reclaims a value's
   storage when the place holding it — a binding, a container element,
   a struct field, a map key — dies.

2. **A string return copies** rather than erroring. There is no rule
   against returning a view of a parameter for strings, because the
   return copies.

3. **A struct copy copies its value fields and shares its reference
   fields.** Reference fields alias; value fields — strings and nested
   plain structs — copy, so a struct copy is O(bytes of its value
   fields).

Nothing can leak: value storage now has a death point exactly as
reference-type storage does. An element overwrite frees the old
element, and a deep copy duplicates the object and everything it holds
— both were under-implemented for value storage, not mis-specified.

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
  `luce_rt_unbind` at scope exit — the same pair reference types
  already carry, and `07_optimize/ownership.zig` already deletes the
  dead ones.
- `ret` of a view gains one runtime call. A function returning a
  fresh string gains nothing.

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
   only*. It must not be wired to any verb rule: `xs.append(name)` on a
   string takes no verb, because a string is a value that copies.
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

`Bytes` would have got the same treatment mechanically. `08_llvm` does
not lower it, and it has no producer in the language today.

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
   editor's remaining tens of megabytes and makes the struct-copy rule
   true for value fields.
4. **Destructive `struct_set`** when the source register is dead after
   it. Pure optimisation, provable from MIR liveness, no semantic
   change. Takes the editor from ~10× today's copy traffic to ~3×.
5. **Small-string optimisation.** ABI 6, format 13. Shipped; see
   **What SSO shipped**.
6. **Move-instead-of-copy for statically fresh stores.** `xs.append(a +
   b)` and `next.content = Editing.splice(…)` hand over the temporary's
   allocation instead of duplicating it. Removes one 40 KB copy per
   keystroke and the `let text = b.build()` copy. Pure optimisation.
   Shipped; see **What move-instead-of-copy shipped**.

## Refused, with reasons

**Reference counting an individual string value.** Luce reference-counts
its reference types, but a string is a value that copies, not a
reference-counted object — and reference-counting a string value would
be a second memory manager underneath the value model. What is being
given up is real and should be written down: under counting,
`var next = state` is O(1) instead of O(40 KB), `split` allocates once
per piece with no copy, and `return s` is free. Swift proves it works.
It also measures: 32% of execution time on average, 25 points of it the
atomics alone, on a runtime where over 99% of objects are thread-private
and the compiler still cannot prove it (PACT'18). Luce has no threads,
so a counter on a string would be non-atomic and cheaper than Swift's —
and it would still be a second manager over a type the value model
already reclaims exactly.

**Copy-on-write.** A shared/unique bit is a reference count with one
bit of range, and reference-counting a string value fails for the same
reason. It also has the worst measured record of anything in this memo:
Sutter's harness put atomic
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

**Owned/viewed as a type distinction — Rust's `String`/`&str`.** It
is the correct answer for Rust and it needs lifetimes. `strings.trim`
returning `s[first:last]` is the counterexample in our own std, and it
would need a lifetime parameter to typecheck. The Rust Book's own
verdict on the ergonomics: *"This trade-off exposes more of the
complexity of strings than is apparent in other programming
languages."* Luce is not paying that for a memcpy that costs 0.29 ns.

**Making `string` a reference type** — a reference-counted object
instead of a value. It would yield exact reclamation with no copies at
all, and it is the strongest alternative here. It is refused because it
stops string being a value: the value rules die, LANGUAGE.md's first
page stops being true, and every `let a = b` becomes a question of
sharing rather than a copy. A string is a value by design; making it a
reference-counted object is a memory manager the value model does not
need for it.

**A per-container byte pool** — one bump arena per List or Map, freed
with the container. One allocation per growth instead of per element,
which would make `split` free. Refused because overwrite and remove
cannot reclaim into a bump, so `for i in range(0, 1_000_000): m["k"] =
String(i)` grows without bound. It trades a run-lifetime leak for a
container-lifetime leak, which is smaller and still a leak.

**Interning.** Deduplicates and never frees. It is the current arena
with a hash table in front of it.

**Explicit copy at the call site — Zig's `dupe`, Odin's
`strings.clone`, Hare's `strings::dup`, Go's `strings.Clone`.** This is
what every other manual-memory language in the survey actually does,
and it is refused for one reason: Luce has already promised that values
copy on assignment, and a language that says so and then requires an
explicit clone at a string store is lying on its first page. Nim is the
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
measurement is a count of copies it inserts across `examples/`,
`bench/` and `src/luce/std/`. Prediction: zero.

## What shipped

Steps 2 and 3, whole, in one change. `.lc` `format_version` 11 → 12;
`abi.version` unchanged, because nothing about the boxed `Value`
moved. 795 tests green, `zig fmt --check` clean.

### The measurements

Against the base commit, on this host (Apple M4 Max, `--release`, warm
artifact, `/usr/bin/time -l`):

| churn loop, one string built and discarded per iteration | 0.5M | 1M | 2M | 4M |
|---|---|---|---|---|
| before, compiled path | 20.3 MB | 29.6 MB | 60.0 MB | 121.0 MB |
| **after, compiled path** | **20.4 MB** | **20.2 MB** | **20.4 MB** | **20.4 MB** |
| before, interpreter | 15.5 MB | 29.4 MB | 59.9 MB | 121.0 MB |
| **after, interpreter** | **1.8 MB** | **1.8 MB** | **1.9 MB** | **1.8 MB** |

Flat, and flat all the way out: 8M and 16M iterations are 20.4 MB too,
so 32× the work is the same footprint. The compiled path's 20 MB is
`libmalloc`'s working set for a hot allocate-and-free loop, not
anything Luce is holding — the interpreter, which draws on Zig's
general-purpose allocator, sits at the 1.8 MB do-nothing floor.

**The editor**, `examples/editor/editor.luc` verbatim with its interactive
`main` replaced by 20,000 keystrokes played into a 40 KB buffer through
the same `Handle.key` / `Handle.adjust` path: **1204.2 MB → 3.3 MB**
peak RSS, same output. Wall time 0.18 s → 0.48 s for the 20,000
strokes, i.e. 9 µs → 24 µs a keystroke — the memo predicted +4–6 µs and
it is +15, three orders of magnitude inside a frame either way.

`bench/compare.sh`, interleaved A/B on this host:

| benchmark | base | head | delta |
|---|---|---|---|
| loops | 82.5ms | 81.7ms | −1.0% |
| math | 105.9ms | 105.9ms | +0.0% |
| **strings** | 45.5ms | 65.9ms | **+44.8%** |
| arrays | 45.6ms | 45.6ms | −0.2% |
| matmul | 11.3ms | 11.4ms | +0.8% |
| stats | 38.5ms | 38.6ms | +0.4% |

**The parity benchmarks are untouched**, exactly as predicted — five
rows inside 1%. `strings` is the whole cost, and it is allocation:
400,000 `String(i)` results and 400,001 split pieces that used to be
unreclaimed bump allocations and views are now 800,000
allocate-and-free pairs. The average piece is 11.7 bytes and every
`String(i)` is at most 7, so **small-string optimisation removes
essentially all of it**, which is why step 5 is next.

**The mutation-during-statement rule fires on zero lines** of
`examples/`, `bench/` and `src/luce/std/` — the memo's prediction,
checked by counting the copies it inserts across the whole corpus. It
does fire on the memo's own example, `f(pieces[0], drop_first(pieces))`,
which is in the spec suite.

### Where the design met the code

Five things the memo did not have quite right, all found by running it:

1. **Two intrinsics, not none.** The memo expected `object_bind` to
   carry the copy and `object_unbind` the release. `bind` cannot: a
   statement temporary holding a *fresh* value must take ownership
   without copying, or the original leaks, and a temporary of an
   object-carrying struct needs the bind for its objects while needing
   no copy for its run — so one instruction cannot mean both. The copy
   and the release are `own_storage` and `drop_storage`, two entries in
   the intrinsic list; the `Instruction` union is the 23 tags it was.
   `drop_storage` answers the *emptied* value, which the caller stores
   back, and that is what makes releasing a place twice free nothing.

2. **`mir.Local` carries `owns_storage`.** A parameter views its
   caller's bytes and a block-split spill views whatever it carries
   across the branch; a binding and a temporary own theirs. Both
   engines read the flag for two things: a slot that owns storage
   starts *empty* rather than at the shared per-layout zero, and a trap
   that unwound past every release still gives the storage back —
   the interpreter sweeps the frames it left standing, and every frame
   sweeps its own slots as it pops. Value storage is not in the census,
   so unlike reference types there is nothing to preserve by leaving it.

3. **A fresh value has an identity, so it cannot be CSE'd.**
   `07_optimize/values.zig` folded two identical `struct_make`s
   together — correct while a struct run was arena-lived and shared,
   and a double free the moment the run has an owner. `struct_make`,
   `struct_set`, `str`, `chr` and String `+` are `impure` in
   `07_optimize/effects.zig` now, for the same reason `heap_new` always
   was. `dead.zig` keeps a `local_set` into an owning slot for the
   matching reason: the sweep reads that slot, and no block mentions it.

4. **`str` always allocates.** `String(s)` of a String and `b.build()` of a
   Bool used to answer a view and a static. A producer that sometimes
   allocates and sometimes answers a view cannot be told apart at its
   use site, and the whole rule turns on being able to.

5. **A `for` name over a container is a view, and the body can
   invalidate it.** `for s in items:` with `items[0] = ...` in the body
   frees the bytes `s` is looking at — a reference type's handle would
   go stale and trap, a String has none. The name takes a copy per
   iteration exactly when the body could free something a container
   holds, and keeps the view when it provably could not, which is
   what keeps `for piece in pieces:` free. Same static question as the
   residual hazard, one scope wider.

Two smaller ones. An `Array(String)` element store no longer writes
inline in compiled code — `08_llvm`'s `ownsNothing` is scalars only
now, because a String element owns its bytes; reads stay inline, since
reading an element is a view. And `Memory.arena` survives, holding
what a program cannot grow without bound: a trap's words, the
per-layout struct zero templates, and host text on its
way into owned storage.

### What is still open

`luce_rt_close` on a **compiled** artifact that trapped does not
reclaim the storage its frames were holding. The interpreter walks its
frame stack; generated code has no frame stack to walk, and the trace
it records on the way out names functions, not slots. The run ends
either way and the leak is bounded by the live set at the trap, but it
is a real gap and the fix is to emit the drops on each frame's
unwinding edge — the same place `luce_rt_unwound` is already called.
Still open after SSO, and smaller than it was: a frame's short strings
are in its slots and go with them.

## What SSO shipped

Step 5, whole. `.lc` `format_version` 12 → 13; `abi.version` 5 → 6,
because generated code reads a `Value` differently even though no field
moved. 812 tests green, `zig fmt --check` clean.

**The threshold is 22, and the tag demotion was clean.** `Tag` is
`enum(u8)`, `inline_length` is the byte after it, and offsets 2 through
23 — `inline_head` plus `bits` plus `length` — are the one contiguous
run inline text lives in. `@sizeOf(Value)` is 24 before and 24 after,
`@alignOf` is 8 before and after, and **`bits` and `length` did not
move**: they are still at 8 and 16, so an object handle is the same
word in the same place and `generation_shift` never came into it. The
form byte says which: `text_outside` (255) when `bits` addresses the
text, a count from 0 to 22 when the text is in the slot. Nothing in the
runtime switches on a new tag, so `Tag`'s eight values are the eight
they were.

### The measurements

`bench/compare.sh`, interleaved A/B on this host (Apple M4 Max), against
the commit this started from:

| benchmark | base | head | delta |
|---|---|---|---|
| loops | 85.4ms | 83.5ms | −2.2% |
| math | 108.9ms | 107.4ms | −1.3% |
| **strings** | 68.2ms | 52.0ms | **−23.8%** |
| arrays | 46.4ms | 46.4ms | −0.0% |
| matmul | 11.7ms | 11.7ms | +0.4% |
| stats | 33.8ms | 34.2ms | +1.2% |

`bench/strings` compute ratio **3.61× C → 2.88× C**. And the honest
comparison, the same A/B against `957a3b0` — the commit *before*
copy-on-store, whose ratio was the 2.35–2.51× the regression was
measured from:

| benchmark | pre-copy-on-store | head | delta |
|---|---|---|---|
| **strings** | 49.8ms | 55.5ms | **+11.6%** |
| loops, math, arrays, matmul, stats | — | — | within ±0.5% |

**So SSO took back roughly three quarters of the regression, not all of
it**, and the memo's prediction that it "removes essentially all" was
too strong. Timing the benchmark in phases says exactly where the rest
is, and it is not allocation:

| phase | pre-copy-on-store | head |
|---|---|---|
| build 400,000 pieces with a Builder, `b.build()` | 18ms | **18ms** |
| + `split(";")` and sum the pieces | 27ms | 30ms |
| + `count`, `upper`, `replace` | 46ms | 51ms |

The build phase — 400,000 `String(i)` results, which is where 400,000 of
the 800,000 allocations were — is **recovered exactly**, to the
millisecond. What remains is in `split` and the fold, and it is the
*copying* copy-on-store introduced: `pieces.append(s[run:at])` used to
store a view and now duplicates twelve bytes into the element cell,
400,001 times. That is the design's own trade, made deliberately
(*"the copy is free and the allocation is not"*), and the memo's
estimate of it — 0.1 ms, "beneath notice" — was the number that was
wrong, by about thirty times. Removing it would need step 6, not a
larger threshold. [Since retracted — see "Where the design met the
code" below: the copy is the view's one necessary copy, it measures
1.3 ms rather than the ~3 ms this table attributed to it, and step 6
could not have removed it.]

The parity benchmarks did not move.

### Memory

The churn loop — one string built and discarded per iteration, nothing
retained — is flat and slightly *below* where copy-on-store left it,
because a loop whose strings all fit inline now calls the allocator
zero times rather than in a matched pair:

| iterations | 0.5M | 1M | 2M | 4M | 8M |
|---|---|---|---|---|---|
| compiled | 1.9 MB | 1.9 MB | 1.9 MB | 1.9 MB | 1.9 MB |
| interpreter | 1.8 MB | 1.8 MB | 1.8 MB | 1.8 MB | 1.8 MB |

The editor simulation — `examples/editor/editor.luc` verbatim with its
interactive `main` replaced by 20,000 keystrokes played into a 40 KB
buffer through the same `Handle.adjust` / `Handle.key` path — is
**3.5 MB compiled and 5.3 MB on the interpreter**, against 3.0 MB and
7.3 MB before. Flat either way, and the difference is allocator working
set, not retention.

One correction to the earlier table while we are here: its compiled
column (20.4 MB, and the editor's 3.3 MB) was measured on a cold
artifact, so it included `luce`'s own LLVM run in the same process.
Warm, the figure was always ~2 MB. Measure a compiled artifact twice.

### Where the design met the code

Six things the SSO section did not have quite right.

1. **A String register cannot leave the frame that made it, so `ret`
   needed a third storage intrinsic.** The memo treated SSO as a change
   to *reads*. It is, but the read throws away *which form* the text
   was in: unbox a String and you have `{ptr, i64}`, and if the text was
   inline that pointer is into a frame slot. `ret` hands it to the
   caller, whose frame outlives it. So `export_storage` joins
   `own_storage` and `drop_storage`: it answers a value whose storage
   outlives the frame — copying inline text out to an allocation,
   passing everything already independent through untouched. It costs
   the caller no allocation it was not already paying, because in every
   case the value it replaces had allocated one.

2. **A slot that owns its storage holds a whole `Value`, not the
   register shape.** Same reason, one scope smaller: `own_storage`
   answers a value that may be inline, and a `{ptr, i64}` slot could
   only record a pointer into the runtime's answer scratch. Locals that
   *view* — every parameter, every block-split spill — keep the two
   words they had, which is what keeps `find`'s inner loop over a
   String parameter exactly as it was.

   Errors arrived after this and had to honour it. A fallible call's
   result crosses the branch on its outcome through a hidden slot
   (docs/FAILURE.md), and that slot is *not* a viewing spill: it is
   the slot that owns the value, so the form survives the crossing.
   Carrying it in a viewing one instead marked inline text as
   outside text, and the release at the end of the statement freed a
   pointer into the frame — the same failure this rule exists to
   prevent, met from a direction that did not exist when it was
   written.

3. **The backend has to remember which box a register came from.** Two
   intrinsics ask *which form* rather than merely reading the bytes:
   `drop_storage`, which frees, and `export_storage`, which decides
   between a transfer and a copy. Both take the place the register was
   read out of — a frame slot, an array cell, a struct's field run, the
   scratch a runtime call answered into — rather than a box rebuilt
   from the register, which would say "outside" over inline bytes and
   ask the runtime to free a pointer into the stack. Every *other*
   runtime call reads through the pointer, so an outside box over inline
   bytes tells it the truth and nothing else changed. A text register
   with no place behind it is refused rather than guessed at.

4. **Store-to-load forwarding had to stop at slots that own storage.**
   `07_optimize/values.zig` made `local_get %L` after `local_set %L, rV`
   answer `rV`. That was true while a slot held what was stored into it.
   It no longer is: the slot holds an owned copy, and for text the
   runtime picks the form, so the register and the slot are two
   different things and the release needs the slot.

5. **A slice of inline text is a copy, and has to be.** `text.slice`
   answered `Value.ofString(text[a..b])` — a view of its argument,
   which is a *copy of the caller's value* when the text is inline, so
   the view pointed at a parameter about to go. The source is at most
   twenty-two bytes, so any part of it fits inline too: the fix is a
   copy that allocates nothing. This is the one place where the two
   engines take visibly different routes to the same answer — the
   compiled path slices in registers, since its source is already a
   `{ptr, i64}` — and the boundary tests are what say they agree.

6. **`ret` is not the only way out of a frame — a trap's words leave
   too.** Rule 1 named `ret` and stopped there, and for two years that
   was the whole list. It was not: `trap("not a number: " + text)` hands
   its String to the trap channel, which stored the *view* on the
   argument that a trap unwinds past every release, so nothing gives the
   bytes back before the report is read. True, and beside the point —
   the words were never freed, the **frame** they lived in ended, and a
   frame ending is not a release. Short text has no allocation at all;
   it is the frame slot. The report is read once the whole run has
   stopped, so the sentence printed was whatever later stack traffic had
   left in the abandoned slot, and the program only looked correct when
   nothing had run in between (GitHub #28). The answer is not a fourth
   storage intrinsic at the trap site: the interpreter had the same hole
   and had patched it with a copy of its own, and `workers.adoptTrap` a
   third. One channel, one copy — `heap.failMessage` owns its words the
   way `raise` does, taken while the trapping frame is still standing,
   and the three hand-copies are gone. A trap is a run's last act, so
   the `dupe` is once per run.

Two smaller ones. `String(Int)` and `chr` now *never* allocate: twenty
digits and a sign is the longest an `i64` gets and a codepoint is four
bytes, so both always fit. And `Value.asString` takes a pointer
receiver, which is not decoration — it is the compiler refusing to let
anyone read inline text out of a temporary.

## What move-instead-of-copy shipped

Step 6, whole. `.lc` `format_version` 14 → 15, because the store
intrinsics mean something different; `abi.version` unchanged, because
nothing about `LuceHost` moved. 834 tests green, `zig fmt --check`
clean.

**The change is where the copy is written.** Before this, one decision
had two mechanisms. A binding and a `ret` took their copy through
`own_storage`, an instruction the compiler could see and elide; a list
element, a map value, a struct field and a struct's construction took
theirs *inside* `libluce_rt`, where nothing could. Only the first half
could ever move. Now there is one mechanism:

> **A store site keeps what it is handed.** `luce_rt_append`,
> `luce_rt_insert`, `luce_rt_index_set`, `luce_rt_struct_make` and
> `luce_rt_struct_set` consume the value they store — including on the
> trap, so nothing the caller handed over is ever left without an
> owner — and `own_storage` stands in the IR in front of them wherever
> the source is a view.

A map's **key** is the one exception and stays a view the map copies
for itself: a store looks its key up before it keeps one, and an entry
that already exists must not pay for a copy it will throw away.
`m[k] = v` in a loop allocates for the value and nothing for the key.

A Builder's `append` is not a store. It copies bytes into a buffer of
its own and the text stays the caller's, which is what it always did.

### How freshness and deadness are proved

Both were already in hand; step 6 is what joins them.

**Fresh** is `producesFreshStorage`, which SSO left behind: it reads
the *instruction* that made the register, not the expression, so the
set of producers is closed — String `+`, `struct_make`, `struct_set`, a
call, and the intrinsics that allocate (`str`, `chr`, `pop`, `copy`,
the host services, and `own_storage` itself). Everything else that
answers text answers a view.

**Dead** is the park. Stage 4 already puts every fresh value in a
hidden slot whose release ends the statement (`registerTemp` /
`flushTemps`), so "will anything else hand this back?" is answered by
looking for that park — and taking the storage is *retracting* it.
`takeStorage` clears the slot's `owns_storage`: the statement's release
goes with it, the trap sweep skips it, and `07_optimize/dead.zig`
deletes the store into it because nothing reads it any more. No
liveness analysis was needed, and none would have been better: stage 4
knows which slot a value was parked in, and by the time MIR exists that
slot's release is indistinguishable from a binding's.

Two parks are kept rather than retracted, and both are correctness:

- **A slot that is read back cannot stop owning its storage.** A
  viewing slot hands a reload the register shape, and a String's form
  does not survive that — the reload comes back saying "outside" over
  bytes that are in the frame. That is exactly the slot a fallible
  call's result crosses its branch in (rule 2 of the SSO section), so a
  `try`'s or `catch`'s value is copied into a store, not moved.
- **A temporary that also owns objects keeps its slot**, because that
  ownership is settled at run time by `object_bind` and the release
  still has to load the slot to ask. Mixing the two questions in one
  slot buys a copy of a field run and risks the other.

The backend needed one thing: a store now keeps the value it is given,
so the value has to arrive in the form its place must hold. Every
adopted argument goes through `storageOf` — the box the register was
read out of — the same way `drop_storage` and `export_storage` already
did, and `struct_make` fills its field run by copying whole boxes
across rather than rebuilding them. That is sound because an adopted
argument is always either an `own_storage` result or a fresh producer,
and both answer into scratch that nothing else can move.

### The measurements

`bench/compare.sh 4ec770a`, interleaved A/B on this host (Apple M4
Max):

| benchmark | base | head | delta |
|---|---|---|---|
| loops | 92.8ms | 93.2ms | +0.4% |
| math | 117.8ms | 120.0ms | +1.8% |
| **strings** | 56.6ms | 54.5ms | **−3.8%** |
| arrays | 50.7ms | 50.1ms | −1.1% |
| matmul | 12.9ms | 12.7ms | −1.0% |
| stats | 38.9ms | 38.5ms | −1.0% |

`bench/strings` compute ratio **2.71× C → 2.68× C**. The parity
benchmarks did not move; three earlier runs of the same A/B put
`strings` at −3.3% to −3.8% and every other row inside ±1.8%.

**The editor is where it pays.** `examples/editor/editor.luc` verbatim with
its interactive `main` replaced by 20,000 keystrokes played into a
40 KB buffer through the same `Handle.adjust` / `Handle.key` path,
same output both ways:

| | base | head |
|---|---|---|
| compiled, 20,000 strokes | 536.7 ms | **399.8 ms** (−25.5%) |
| per keystroke | 26.7 µs | **19.8 µs** |
| peak RSS | 4.12 MB | **3.64 MB** |
| interpreter | 22.81 s | 22.39 s |
| interpreter peak RSS | 6.31 MB | 6.11 MB |

The churn loop — one long string built per iteration and stored into a
list and a map, nothing retained — is 21.0% faster at 2M iterations
(851.3 ms → 672.7 ms) and still flat:

| iterations | 0.5M | 1M | 2M | 4M | 8M |
|---|---|---|---|---|---|
| compiled | 1.7 MB | 1.8 MB | 1.8 MB | 1.8 MB | 1.9 MB |
| interpreter | 2.0 MB | 2.0 MB | 2.0 MB | 2.1 MB | 2.2 MB |

Counted across `examples/` and `bench/`, the corpus emits **185
`own_storage` copies before and 101 after** — 45% of every copy site in
userland is gone. `editor.luc` alone goes from 59 to 36.

### Where the design met the code

**The memo's localisation of the `bench/strings` gap was wrong, and
this is the measurement that says so.** The SSO section concluded that
what remained after small-string optimisation was "the *copying*
copy-on-store introduced: `pieces.append(s[run:at])` … duplicates
twelve bytes into the element cell, 400,001 times", and that "removing
it would need step 6".

Step 6 cannot remove it. `s[run:at]` is a **view of the text being
split**, not a fresh value — there is no allocation to hand over, and a
store that kept the view would put a pointer to somebody else's bytes
in the list. It is the one copy the whole design exists to make. The
prediction that step 6 would close that gap could not have been right
for any implementation of step 6.

And the copy is smaller than the memo made it. Neutralising it in the
runtime (storing an empty inline value instead, purely to time it)
moves the split-and-fold phase from **28.7 ms to 27.4 ms**: the 400,001
element copies cost **1.3 ms**, not the ~3 ms the phase table attributed
to them. The rest of that phase's regression is elsewhere and is still
unaccounted for.

So `strings` moved 3.3%, not the several points the memo implied, and
what step 6 actually removed there is the four multi-megabyte copies
`let text = b.build()`, `return out.build()` inside `upper` and `replace`,
and the two bindings that receive them. **The editor's 25% is the real
result**, and it is the one the memo predicted for the right reason.

Three smaller things the design did not have quite right:

1. **`rebuild` stopped needing `drop_storage` at all.** A nested place
   assignment built a chain of `struct_set`s and released each
   intermediate, because the next step copied out of it. Under adopt
   each step *moves* what the step below built, so the releases were
   not an optimisation to remove but a double free waiting to happen —
   they had to go with the same change.

2. **`zeroOf` has to say which of its fields are views.** `var x: Point`
   builds each field's zero and hands them to `struct_make`. A nested
   struct's zero is its own fresh run and moves in; a String's zero is
   `const_data ""`, a view of a program constant, and needs the copy.
   This is the one store site whose decision is made in `06_mir`, where
   `producesFreshStorage` is not in reach — and it is decidable from
   the field's type alone, which is why it can be.

3. **Returning an owned local still copies.** `return kept`, where
   `kept` is a `var` this frame owns, is a `local_get` and therefore not
   fresh, so `ret` copies and the scope release then frees the original.
   The `moved` parameter already suppresses exactly this for reference
   types; doing it for storage means proving the local is not read again
   after the `return`, which is a liveness question rather than a
   freshness one.
   Left for step 4, which needs the same machinery.
