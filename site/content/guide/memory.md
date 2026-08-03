# Memory without a collector

Luce reclaims memory deterministically, with no garbage collector and
**no reference counting anywhere** — not in the language, not in the
runtime, not hidden behind a copy-on-write bit. That is a permanent
rule rather than a stage the implementation is passing through.

This page is why, what it costs, and what was measured.

## The model, in one paragraph

The binding that received a fresh object owns it, and the owning scope
frees it: at the end of the block, at an early `return`/`break`/
`continue`/`try`, and immediately on reassignment. An unnamed
temporary lives exactly as long as the statement that made it. `let y
= x` is an alias, tracked by nothing. Keeping a *named* object —
storing it in a container or struct, or handing it to a parameter that
says `give` — takes a word from you, `give` (transfer) or `copy`
(duplicate). `return` moves. `free(x)` is an early release. Values —
`Int`, `Float`, `Bool`, `String`, and object-free structs — never take
a word at all.

That is the whole thing. It is ratified as
[43 numbered situations](/ref/ownership/), the compiler quotes their
numbers in its diagnostics, and an executable specification in the
repository runs every one of them.

## The five candidates, and why this one

The decision memo weighed five options and recorded why each lost.

**Manual `free` with leak reports** was what Luce had. Safe and
honest, and the single biggest source of friction in real programs:
every early return is a leak, so you write single-exit contortions.
Nobody's endgame.

**`defer` on top of manual `free`** — Zig's answer. A tiny addition,
and still a line of ceremony per object, still forgettable, and it
does not compose with returning an object, since you have to cancel
the `defer` by hand.

**Full static borrow checking** — Rust's answer. Compile-time
guarantees and zero runtime cost, at the price of lifetimes and
aliasing rules, which are the opposite of the ease Luce is aiming at,
and an enormous amount of compiler. Explicitly ruled out.

**Reference counting** — Swift's and CPython's answer. The best pure
ergonomics of the five: objects die when the last reference goes, and
there is no syntax at all. It loses on three counts. Cycles leak
unless you add weak references, which is a second concept and a
footgun. Every assignment becomes a read-modify-write, which is a tax
on exactly the code that should be fastest. And it makes the death
point of an object unknowable from the source, which is the property
scope ownership exists to keep.

**Scope ownership plus `give`** won. `free` disappears from
essentially all code while drop points stay readable from the source;
leak reports become structurally impossible rather than usually empty;
the `give` keyword makes a transfer of ownership visible at both ends;
and the dynamic checks mean no borrow checker, no lifetimes, and no
fight with the compiler.

One fact made every option cheaper than usual: the runtime already
tracks every object and traps on dead references. Luce can afford
*dynamic* enforcement of rules other languages must prove statically.

## What it costs

Two things surface at run time rather than at compile time.

An **alias that outlives its owner** traps `use_after_free` at the
point of use. That is the accepted price of having no borrow checker,
and the trap is deterministic and names the faulting line.

**Giving away an object a container already owns**, reached through an
alias, traps `not_owned`. It is the one dynamic ownership check; the
direct case is caught statically by poisoning.

Neither can be turned off. There is no build mode that omits them —
`--release` strips source locations from traps and nothing else.

## Object identity survives a reused row

The promise the `use_after_free` trap makes is about the *object*, not
about the storage it sat in. A handle is `{index, generation}`, and a
freed row goes on a free list, so the object table grows to a
program's peak object count rather than to the number of objects it
ever made. A stale handle's generation is not the row's, so it traps
identically whether or not something else has since moved in — and it
never reads the newcomer. Generations do not wrap: a row that runs out
of them is retired rather than reused, because a one-in-four-billion
aliasing hole is not a price this trap pays.

Measured on a loop making and freeing one list per iteration, peak
resident memory went from **281 MB to 21.2 MB at one million
iterations, and 593 MB to 21.3 MB at four million** — flat where it
had been linear.

## Values give memory back too

The harder half was values, and in particular `String`. A `String`'s
bytes used to live in a run-lifetime arena and were never reclaimed,
so a program that built and discarded text grew without bound even
though it retained nothing.

What fixed it is the language's own claim made literal: **values
copy**. A `String`'s bytes and a struct's field run have exactly one
owner, and any store into something that outlives the current
statement copies them, so no owner ever holds a view of bytes it did
not allocate.

The same churn loop — one string built and discarded per iteration,
retaining nothing — measured on the interpreter:

| iterations | 0.5M | 1M | 2M | 4M |
|---|---|---|---|---|
| before | 15.5 MB | 29.4 MB | 59.9 MB | 121.0 MB |
| after | **1.8 MB** | **1.8 MB** | **1.9 MB** | **1.8 MB** |

Flat, and flat all the way out: 8M and 16M iterations sit at the same
figure, so thirty-two times the work is the same footprint. On the
compiled path the number is 20.4 MB and equally flat — that is the
system allocator's working set for a hot allocate-and-free loop, not
anything Luce is holding.

The flagship program was the worked example and is now the proof.
`programs/editor.luc` splices its lines as
`value[0:cursor] + extra + value[cursor:len(value)]`, and twenty
thousand keystrokes into a 40 KB file used to peak at **1204 MB**. The
same simulation now peaks at **3.3 MB**, and costs 24 µs a keystroke
instead of 9 — three orders of magnitude inside a 16 ms frame either
way.

That is the trade this model makes, stated plainly: copying where
counting would have been cheaper in one benchmark, in exchange for a
program that can run all day. [Strings and copies](../strings/) has
the rest of that story, including the row it cost.

## What you actually write

```luce run
struct Report:
    title: String
    lines: List(String)

func build(title: String, count: Int) -> Report:
    var lines: List(String) = []
    for i in range(0, count):
        lines.append(f"line {i}")
    return Report(title = title, lines = give lines)

func summarise(report: Report) -> String:
    return f"{report.title}: {len(report.lines)} lines"

func main():
    var report = build("first", 3)
    print(summarise(report))

    var archive = new List(Report)
    archive.append(give report)
    archive.append(build("second", 5))

    for entry in archive:
        print(summarise(entry))
    # main's scope ends: the archive, its reports, and their lists all go
```

```output
first: 3 lines
first: 3 lines
second: 5 lines
```

Two words in a whole program that builds, moves and stores nested
objects, and no `free` at all. That ratio is the point of the model.

## Deliberately excluded

- **Shared ownership** (`share`, opt-in reference-counted islands) —
  refused permanently, not deferred. A program that needs genuinely
  shared ownership restructures, or uses indices into a container it
  owns.
- **Weak references** — only meaningful once shared ownership exists,
  so never.
- **Arenas as a language feature** — the runtime may use them as an
  invisible optimisation; you cannot ask for one.
- **`defer`** — superseded by scope ownership for memory. It may
  return one day for host cleanup, as a separate decision.
- **`errdefer`** — refused, with reasons. The one bit it encodes is
  already a parameter of the unwinder.
