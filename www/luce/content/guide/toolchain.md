# The compiler and the terminal

Two binaries, three artifacts, two build modes. This page is how they
fit together.

## luce, the compiler

```
luce build FILE [-o OUT] [--release] [--emit=WHAT]
luce check FILE
luce ir FILE [--full]
```

`FILE` may be a `.luc` source file **or** a `.lcm` module — the same
program either way, taken up from where it was left. A `.lcm` is the
front end's hand-over to the back end, not something to ship; that is
how `loom` gets a program compiled without carrying a code generator,
by running this binary over the module it already has.

The current `.lcm` format is **34**. Format 33 introduced the
program-root constant-container pool, its load instruction and
`immutable_object`; 34 appends `ownership_cycle`. The earlier
`call_inout` edge used by writing methods first moved it to 32. The
published host ABI is **13** and did not move: none of these features
added a host service.

Current version pair: `format_version = 34`; `abi.version = 13`.

`FILE` may also be `-`, to read the program from standard input.
Imports then resolve beside the current directory, and `build` needs
`-o` to say where to write.

### The three artifacts

`--emit` says which shape `build` writes, and it is the **only** thing
that differs between them. The same program walks the same pipeline in
every case.

| `--emit` | Writes | What it is |
|---|---|---|
| `library` (default) | `FILE.lc` | A native artifact loom loads and calls |
| `object` | `FILE.o` | A relocatable object; you link it |
| `exe` | `FILE` | A standalone native executable |

All three go through LLVM and are stamped with the machine, the host
ABI and the code generator they were built for, so a loader refuses
the wrong one by name rather than crashing. Linking uses `cc`;
`LUCE_CC` names another driver and `LUCE_LIB` the directory holding
`libluce_rt.a`.

```sh
build/luce build examples/hello/hello.luc --emit=exe -o hello
./hello you        # needs neither loom nor a runtime beside it
```

### The `.lc` artifact

**A `.lc` is machine code.** It is a shared library the platform
loader opens, holding the compiled program and a copy of the runtime
library it calls, plus one exported tag saying what it is: a magic
number, the tag's own layout version, the host ABI version, the
machine, a content hash of the program, whether it kept its trap
origins, and the identity of the code generator that wrote it.

`loom run FILE.lc` is one `dlopen`, one symbol lookup and one call —
no compiler, no C toolchain and no LLVM have to be installed. The tag
is read first, so a file built for another machine, against another
host ABI, or by another code generator is refused with a sentence
saying which:

```
loom: cannot run old.lc: it was built by a different code generator
```

There is no migration and no compatibility mode. An artifact that is
refused is rebuilt from source, which is one `luce build` away.

A `.lc` is therefore **not portable**, and the tag is what makes that
safe: a file that cannot run here says so instead of crashing.
Compiling for another machine — `--target`, one `libluce_rt` per
target — is not built yet.

## loom, the terminal

```
loom                        the interactive shell
loom run PROGRAM.lc [ARGS]  run a compiled program
loom luce PROGRAM.luc [..]  compile a source file and run it
loom edit FILE              open the Luce editor
loom PROGRAM.lc [ARGS]      shorthand for run
```

`loom` is the trusted boundary that implements the host services —
console, files and the terminal. Command-line arguments are instead
handed to `main` as its owned parameter. The host owns raw mode, the
alternate screen, frame buffering and every escape byte, and it
sanitizes `term_write` text so a Luce program can never emit a control
sequence.

**The exit status says how the program stopped**, and a standalone
`--emit=exe` binary answers with the same numbers, because both take
them from the same place:

| status | what happened |
| --- | --- |
| `0` | the program finished |
| `1` | the program trapped |
| `3` | an error reached the top uncaught |
| `70` | the runtime ran out of memory |
| `71` | it could not be run, or its output could not be written |

A trap and an uncaught error are two different sentences about a
program, so they are two different numbers: a script can tell them
apart without reading stderr. loom's own refusals — no such file, a
compile that failed — are `1`, and say so before anything of the
program has run. A `.luc` or `.lc` path piped into `loom` on standard
input returns the worst status any line produced; the interactive
shell always leaves with `0`, because you watched every failure go
past.

**loom carries no code generator.** Building is `luce`'s job, so loom
runs that binary — found beside its own executable first, then on
`PATH` — and links nothing itself. libLLVM is 164 MB and the dynamic
loader binds it before `main`, which cost every `loom` invocation
5.7 ms for nothing; loom now starts in 3 ms against a C do-nothing
binary's 2.4. It also means **a machine that only runs Luce programs
needs no LLVM installed at all**.

## One engine

There is no engine selection, because there is one engine. `loom run
FILE.lc` calls machine code and `loom luce FILE.luc` compiles first —
caching the result as `FILE.lc` beside the source, keyed on the
program's bytes, so an unchanged program is warm and a changed one is
rebuilt.

A `.luc` therefore needs a compiler, exactly as a `.c` does, and a
loom that cannot find one says so rather than doing something slower
and quieter:

```
loom: cannot compile sums.luc: the `luce` compiler is not beside /opt/luce and not on PATH
```

A `.lc` needs nothing at all.

There is still a second implementation of the language — a Luce IR
interpreter — and it ships in nothing. It is the differential oracle
in the compiler's test suite, where every program in the executable
specification runs on both it and the compiled path and the two are
compared on printed bytes, trap code, trap message, call trace frame
for frame, leak census and the world each left behind. That is the
same arrangement Rust has with Miri and Zig with one behaviour suite
run against every backend: an implementation that exists to disagree,
not to run your programs.

## The two build modes

Luce has exactly two, and they differ in **one thing only**: what a
trap can tell you.

```sh
luce build dice.luc              # debug, the default
luce build dice.luc --release    # stripped
```

A debug artifact carries origins — for every instruction, the line and
column of the statement it came from, plus the source file name per
function. A trap prints the location and the whole call stack:

```
loom: trap: division by zero [divide_by_zero]
    at divide (crash.luc:5:5)
    at ratio (crash.luc:8:5)
    at main (crash.luc:12:5)
```

A release artifact has the tables stripped. Traps still carry their
stable code, message and function names — names are structure, not
debug information — but no lines:

```
loom: trap: division by zero [divide_by_zero]
    at divide
    at ratio
    at main
```

**Semantics never change between modes.** This is the deliberate
departure from Zig, whose `ReleaseFast` turns integer overflow into
undefined behaviour. Luce refuses the trade: checked arithmetic,
bounds checks, UTF-8 boundary checks and ownership traps are the
*language*, not a mode. A program traps on the same instruction with
the same stable code in both modes, so there is no "works in debug,
corrupts in release" class of bug and release needs no separate
testing story. In Zig's terms Luce is always `ReleaseSafe`, and
`--release` is closer to `-fstrip`.

**Debug and release run at identical speed.** The lesson taken from
Zig is *where* the cost of debug information lives. Generated code
never reads origins — not a load, not a branch — because they are
constant data nothing on the execution path addresses. It has no frame
stack to walk either, so it builds the trace *as it unwinds*, each
frame recording where it was on the way out. All the cost is on the
far side of "the program already failed."

So: `--release` gives up trap locations and buys very little back. An
artifact is mostly the runtime library it carries, so stripping the
origin tables takes 2% off `editor.lc` and nothing measurable off a
small program. Ship it when source lines would mean nothing to the
recipient; ship debug everywhere else.

Deep recursion is capped: a trace keeps the innermost 64 frames and
counts the rest, so a `call_depth_exceeded` report stays readable.

## Diagnostics

Compile-time diagnostics are unaffected by the mode. They carry stable
codes and byte spans and render as `file:line:column` always — modes
are about *runtime* reporting.

Codes are namespaced by the stage that raised them: `luce.source.*`
for what is not text at all, `luce.lex.*`, `luce.parse.*`,
`luce.sema.*`, `luce.import.*`. Ownership diagnostics also quote the
numbered situation they enforce, so a message points at the exact
clause in [the ownership specification](/ref/ownership/).

```luce fail
func main():
    var rows = new list(list(long))
    var item: list(long) = [1]
    rows.append(item)
```

```output
luce: compile failed
main.luc:4:17: a container keeps its owned elements; write give item to hand it over, or copy item to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        rows.append(item)
                    ^~~~
```

## How this site is built

The same discipline, applied to documentation. `www/luce/build.sh` builds
the toolchain, then a small generator in `www/luce/src/` walks the
Markdown in `www/luce/content/`. Every fenced Luce block on the site must
say what is to become of it — `run`, `trap`, `raise`, `fail` or
`module` — and a bare one is a build error naming the page and the
line. There is no unverified Luce here by construction.

For each sample the generator writes the files to a scratch directory.
`run`, `trap` and `raise` samples compile with the freshly built `luce`
and execute with the freshly built `loom`; `fail` samples go through
`luce check`, while `module` fences supply another sample's source or
data. Every claimed output or diagnostic is compared byte for byte, and
a mismatch fails the build.

Some samples do not carry their own source at all: the
[bundled programs](/examples/programs/) are included from
`examples/*/*.luc` in the repository, so if one of them changes, the
page changes with it or the build stops.

Finally every generated page is walked for links, and every `href`
must resolve to a file in the output tree with the anchor it names.

That is the whole build. It takes a few seconds and keeps the samples,
claimed outcomes and navigation tied to the compiler actually in the
repository. The prose around those checked facts remains a review
responsibility.
