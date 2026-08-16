# One engine, and the oracle

Luce ships **one engine**: source goes through LLVM to machine code,
and the thing loom loads *is* machine code. There is no interpreter to
select, no fallback, no `LOOM_ENGINE`, no second dispatch loop in
either binary.

The interpreter is not gone, though. It survives as the **differential
oracle in the test suite**: the second, independently written
implementation that every program in `specs/` is run on and compared
against. It ships in nothing — `luce` and `loom` do not reach it — and
its only job is to disagree. This file says why that arrangement is the
right one and what keeps it honest.

`libluce_rt` sits underneath both arms and is untouched by any of this:
it is the one implementation of every semantic, and both the compiled
path and the oracle call it. Removing one arm would change nothing
about it.

The precedent is the one every language in this class already follows:
Rust's Miri (an in-tree MIR interpreter that ships as a dev tool and
never as an engine), Zig's one behavior suite run against every
backend, Go's `toolstash -cmp`, and Wasm's reference interpreter.

## What the oracle is

`specs/agree.zig` compiles one source, runs it on the interpreter
through a `Reference` host, runs it compiled through `dlopen` against a
`Capture` host built from the *same* `World`, and demands that the two
agree on:

- the printed bytes,
- the trap code,
- the trap message,
- the call trace, frame for frame,
- the leak census, and
- the world each arm left behind — file names and bytes, keys read,
  lines read, the clock.

The transcript catches a wrong effect; the world comparison catches a
wrong *result* of one. A program that traps agrees on where; a program
that leaks agrees on what.

## Why a second implementation, and not a golden file

The interpreter has caught real bugs in the compiled path, and the
tests are named after them:

- **The null object put in a `T?` is present, because absence is not a
  handle.** A heap `T?` cannot lower to the null handle, because the
  null handle is the *zero of an object-typed place* — a value that is
  **present** — so `xs == none` answers `false` and a sentinel lowering
  would answer `true`. One program in the language distinguishes the
  two designs, and the oracle is the thing that runs it
  (docs/FAILURE.md).
- **An error path releases the objects and the string storage it
  holds.** Carrying a fallible call's result in a *borrowing* slot
  marked short text as outside text, and the statement's release freed
  a pointer into the frame (docs/STRINGS.md).
- **A store that traps still holds what it was handed** — a
  double-release the compiled arm hid behind plausible output.

All three were **silent-agreement bugs**: the compiled arm produced
plausible output, and what caught them was a second implementation
answering differently about a leak census, a trap's position, and one
boolean. A golden-output file does not have those facts unless a human
transcribes them from the semantics — which is exactly what the
interpreter does automatically, for every program, on every run.

And once the oracle was the one that was wrong: a stale-register read
the interpreter had and the compiled path did not, on a fallible call's
answer across the branch on its outcome. It took a large program
(`examples/adventure/adventure.luc`) to meet it, where a thousand small
ones never did. An oracle is only an oracle where the two arms are
written independently, and the price of that is that either one can be
the one that is wrong — which is the argument for a corpus with a large
program in it.

The alternatives were weighed and are weaker here:

- **Golden-output tests** would have caught none of the three: the leak
  census and the trace are the discriminating facts, and a golden file
  only has them if a human transcribed them.
- **Property fuzzing against `libluce_rt`'s own assertions** would have
  caught none either: `libluce_rt` was correct in all three cases. The
  lowering marshalled into it wrongly, and there is nothing for the
  runtime to assert about a value the lowering never handed it.

The reference arm is cheap: an interpreted run of a spec-sized program
is below the resolution of process startup, and inside `agree` there is
no fork at all. Deleting the interpreter would not save the test time,
because the specs run their programs compiled either way; keeping it
adds a free second opinion for a fraction of a second across the whole
suite.

## The discipline that keeps it honest

1. **It ships in nothing.** `loom` and `luce` do not reach
   `interpreter/`. The check is structural — a build-graph assertion,
   the way `otool -L build/loom` polices libLLVM.
2. **It has no product role.** There is no `Engine`, no
   `Policy.engine`, no `LOOM_ENGINE`. The only caller of
   `interpreter.run` is a test harness.
3. **It may never acquire a semantic.** `interpreter/machine.zig` keeps
   only the dispatch loop, the frame stack, the traceback, and host
   effects; it calls `runtime.zig` and nothing else goes in it. There
   is exactly one implementation of every semantic, and the specs are
   what prove it.
4. **Every spec is a comparison.** An oracle consulted by a handful of
   curated tests can drift. An oracle that is the second arm of every
   spec cannot drift silently — each one is a disagreement detector.
   The rule that follows is:

   > **Anything that runs a Luce program is a specification, and a
   > specification runs it on both engines. Anything that inspects a
   > structure is a test of that structure and lives beside the code it
   > proves.**

That rule is why the specs are their own module. The `agree` harness
needs the emitter and the libLLVM that `luce` deliberately does not
link, so the specs cannot live inside the `luce` module and still gain
a compiled arm. `src/luce/specs.zig` is the one module that imports
both `luce` and `emit`, built by `build.zig` as its own test target.
`08_llvm/test.zig` lives there too, because it runs programs.

A handful of things legitimately inspect the interpreter's own
structure rather than run a program as a specification, and they stay
beside the code they prove: `interpreter/test.zig`'s frame-storage
tests (compiled code has no frame stack of its own), and
`06_mir/module.zig`'s single-byte damage fuzz, where a mutant is not a
Luce program — no source produces it, nothing says what it should
print, and the interpreter is a **sanitizer** there rather than a
reference.

## What running a program costs

`luce build` writes machine code and calls it `.lc`; `loom run FILE.lc`
opens it and calls it — one `dlopen`, one symbol lookup, one call, with
no compiler, no C toolchain, no LLVM and nowhere to write. A **source**
file needs all four, exactly as a `.c` does, and when one is missing
loom names it — "the `luce` compiler is not beside /usr/local/bin and
not on PATH" — rather than running the program some other way. There is
nothing to fall back to, and nothing to fall back from.

Serialized MIR keeps the module format and answers to `.lcm` when it
has to reach a disk: it is the front end's hand-over to the back end
and the artifact's cache key, which is how loom gets a program compiled
without carrying a code generator. It is a seam, never a deliverable —
there is no `--emit=module`. `docs/CODEGEN.md` and `docs/PIPELINE.md`
describe the compiled path in full; `docs/MODES.md` describes debug
versus `--release`.

## What stays

**`libluce_rt` is the floor and does not move.** It is the object heap,
reference counting, `list`/`map`/`array`/`builder`, string storage and
the string primitives, checked arithmetic, and the trap channel. Both
arms call it; its own tests call it directly, through neither engine.

The **memory model** is orthogonal to any of this: values copy and references
share under ARC (`docs/MEMORY.md`). Both engines run the same retain/release
semantics and every successful differential specification requires a zero
live-object census.
