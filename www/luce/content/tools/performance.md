# Performance

Luce programs compile to native code through LLVM. The useful performance
question is not whether a language is “fast”; it is whether a particular
program completes representative work within its latency, throughput, and
memory budget. Measure that program before changing it.

## A dated compiler snapshot

This snapshot was recorded on 2026-08-16. `bench/run.sh` on an Apple M4 Max,
best of five, compares C at `-O3 -march=native` with a Luce `--release`
artifact run by `loom`. Both include process startup. `compute` subtracts the
do-nothing startup floor and is the useful column when a compiler change is
being evaluated.

| benchmark | C | Luce | Luce/C | compute |
|---|---:|---:|---:|---:|
| loops | 80.1 ms | 90.8 ms | 1.13× | 1.05× |
| math | 137.7 ms | 115.4 ms | 0.84× | 0.78× |
| strings | 19.7 ms | 75.4 ms | 3.82× | 3.87× |
| arrays | 43.3 ms | 53.2 ms | 1.23× | 1.07× |
| arrays32 | 7.8 ms | 48.7 ms | 6.26× | 7.77× |
| matmul | 10.5 ms | 17.6 ms | 1.68× | 1.02× |
| matmul32 | 6.5 ms | 13.4 ms | 2.05× | 0.99× |
| stats | 32.2 ms | 49.0 ms | 1.52× | 1.34× |
| lists | 8.0 ms | 23.3 ms | 2.93× | 2.61× |

The harness first compares every Luce program's output with its C twin and
refuses to time different results. It interleaves runs and keeps the best of
five so one implementation is not systematically measured before the other.
Absolute times move with the operating system, compiler, temperature, and
workload. This table locates current costs; it does not predict an unrelated
application.

## Measure your program

Build the artifact you intend to ship, choose an input representative of real
work, and time the complete operation:

```text
luce build report.luc --release
time ./report data.json
```

Run it several times. Record the Luce version, machine, operating system,
input, build command, and result. If startup is a large fraction of the run,
measure a larger batch or report startup and steady work separately rather
than subtracting a guessed constant.

For a compiler change, compare two revisions on the same host with the same
input. The repository's `bench/compare.sh GIT-REF` does this for the maintained
benchmark set. For an application, a small repeatable script that verifies
output before timing is more valuable than a single impressive number.

## Build text with a builder

`+` creates a new `str` value. In a loop, repeated concatenation therefore
copies the text accumulated so far on each iteration. A `builder` grows one
buffer and returns a `str` at the end:

```luce run
func main():
    var out = builder()
    for i in range(0, 4):
        if i > 0:
            out.append(",")
        out.append(str(i))
    print(out.build())
```

```output
0,1,2,3
```

Text is a value. Keep large text in one clear owner, use a builder for
incremental construction, and avoid reshaping the same prefix repeatedly.
Do not replace a readable expression merely because it allocates once; find a
measured repeated cost first.

## Choose storage from the work

`array[T, _]` stores a fixed-shape sequence whose extent is chosen at
construction. It is the natural input to `std.math` reductions and avoids
list growth when the size is known. `list[T]` is the flexible choice when
elements are added or removed. Neither choice changes checked bounds or
arithmetic.

Choose the narrowest numeric type that represents the domain, but do not
assume a smaller width is automatically faster. Checked integer operations
remain checked at every width, and vectorization depends on the whole loop.
The `arrays32` row is deliberately a warning: storage width, overflow
semantics, and current optimizer support all matter.

## Make allocation visible

Lists, maps, arrays, builders, classes, closures, and interface values are ARC
managed. Passing a reference is cheap and does not copy its contents; growing
a container, taking a list slice, building a string, or repeatedly creating a
closure may allocate. Value structures copy their fields and retain any
references they contain.

Start with the data model that makes sharing clear. In a hot path, look for
repeated growth, short-lived large containers, text concatenation in a loop,
or an algorithm that scans the same data several times. Reusing a sensible
buffer or changing the algorithm is usually a more durable improvement than
trying to avoid every retain.

## Separate computation from host work

File, terminal, process, window, clock, and random-host interactions can
dominate a small computation and vary for reasons outside the compiler. If
the question is parser speed, read the input before the timed region. If the
question is end-to-end latency, include the I/O and say so. Both measurements
are useful when they answer different named questions.

Use `--release` when measuring a shipped artifact. Debug and release have the
same semantics; release removes source locations from runtime traps. Warm up
or discard startup consistently, run enough repetitions to see the noise
floor, and keep comparison implementations identical. A faster result that
changes the input or omits error checking is not a comparison.

Luce does not currently ship a language-specific profiler. Native executables
can be observed with the platform's ordinary sampling and tracing tools. Read
their hottest call paths together with allocation behavior and input shape;
do not optimize from a source line merely because it looks low-level.

## What the table does not promise

The snapshot is not a language-wide ranking or a guarantee about a different
CPU, input, allocation pattern, or I/O system. Luce keeps checked arithmetic,
bounds checks, UTF-8 boundaries, and memory-safety checks in every build mode.
Those are semantics, not optimizations a release build may remove.

Performance work is complete only when behavior tests remain green and a
same-host measurement improves the workload that motivated the change. For
representation rules behind copies and ARC, see [Memory and
ARC](/guide/memory/). For artifact modes, see [The luce and loom
Commands](/tools/command-line/).
