# Performance

Luce compiles through LLVM to native code, and on six of nine
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
| loops | 82.2 ms | 87.2 ms | 1.06× | 1.06× |
| math | 139.1 ms | 110.2 ms | 0.79× | **0.78×** |
| strings | 21.7 ms | 52.6 ms | 2.43× | **2.67×** |
| arrays | 44.3 ms | 47.6 ms | 1.07× | 1.06× |
| arrays32 | 8.1 ms | 43.4 ms | 5.38× | **8.66×** |
| matmul | 10.9 ms | 12.0 ms | 1.10× | 1.05× |
| matmul32 | 7.0 ms | 7.8 ms | 1.12× | 1.05× |
| stats | 32.8 ms | 35.0 ms | 1.07× | 1.05× |
| lists | 8.7 ms | 17.5 ms | 2.03× | **2.60×** |
| *(do-nothing floor)* | 3.5 ms | 4.2 ms | — | — |

**`compute` is the column to quote.** Where anything else in the
repository names a benchmark ratio it names that column and says so,
because the two differ by as much as 0.2× on the row that matters and
picking silently between them is how one row ends up with four
numbers.

`math` is ahead of C because Luce's transcendental calls land in the
same libm C's do while the surrounding loop vectorizes.

Three rows are behind, and they are behind for three different
reasons.

`strings` is **allocation-bound rather than code-generation-bound**:
the cost is copying `string` bytes so that text has an owner and
memory comes back. [Strings and copies](../strings/) is that whole
story, with the phase timings that locate the remaining cost.

`arrays32` is the price of **checked integer arithmetic in a
reduction**. Every `+` carries an overflow test, so the sum cannot be
reassociated and the loop stays one element per iteration; C's
`int32_t` addition is free to wrap, so it fills four lanes. The ratio
is worse than the `double` twin's precisely because C got faster, not
because Luce got slower — 41.8 ms against 41.1 ms at the two widths.

`lists` is `append`, and only `append`. Reading a list is the bounds
check and the load it is, so a sequential read, a strided walk and an
in-place transform all measure at C's speed; appending has to keep the
list's length in the object's row, because the row is what every other
name for that list reads, where C keeps its count in a register.

## What the numbers are not

**They are not portable.** Absolute times mean nothing off that host.
For a before-and-after, the repository has `bench/compare.sh GIT-REF`,
which interleaves two builds on the machine in front of you — that is
the authoritative regression check, not this table.

**They are not a benchmark suite in the marketing sense.** Nine paired
programs, each written twice with the same algorithm and cross-checked
for identical output before either is timed. A different nine programs
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
scope ownership, the four containers, file/task resources and workers,
string storage, checked arithmetic, the trap channel — lives in
`libluce_rt`, a real static
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

**Use `array` for numeric bulk.** Fixed shape, zero-initialized,
contiguous. `std.math`'s whole-array reductions accumulate left to
right and are bit-reproducible, including against the C twins.

**Use a `builder` to accumulate text.** Repeated `+` allocates per
step.

**Prefer `get(key, default)` to `has` then index** where you can — the
latter is two hash lookups where one would do. (`m.get(k) -> V?` does
not exist yet and is on the [status page](/status/) as the better
answer.)

**Count with `counts[key] += 1`.** A compound store defines a missing
key at the value type's zero, so the first-sighting arm and the
`get(key, 0)` that used to stand in for it are both gone, and the hit
path is two hash lookups rather than three.

**Remember that slicing a list copies.** `xs[a:b]` allocates a new
list — deeply, when the elements are resource-free objects, because
two containers can never own one object. If the element type carries
`file` or `task`, slicing normally is refused: only equal compile-time
`long` bounds are admitted, because they prove a zero-element result and
execute no deep copies.

**Do not reach for `copy` by reflex.** For a resource-free object graph,
`copy` is a deep copy and its cost is deliberately visible at the call
site; a borrow is free. A graph carrying `file` or `task` moves with
`give` and cannot be copied.

```luce run
import std.math

func main():
    let n = 100000
    var values = new array(double, n)
    for i in range(0, n):
        values[i] = double(i % 97) * 0.5

    print(f"sum {math.sum(values)}")
    print(f"mean {math.mean(values) else 0.0}")
    print(f"norm {long(trunc(math.norm(values)))}")
```

```output
sum 2399842.5
mean 23.998425
norm 8785
```
