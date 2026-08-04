# Performance

Luce compiles through LLVM to native code, and on five of six
benchmarks it lands within a few percent of C doing the same thing.
This page is the table, what it measures, and what it does not.

## The table

`bench/run.sh`, Apple M4 Max, best of five, C at `-O3 -march=native`
against Luce `--release` under `loom run` from a warm artifact. Both
sides include process startup; the `compute` column is the same
numbers with the do-nothing floor taken off each, which is the ratio a
code-generation change moves.

| benchmark | C | Luce | Luce/C | compute |
|---|---|---|---|---|
| loops | 83.1 ms | 87.3 ms | 1.05× | 1.04× |
| math | 142.5 ms | 111.6 ms | 0.78× | **0.77×** |
| strings | 21.3 ms | 53.7 ms | 2.52× | **2.73×** |
| arrays | 44.3 ms | 47.4 ms | 1.07× | 1.06× |
| matmul | 11.1 ms | 12.0 ms | 1.08× | 1.02× |
| stats | 33.9 ms | 35.9 ms | 1.06× | 1.04× |
| *(do-nothing floor)* | 2.9 ms | 3.6 ms | — | — |

**`compute` is the column to quote.** Where anything else in the
repository names a benchmark ratio it names that column and says so,
because the two differ by as much as 0.2× on the row that matters and
picking silently between them is how one row ends up with four
numbers.

`math` is ahead of C because Luce's transcendental calls land in the
same libm C's do while the surrounding loop vectorizes.

`strings` is the one row genuinely behind, and it is
**allocation-bound rather than code-generation-bound**: the cost is
copying `String` bytes into list elements, which is the price of
giving strings an owner so memory comes back.
[Strings and copies](../strings/) is that whole story, with the phase
timings that locate the remaining cost.

## What the numbers are not

**They are not portable.** Absolute times mean nothing off that host.
For a before-and-after, the repository has `bench/compare.sh GIT-REF`,
which interleaves two builds on the machine in front of you — that is
the authoritative regression check, not this table.

**They are not a benchmark suite in the marketing sense.** Six paired
programs, each written twice with the same algorithm and cross-checked
for identical output before either is timed. A different six programs
would give different ratios.

**They are not the interpreter.** There is one engine that runs your
programs, and it is this one. Luce keeps a second implementation — an
IR interpreter — purely as the differential oracle in its own test
suite; it ships in nothing, and it was 30–60× slower than compiled
code when it did run programs.

**They are not measured against a debug build of anything.** A Zig
debug build of the toolchain is 4–5× slower and its numbers would be
meaningless. Only optimised builds are timed.

## What makes it fast

**One code generator, one runtime.** Every semantic — the object heap,
scope ownership, the four containers, string storage, checked
arithmetic, the trap channel — lives in `libluce_rt`, a real static
library behind a C ABI. Compiled code calls it, and so does the
interpreter that acts as the test suite's oracle, so there is exactly
one implementation of every rule and no second one to be slower or
subtly different.

**Effects travel in a vtable, not as undefined symbols.** Generated
code indexes a `LuceHost` table with `getelementptr`. Every service is
optional and fails closed, so a program's behaviour does not depend on
who started it.

**Safety checks are cheap where it counts.** Bounds checks and the
use-after-free check were measured free once container access is
inlined; what costs is the control dependence they create, not the
branch. That is why they are never turned off — see
[build modes](../toolchain/#the-two-build-modes).

**Debug information is inert.** Per-instruction source origins are
constant data that nothing on the execution path addresses, so a debug
build and a release build run at identical speed. All the cost of a
trap's location sits on the far side of "the program already failed".

## Compilation is not on the run path at all

A `.lc` **is** machine code, so `loom run FILE.lc` compiles nothing:
one `dlopen`, one symbol lookup, one call. Measured on `bench/matmul`,
that whole startup is 3 ms, and the program itself then runs at C's
speed.

Compiling is `luce build`'s job and happens once, when you ask for it.
`loom luce FILE.luc` still compiles — that is what it is for — and
caches the result as `FILE.lc` beside the source, keyed on **content**
rather than on a modification time, so an unchanged program is warm
and a changed one is rebuilt.

Every artifact also records the code generator that produced it.
Upgrading `luce` rebuilds rather than silently running the old
compiler's code, and a stale or foreign artifact is refused by name
instead of crashing.

## Writing Luce that is fast

Little of this is unusual, and none of it is about the language being
new.

**Use `Array` for numeric bulk.** Fixed shape, zero-initialized,
contiguous. `std.math`'s whole-array reductions accumulate left to
right and are bit-reproducible, including against the C twins.

**Use a `Builder` to accumulate text.** Repeated `+` allocates per
step.

**Prefer `get(key, default)` to `has` then index** where you can — the
latter is two hash lookups where one would do. (`m.get(k) -> V?` does
not exist yet and is on the [status page](/status/) as the better
answer.)

**Remember that slicing a list copies.** `xs[a:b]` allocates a new
list — deeply, when the elements are objects, because two containers
can never own one object.

**Do not reach for `copy` by reflex.** `copy` is a deep copy and its
cost is deliberately visible at the call site; a borrow is free.

```luce run
import std.math

func main():
    let n = 100000
    var values = new Array(Float, n)
    for i in range(0, n):
        values[i] = Float(i % 97) * 0.5

    print(f"sum {math.sum(values)}")
    print(f"mean {math.mean(values) else 0.0}")
    print(f"norm {Int(math.norm(values))}")
```

```output
sum 2399842.5
mean 23.998425
norm 8785
```
