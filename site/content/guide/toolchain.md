# The compiler and the terminal

Two binaries, four artifacts, two engines, two build modes. This page
is how they fit together.

## luce, the compiler

```
luce build FILE [-o OUT] [--release] [--emit=WHAT]
luce check FILE
luce ir FILE [--full]
```

`FILE` may be a `.luc` source file **or** a `.lc` module — the same
program either way, taken up from where it was left. That is how
`loom` gets a program compiled without carrying a code generator: it
runs this binary over the module it already has.

`FILE` may also be `-`, to read the program from standard input.
Imports then resolve beside the current directory, and `build` needs
`-o` to say where to write.

### The four artifacts

`--emit` says which artifact `build` writes, and it is the **only**
thing that differs between them. The same program walks the same
pipeline in every case.

| `--emit` | Writes | What it is |
|---|---|---|
| `module` (default) | `FILE.lc` | Portable serialized IR; the interpreter runs it |
| `object` | `FILE.o` | A relocatable object; you link it |
| `library` | `FILE.lcn` | A native artifact loom loads directly |
| `exe` | `FILE` | A standalone native executable |

The last three go through LLVM and are stamped with the machine and
the host ABI they were built for, so a loader refuses the wrong one by
name rather than crashing. Linking uses `cc`; `LUCE_CC` names another
driver and `LUCE_LIB` the directory holding `libluce_rt.a`.

```sh
build/luce build programs/hello.luc --emit=exe -o hello
./hello you        # needs neither loom nor a runtime beside it
```

### The `.lc` format

A direct binary serialization of the verified intermediate
representation: a magic number and version, constants, structs,
functions, ports, entry. Decoding re-runs the IR verifier, so damaged
modules are rejected — but instruction *types* beyond the verifier are
trusted. Treat a `.lc` like an executable, not like data.

Any change to the instruction set, the intrinsics or the trap codes
bumps the format version. There is no migration: modules recompile
from source.

## loom, the terminal

```
loom                        the interactive shell
loom run PROGRAM.lc [ARGS]  run a compiled program
loom run PROGRAM.lcn [..]   run a native artifact directly
loom luce PROGRAM.luc [..]  compile a source file and run it
loom edit FILE              open the Luce editor
loom PROGRAM.lc [ARGS]      shorthand for run
```

`loom` is the trusted boundary that implements the host services —
console, files, arguments, the terminal. It owns raw mode, the
alternate screen, frame buffering and every escape byte, and it
sanitizes `term_write` text so a Luce program can never emit a control
sequence.

**loom carries no code generator.** Building is `luce`'s job, so loom
runs that binary — found beside its own executable first, then on
`PATH` — and links nothing itself. libLLVM is 164 MB and the dynamic
loader binds it before `main`, which cost every `loom` invocation
5.7 ms for nothing; loom now starts in 3 ms against a C do-nothing
binary's 2.4. It also means **a machine that only runs Luce programs
needs no LLVM installed at all**.

## The two engines

`loom run` prefers native code. Given a `.lc` it looks for `NAME.lcn`
beside it, builds one if there is none or it was built from different
bytes, and falls back to the interpreter only when the compiled path
is genuinely unavailable.

| Variable | Effect |
|---|---|
| `LOOM_ENGINE=native` | The fallback becomes an error naming what was missing |
| `LOOM_ENGINE=interpreter` | Take the reference engine on purpose |

The two agree by construction: one runtime library, one host, one
rendering of a trap. The interpreter is the reference arm of the
agreement tests, the only engine on a machine with no C toolchain, and
what `loom run` falls back to; its dispatch loop goes last, and not
soon.

## The two build modes

Luce has exactly two, and they differ in **one thing only**: what a
trap can tell you.

```sh
luce build dice.luc              # debug, the default
luce build dice.luc --release    # stripped
```

A debug module carries origins — for every instruction, the line and
column of the statement it came from, plus the source file name per
function. A trap prints the location and the whole call stack:

```
loom: trap: division by zero [divide_by_zero]
    at divide (crash.luc:5:5)
    at ratio (crash.luc:8:5)
    at main (crash.luc:12:5)
```

A release module has the tables stripped. Traps still carry their
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
Zig is *where* the cost of debug information lives. The interpreter's
dispatch loop never reads origins — not a load, not a branch — and
neither does generated code, whose origins are constant data nothing
on the execution path addresses. On a trap the interpreter walks its
still-intact frame stack; compiled code has no such stack, so it
builds the trace *as it unwinds*, each frame recording where it was on
the way out. All the cost is on the far side of "the program already
failed."

So: `--release` buys a smaller module — roughly a third off — and
gives up trap locations. Ship it when size matters or when source
lines would mean nothing to the recipient; ship debug everywhere else.

Deep recursion is capped: a trace keeps the innermost 64 frames and
counts the rest, and both engines cap at the same number, so the same
trap reports the same frames.

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
    var rows = new List(List(Int))
    var item = [1]
    rows.append(item)
```

```output
luce: compile failed
main.luc:4:17: a container keeps its object elements; write give item to hand it over, or copy item to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        rows.append(item)
                    ^~~~
```

## How this site is built

The same discipline, applied to documentation. `site/build.sh` builds
the toolchain, then a small generator in `site/src/` walks the
Markdown in `site/content/`. Every fenced Luce block on the site must
say what is to become of it — `run`, `trap`, `raise`, `fail` or
`module` — and a bare one is a build error naming the page and the
line. There is no unverified Luce here by construction.

For each sample the generator writes the program to a scratch
directory, compiles it with the freshly built `luce`, and runs it
twice: once under `LOOM_ENGINE=native`, so a silent fall back to the
interpreter is an error rather than a pass, and once under
`LOOM_ENGINE=interpreter`. **The two must agree**, which re-proves on
every page the claim this document makes about the engines. The output
you see is then compared byte for byte against what the page claims,
and a mismatch fails the build.

Some samples do not carry their own source at all: the
[bundled programs](/examples/programs/) are included from
`programs/*.luc` in the repository, so if one of them changes, the
page changes with it or the build stops.

Finally every generated page is walked for links, and every `href`
must resolve to a file in the output tree with the anchor it names.

That is the whole build. It takes a few seconds and it is the reason
these pages can be trusted to describe the compiler that is actually
in the repository.
