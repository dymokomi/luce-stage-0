# Luce

**Good for humans. Good for computers.**

Luce is a small statically typed language that looks like Python, runs
at the speed of C, and gives memory back without a garbage collector
and without reference counting anywhere.

```luce run args=world
func main(args: list(string)):
    var greeting = "hello"
    if len(args) > 0:
        greeting = greeting + ", " + args[0]
    print(greeting)

    var counts = new map(string, long)
    for word in ["fig", "pear", "fig"]:
        counts[word] += 1
    for word, seen in counts:
        print(f"{word} appeared {seen} time(s)")
```

```output
hello, world
fig appeared 2 time(s)
pear appeared 1 time(s)
```

That program was compiled and run to produce the output above it when
this page was built. So was every other
sample on this site — see [how that works](/guide/toolchain/#how-this-site-is-built).

## Three things that are unusual

**Memory is scope-owned.** The binding that received a fresh object
owns it, and the owning scope frees it. There is no collector, no
reference counting at any layer, and no `malloc`/`free` bookkeeping in
ordinary code. Four words — `give`, `copy`, `free`, `new` — cover
everything the compiler cannot see for itself, and a string-churn loop
that used to grow without bound now sits flat at about 1.8 MB.
[The memory model](/guide/memory/).

**Compiled code is at C's speed.** Against C twins built with
`-O3 -march=native`, the same algorithms measure 0.78× to 1.06× on six
of the nine benchmarks — loops, math, arrays, both matrix multiplies
and statistics. Three are not there, and each says why: string
processing at 2.67× is allocation-bound, lists at 2.60× is `append`
alone, and a 32-bit integer reduction at 8.66× is the price of
checking every add.
[The numbers, and what they do not say](/guide/performance/).

**Failure has three shapes, and they do not overlap.** A `T?` says
something might not be there. A `T!` says a call might not succeed,
handled with `try` or `catch`. Everything else is a trap, which is a
bug: it reports a stable code, `file:line:column`, and a call trace,
and it does that from the machine code you ship. The rule that decides
between them is one sentence — *traps are bugs, errors are news*.
[Absence and failure](/guide/failure/).

## What Luce is not

It is a real language with a real compiler, a real runtime, a real
terminal and a real editor written in itself — and it is early. There
are no closures, no generics for user code, no tagged unions, no
tuples, no package manager
and no language server. Some of those are deliberate and permanent;
some are simply not built yet. The
[status page](/status/) says which is which, without rounding up.

## Start here
