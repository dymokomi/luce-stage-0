# Performance

Luce programs are compiled to native code through LLVM. The right way to
reason about speed is to measure the program you care about; the table below
is a reproducible snapshot, not a promise for every machine.

## The current snapshot

`bench/run.sh` on an Apple M4 Max, best of five, compares C at
`-O3 -march=native` with a Luce `--release` artifact run by `loom`. Both
include process startup. `compute` subtracts the do-nothing startup floor and
is the useful column when a compiler change is being evaluated.

| benchmark | C | Luce | Luce/C | compute |
|---|---:|---:|---:|---:|
| loops | 80.5 ms | 84.1 ms | 1.05× | 1.04× |
| math | 138.8 ms | 109.2 ms | 0.79× | 0.78× |
| strings | 19.9 ms | 50.0 ms | 2.51× | 2.75× |
| arrays | 43.5 ms | 46.9 ms | 1.08× | 1.07× |
| arrays32 | 8.0 ms | 42.8 ms | 5.39× | 7.92× |
| matmul | 10.4 ms | 11.7 ms | 1.12× | 1.07× |
| matmul32 | 6.7 ms | 7.7 ms | 1.15× | 1.09× |
| stats | 32.4 ms | 42.5 ms | 1.31× | 1.32× |
| lists | 8.1 ms | 16.7 ms | 2.05× | 2.53× |

The numbers move with the operating system, compiler, and workload. The
benchmark sources and measurement script are in the repository's `bench/`
directory; use the [status page](/status/) for the current project-level
summary.

## Choices that matter

### Build text with a builder

`+` creates a new `str` value. In a loop, repeated concatenation therefore
copies the text accumulated so far on each iteration. A `builder` grows one
buffer and returns a `str` at the end:

```luce run
func main():
    var out = new builder
    for i in range(0, 4):
        if i > 0:
            out.append(",")
        out.append(str(i))
    print(out.build())
```

```output
0,1,2,3
```

`str` values are values, so putting one into a container copies the value.
That makes lifetime predictable; it also makes copying a large value a real
cost. Keep large text in one owner, use a `builder` for construction, and
measure before changing an algorithm. [Strings and copies](/guide/strings/)
explains the trade-off.

### Keep numeric storage in arrays

`array[T, _]` stores a fixed-shape sequence whose extent is chosen at
construction. It is the
natural input to `std.math` reductions and avoids list growth when the size
is known. `list[T]` is the flexible choice when elements are added or
removed. Neither choice changes the language's checked bounds and arithmetic
rules.

### Check the work, not just the artifact

Use `--release` when measuring a shipped artifact. Debug and release have the
same semantics and generated code does not execute its source-location
tables; release mainly removes trap locations. Warm up or discard startup
time consistently, run enough repetitions to see the noise floor, and keep
the C comparison identical. A faster result that changes the input or omits
error checking is not a useful comparison.

## What the table does not promise

The table is not a language-wide ranking and it is not a guarantee about
I/O, allocation patterns, or a different CPU. Luce keeps checked arithmetic,
bounds checks, UTF-8 boundaries, and memory-safety checks in every build mode.
Those are semantics, not optimisations a release build may remove. When a
hot loop is slower, first make its data shape and allocation behavior clear,
then profile and measure the smallest change that addresses it.
