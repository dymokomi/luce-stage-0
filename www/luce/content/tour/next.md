# Where to go next

That is the language. Seventeen chapters covered every construct Luce
has: there is no hidden chapter holding back generics or traits or
async, because those are not in it.

## What you have seen

Scalars, plain structs, enums and function values that copy; four
container objects that do not. Scope-owned `file` and `task` resources
that move but cannot copy. Named functions as values, and capture-free
lambdas whose types come from where they land.
Folded file-scope values and flat immutable tables owned by each
runtime's program root.
Static types with inference and two widening ladders —
`byte` → `short` → `int` → `long` and `half` → `float` → `double` —
with any cross-ladder mix widening to `double`.
Dispatch that checks you covered every member, and unions whose
arms bind each payload field by its own name. Checked
arithmetic and bounds checks that no build mode turns off. Scope
ownership with `give`, `copy` and `free`; share-nothing workers whose
task scopes join. `T?` for absence with
narrowing and `else`. `T!` for failure with `try`, `catch` and
`error`. A file as a module and a reserved `std.` namespace, public
until a declaration says `private`. Effects as host services, gated at
compile time.

## What you have not

There are no closures, no generics for user code,
no tuples, no operator overloading, no exceptions,
no shadowing, no mutable file-scope `var`, and no `defer`. Typed
channels are the next approved design-and-implementation run: typed
pipes and ownership-moving `send(give x)` are ratified, while their
construction, capacity, receive, close and failure surface is not yet.
Some absent features are
permanent decisions with reasons written down; some are simply not built. The
[status page](/status/) says which is which, and it does not round up.

## Four directions

**Read short programs.** [Luce by example](/examples/) is complete
programs one concept at a time, each checked for its shown result —
normal output, trap, raise or refusal — plus the real userland from the
repository, including a Brainfuck interpreter and a recursive-descent
calculator.

**Go deeper on the unusual parts.** [The guides](/guide/) are the
longer pieces: why memory works this way and what it measured, the one
rule that decides trap-or-error, what strings cost, what the benchmark
table does and does not say, and how the toolchain fits together.

**Look something up.** [The reference](/ref/) is normative and terse:
the exact grammar, every operator's precedence, all 46 ownership
situations with individual anchors, every trap code, every builtin
signature. It is the document to cite.

**Read the library.** [The standard library](/std/) is nine modules —
`math`, `strings`, `files`, `lists`, `paths`, `os`, `term`, `zip`,
`json` —
written in ordinary Luce and embedded in the compiler.

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
