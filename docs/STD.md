# The Luce standard library

Std modules are ordinary Luce source **embedded in the compiler** —
the way Zig ships `lib/std` with its compiler, minus the install
path.  Wherever the compiler runs (the `luce` CLI, loom, a test),
`import std.math` just works.

**`std.` is the reserved namespace, and nothing else is.**
`import std.math` reaches the library; `import math` reaches
`math.luc` beside your program and never the library.  Because the
two namespaces are disjoint, a std module cannot be shadowed *and* a
file of your own cannot be made unreachable — the two halves of
Python's `random.py` problem, both gone.

The import **binds the bare name**: after `import std.math` the call
sites are `math.sqrt(x)`, exactly as before, and only the import line
records where the module came from (Rust's `use std::fs;` then
`fs::read`).  A program that writes both `import std.math` and
`import math` therefore has two modules under one binding and is
refused (`luce.import.collision`); rename the file, since there is no
`as` clause.  `import std.nope` lists the modules that do exist
(`luce.import.standard`), and `import std` is refused because the
namespace is not a module — no `std.luc` can be imported
(`luce.import.reserved`).

Being ordinary modules, std code obeys every language rule — the
ownership model, the checked arithmetic, and the host gate:
`import std.files` inside a host-less program is a compile error,
because file access genuinely does not exist there.

Sources live in `src/luce/std/*.luc`; the table that embeds them is
in `src/luce/01_source/load.zig`; the suite proving them is
`src/luce/specs/std_spec.zig` — math, strings and files alike, each
program run on both engines and compared (docs/ENGINE.md).

Naming follows the language's own style: modules are short lower-case
nouns, functions are short verbs read *with* the module prefix —
`files.read(path)`, `math.round(x)` — so bare names stay short
without colliding.

---

## math

Pure Luce over the checked builtins (`sqrt floor ceil abs min max
clamp` stay builtins; math adds what they lack).  Series are
range-reduced: `exp`/`ln` hold to ~1e-14 relative, trig to ~1e-12
absolute.

```text
import std.math

math.pi   math.tau   math.e            # constants (folded)

math.round(x)          # half away from zero: round(-2.5) == -3.0
math.exp(x)            # e^x; overflow -> inf, underflow -> 0.0
math.ln(x)             # natural log; x <= 0 traps
math.log2(x)  math.log10(x)
math.pow(x, y)         # x^y; negative x needs whole y (else trap),
                       # 0^negative traps, 0^0 == 1
math.ipow(base, n)     # long power by squaring; checked (overflow
                       # traps); negative n traps
math.sin(x)  math.cos(x)  math.tan(x)  # radians, any magnitude
```

### Vectors and statistics

Whole-array operations over `array(double, _)`, the numeric vector
type — the numpy-shaped tranche.  Reductions accumulate left to
right (bit-reproducible, and against the benchmark C twins); operations with no empty answer trap on empty arrays, and
shape mismatches trap.

```text
import std.math

math.sum(xs)            math.mean(xs)      -> double?  (empty: none)
math.vmin(xs)           math.vmax(xs)      -> double?  extrema; min/max
math.minmax(xs)         -> (double?, double?)         both, one traversal
                                           # are the scalar builtins
math.dot(xs, ys)        math.norm(xs)      # Euclidean
math.variance(xs)       math.stddev(xs)    -> double?  population
math.fill(xs, value)    math.scale(xs, factor)
math.axpy(xs, factor, ys)                  # xs[i] += factor * ys[i]
```

**Randomness** is a Lehmer/MINSTD generator in a struct the caller
owns — the state is a private field written back by each draw, so
there are no hidden globals and every stream is deterministic from
its seed:

```luce
import std.math

func main():
    var rng = math.rng(42)           # any long seed
    let f = rng.real()               # double in (0, 1)
    let roll = rng.in_range(1, 7)    # long in [low, high)
    print(string(f) + " " + string(roll))
```

Period 2^31 − 2; games and shuffles, never secrets.

## strings

The language keeps the string **primitives**: literals and f-strings,
`+`, comparison, boundary-checked slices `s[a:b]`, `len(s)`,
`s.byte_at(i)`, and `s.find_byte(byte, start)`.  Everything built on
top of them is ordinary Luce in this module — and the familiar
method spelling is sugar for it:
with `import std.strings` in scope, `s.find(x)` *is* `strings.find(s, x)`
(and `parts.join(sep)` is `strings.join(parts, sep)`).  Using a
string method without the import is a compile error that says so.

All offsets are byte offsets, like the primitives.  The module never
splits a UTF-8 character: it slices at ASCII positions or at match
positions of valid UTF-8 needles.

Two primitives carry the weight.  `find` locates a needle's
first byte with `find_byte` and only then compares the rest, so the
scan itself is one call the runtime may vectorize rather than a Luce
loop over `byte_at`; `fold_case` emits folded bytes with
`append_ascii`, which needs no string per character.  Both are why
the module is fast enough to stay written in Luce (docs/CODEGEN.md
§10).

```text
import std.strings

strings.find(s, needle, start = 0)  # first occurrence at or after
                                    # start, or -1 (docs/ARGS.md)
strings.contains(s, needle)      # bool
strings.starts_with(s, prefix)   strings.ends_with(s, suffix)
strings.count(s, needle)         # non-overlapping occurrences
strings.trim(s)                  # ASCII whitespace off both ends
strings.lower(s)  strings.upper(s)   # ASCII folding; multibyte
                                     # characters pass through whole
strings.replace(s, old, replacement) # every occurrence; empty old
                                     # changes nothing
strings.repeat(s, times)         # zero or fewer -> ""
strings.split(s, separator)      # list(string), keeps empty pieces;
                                 # "" separator = whitespace runs,
                                 # empties dropped (Python's split())
strings.join(parts, separator)   # list(string) -> string
strings.pad_left(s, width)  strings.pad_right(s, width)
strings.format_float(x, decimals)    # fixed-point: "2.50"; rounds
                                     # half away from zero
```

## files

A thin, honest layer over the host's file builtins (host-gated; loom
resolves paths relative to the current directory).

Everything that touches a file says `!`: the world decides whether a
read or a write lands, so `try` it or `catch` it (docs/LANGUAGE.md).
`exists` answers a plain bool and is the exception — but it is a
question about the past, never a guard for the call after it. Read
the file and handle what the read says.

```text
import std.files

files.exists(path)               # bool — a question, not a guard
files.read(path)                 # string!
files.write(path, text)          # !
files.read_lines(path)           # list(string)!, newlines stripped; a
                                 # trailing final newline adds no
                                 # phantom empty line
files.write_lines(path, lines)   # !; joined with newlines, ends with
                                 # one, and an empty list writes an
                                 # empty file

files.append_text(path, text)    # !; adds to the end, creating the
                                 # file if it is not there
files.append_lines(path, lines)  # !; the same, one line each; an
                                 # empty list adds nothing at all
files.delete(path)               # !
files.rename(from, to)           # !; replaces `to` if it exists, so
                                 # write-then-rename replaces a file
                                 # without ever leaving half of one
files.list(path)                 # list(string)!, sorted; plain names,
                                 # not paths, and no "." or ".."
```

`append_text` is spelled that way because `append` is a **reserved
name** — it is `xs.append(v)`, the list method — and nothing
user-declared may take one, module-qualified or not.  It is a wart and
it is recorded as one in `docs/MISSING.md`.

`list` sorts because the host's order is whatever the file system felt
like, and two machines holding the same files answer differently.  A
program that prints a listing should print the same listing.

The four new ones are `!` for the reason `read` and `write` are: the
world decides, and no non-racy check stands in for the result.
Deleting a file that is not there answers `io_failed` rather than
succeeding quietly — the host says `yes` or `no` and cannot tell
"absent" from "refused" (`abi.Answer`), so inventing the distinction
would be inventing it.

---

## paths

Pure text over path names — nothing here touches the host, so the
module works even in a program compiled without host access, no
function can fail or trap on any input, and every answer is a plain
`string` or `bool`.  The separator is `/`, the one the hosts loom
runs on use; there are no drive letters, no backslashes and no
`.`/`..` cleaning — a path is taken as written, and only the seams
the module itself creates are kept tidy.  The shapes follow Go's
`path` package where Go and Python agree, and Python where they
differ on taste: a leading dot is a hidden file's name, not an
extension.

```text
import std.paths

paths.is_absolute(path)     # bool — starts at the root
paths.join(head, tail)      # one separator at the seam; an empty side
                            # answers the other, an absolute tail
                            # answers itself
paths.base(path)            # the last element; trailing separators do
                            # not count; base("/") is "/"
paths.dir(path)             # everything but the last element; a bare
                            # name answers ".", the root is its own
                            # directory
paths.extension(path)       # the base's extension, dot included, or ""
paths.stem(path)            # the base without its extension
```

Two invariants hold on every input, and the spec suite walks them:
`join(dir(p), base(p))` names the same file `p` does — which is why a
bare name's directory is `"."` rather than `""` — and
`stem(p) + extension(p)` is always `base(p)`.

---

## os

What machine is this?  Three numbers, over the three host builtins
that ask for them.  Hosted: the machine's size is the world's business
and not the program's, so every function here is behind the host gate
like `print` and `file_read`.

```
import std.os

os.total_memory()           # long — bytes of physical memory
os.available_memory()       # long — bytes it could still hand out
os.cpu_count()              # long — logical processors
os.used_memory()            # long — total minus available, both read
                            # here: it does not equal a difference you
                            # computed from readings taken elsewhere
```

Nothing here answers `?` or `!`.  A fact the host knows is a number; a
fact it does not know is a **refusal** — `host_unavailable`, the same
trap a withheld service gives — because the alternative is a host
inventing a number the program cannot tell from a measurement.  That
is why the ABI's three slots answer through an out-parameter with the
usual `Answer` rather than returning a bare `i64` the way `clock_ms`
does: `no` on those slots means *this host cannot tell*.

**`available_memory()` moves, and what the word means is the host's.**
Ask it twice and expect two answers; that is the reason to ask it at
all.  Per platform, and said in `src/apps/machine.zig` beside the code:

| Host | "available" is |
|---|---|
| macOS | free + inactive + purgeable pages.  Not `free` alone, which on macOS is close to meaningless — a 64 GiB machine reports about 3.7 GiB free and 38 GiB available, because almost nothing is kept idle |
| Linux | the kernel's own `MemAvailable`; where `/proc` is not mounted, `sysinfo`'s free + buffers, which understates by the whole reclaimable page cache |
| anywhere else | nothing — the host answers `no` and the program traps |

`total_memory()` and `cpu_count()` are `std.process.totalSystemMemory`
and `std.Thread.getCpuCount`, which already know how to ask on every
platform Zig targets.  Only "available" needed platform code of its
own, because there is no portable question for it.

These numbers are for **reporting and sizing, not deciding**: memory
moves between the reading and the use of it, so `available_memory()`
is a gauge and never a guarantee.  Luce allocates through the runtime,
which traps on exhaustion with a code of its own; that is what a
program is actually held up by, and this module is what a program
prints.

`cpu_count()` is here although Luce has no threads — a fact to report
rather than one to act on.  It is in because the machine's facts are
one subject and one ABI version: asking for it a release later would
have cost every artifact in the world a rebuild to learn one number.

---

## Adding a module

1. Write `src/luce/std/NAME.luc` — ordinary Luce, documented with
   `#` comments in the header.
2. Add one row to `standard_modules` in `src/luce/01_source/load.zig`
   — the one place that answers "what are the bytes of module X".
3. Prove it in `std_spec.zig`, the way math, strings and files are —
   a hosted module names the world it wants (`agree.World.withFile`,
   a refusing host) and gets the same one on both engines.
4. Document it here.

Deliberate constraints, until the language grows the features:
no module state (top-level `let` is constant — the RNG's list-state
pattern is the idiom for mutable state), and a function that may find
nothing answers a `T?` while one that may *fail* says `!`
(docs/LANGUAGE.md) — `files` is written that way throughout. `math` has been revisited too: the five
reductions over an array — `mean`, `vmin`, `vmax`, `variance`,
`stddev` — answer `double?`, because an empty array has no mean and
"there is nothing there" is the same fact every time with no reason
worth carrying.  The seven traps left are domains a caller was handed
and could have checked: `ln` of a non-positive number, `pow` and
`ipow` outside theirs, a shape mismatch in `dot` or `axpy`, and
`in_range` with an empty range.  Those are bugs, and bugs trap.
