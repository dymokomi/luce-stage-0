# Where to go next

That is the language. Thirteen chapters covered every construct Luce
has: there is no chapter fourteen holding back generics or traits or
async, because those are not in it.

## What you have seen

Scalars, structs and enums that copy; four heap objects that do not.
Static types with inference, and one widening: `long` into `double`.
Dispatch that checks you covered every member. Checked
arithmetic and bounds checks that no build mode turns off. Scope
ownership with `give`, `copy` and `free`. `T?` for absence with
narrowing and `else`. `T!` for failure with `try`, `catch` and
`error`. A file as a module and a reserved `std.` namespace, public
until a declaration says `private`. Effects as host services, gated at
compile time.

## What you have not

There are no first-class functions or closures, no generics for user
code, no tagged unions — an [enum](/tour/enums/) has names and numbers
and no payloads — no tuples, no operator overloading, no exceptions,
no shadowing, no mutable file-scope `var`, and no `defer`. Some of those are permanent
decisions with reasons written down; some are simply not built. The
[status page](/status/) says which is which, and it does not round up.

## Four directions

**Read short programs.** [Luce by example](/examples/) is complete
programs one concept at a time, each compiled and run to produce the
output shown — plus the real userland from the repository, including
a Brainfuck interpreter and a recursive-descent calculator.

**Go deeper on the unusual parts.** [The guides](/guide/) are the
longer pieces: why memory works this way and what it measured, the one
rule that decides trap-or-error, what strings cost, what the benchmark
table does and does not say, and how the toolchain fits together.

**Look something up.** [The reference](/ref/) is normative and terse:
the exact grammar, every operator's precedence, all 45 ownership
situations with individual anchors, every trap code, every builtin
signature. It is the document to cite.

**Read the library.** [The standard library](/std/) is six modules —
`math`, `strings`, `files`, `paths`, `os` — written in ordinary Luce
and embedded in the compiler.

## Writing something real

```sh
build/loom luce program.luc
```

is the whole loop while you are working. When it is finished:

```sh
build/luce build program.luc --emit=exe -o program
./program
```

writes a standalone native binary that needs neither `loom` nor a
runtime library beside it, and runs at the speed
[the benchmarks report](/guide/performance/).
