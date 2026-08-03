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
`import std.files` inside a host-less evaluator is a compile error,
because file access genuinely does not exist there.

Sources live in `src/luce/std/*.luc`; the table that embeds them is
in `src/luce/01_source/load.zig`; the suite proving them is
`src/luce/specs/std_spec.zig` (math, strings) plus a hosted test beside
`TestHost` in `src/luce/interpreter/test.zig` (files).

Naming follows the language's own style: modules are short lower-case
nouns, functions are short verbs read *with* the module prefix —
`files.read(path)`, `math.seed(42)` — so bare names stay short
without colliding.

---

## math

Pure Luce over the checked builtins (`sqrt floor ceil abs min max
clamp` stay builtins; math adds what they lack).  Series are
range-reduced: `exp`/`ln` hold to ~1e-14 relative, trig to ~1e-12
absolute.

```luce
import std.math

math.pi   math.tau   math.e            # constants (folded)

math.round(x)          # half away from zero: round(-2.5) == -3.0
math.exp(x)            # e^x; overflow -> inf, underflow -> 0.0
math.ln(x)             # natural log; x <= 0 traps
math.log2(x)  math.log10(x)
math.pow(x, y)         # x^y; negative x needs whole y (else trap),
                       # 0^negative traps, 0^0 == 1
math.ipow(base, n)     # Int power by squaring; checked (overflow
                       # traps); negative n traps
math.sin(x)  math.cos(x)  math.tan(x)  # radians, any magnitude
```

### Vectors and statistics

Whole-array operations over `Array(Float, _)`, the numeric vector
type — the numpy-shaped tranche.  Reductions accumulate left to
right (bit-reproducible, and against the benchmark C twins); operations with no empty answer trap on empty arrays, and
shape mismatches trap.

```luce
import std.math

math.sum(xs)            math.mean(xs)      -> Float?  (empty: none)
math.vmin(xs)           math.vmax(xs)      -> Float?  extrema; min/max
                                           # are the scalar builtins
math.dot(xs, ys)        math.norm(xs)      # Euclidean
math.variance(xs)       math.stddev(xs)    -> Float?  population
math.fill(xs, value)    math.scale(xs, factor)
math.axpy(xs, factor, ys)                  # xs[i] += factor * ys[i]
```

**Randomness** is a Lehmer/MINSTD generator whose state lives in a
`List(Int)` the caller owns — mutation through a borrow is ordinary
Luce, so there are no hidden globals and every stream is
deterministic from its seed:

```luce
var rng = math.seed(42)          # any Int seed
let f = math.random(rng)         # Float in (0, 1)
let roll = math.random_int(rng, 1, 7)   # Int in [low, high)
```

Period 2^31 − 2; games and shuffles, never secrets.

## strings

The language keeps the String **primitives**: literals and f-strings,
`+`, comparison, boundary-checked slices `s[a:b]`, `len(s)`,
`s.byte_at(i)`, and `s.find_byte(byte, start)`.  Everything built on
top of them is ordinary Luce in this module — and the familiar
method spelling is sugar for it:
with `import std.strings` in scope, `s.find(x)` *is* `strings.find(s, x)`
(and `parts.join(sep)` is `strings.join(parts, sep)`).  Using a
String method without the import is a compile error that says so.

All offsets are byte offsets, like the primitives.  The module never
splits a UTF-8 character: it slices at ASCII positions or at match
positions of valid UTF-8 needles.

Two primitives carry the weight.  `find_from` locates a needle's
first byte with `find_byte` and only then compares the rest, so the
scan itself is one call the runtime may vectorize rather than a Luce
loop over `byte_at`; `fold_case` emits folded bytes with
`append_ascii`, which needs no String per character.  Both are why
the module is fast enough to stay written in Luce (docs/CODEGEN.md
§10).

```luce
import std.strings

strings.find(s, needle)          # first byte offset, or -1
strings.find_from(s, needle, start)
strings.contains(s, needle)      # Bool
strings.starts_with(s, prefix)   strings.ends_with(s, suffix)
strings.count(s, needle)         # non-overlapping occurrences
strings.trim(s)                  # ASCII whitespace off both ends
strings.lower(s)  strings.upper(s)   # ASCII folding; multibyte
                                     # characters pass through whole
strings.replace(s, old, replacement) # every occurrence; empty old
                                     # changes nothing
strings.repeat(s, times)         # zero or fewer -> ""
strings.split(s, separator)      # List(String), keeps empty pieces;
                                 # "" separator = whitespace runs,
                                 # empties dropped (Python's split())
strings.join(parts, separator)   # List(String) -> String
strings.pad_left(s, width)  strings.pad_right(s, width)
strings.format_float(x, decimals)    # fixed-point: "2.50"; rounds
                                     # half away from zero
```

## files

A thin, honest layer over the host's file builtins (host-gated; loom
resolves paths relative to the current directory).

Everything that touches a file says `!`: the world decides whether a
read or a write lands, so `try` it or `catch` it (docs/LANGUAGE.md).
`exists` answers a plain Bool and is the exception — but it is a
question about the past, never a guard for the call after it. Read
the file and handle what the read says.

```luce
import std.files

files.exists(path)               # Bool — a question, not a guard
files.read(path)                 # String!
files.write(path, text)          # !
files.read_lines(path)           # List(String)!, newlines stripped; a
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
files.list(path)                 # List(String)!, sorted; plain names,
                                 # not paths, and no "." or ".."
```

`append_text` is spelled that way because `append` is a **reserved
name** — it is `xs.append(v)`, the List method — and nothing
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

## Adding a module

1. Write `src/luce/std/NAME.luc` — ordinary Luce, documented with
   `#` comments in the header.
2. Add one row to `standard_modules` in `src/luce/01_source/load.zig`
   — the one place that answers "what are the bytes of module X".
3. Prove it in `std_spec.zig` (pure) or beside `TestHost` (hosted),
   the way math and files are.
4. Document it here.

Deliberate constraints, until the language grows the features:
no module state (top-level `let` is constant — the RNG's List-state
pattern is the idiom for mutable state), and a function that may find
nothing answers a `T?` while one that may *fail* says `!`
(docs/LANGUAGE.md) — `files` is written that way throughout. `math` has been revisited too: the five
reductions over an array — `mean`, `vmin`, `vmax`, `variance`,
`stddev` — answer `Float?`, because an empty array has no mean and
"there is nothing there" is the same fact every time with no reason
worth carrying.  The seven traps left are domains a caller was handed
and could have checked: `ln` of a non-positive number, `pow` and
`ipow` outside theirs, a shape mismatch in `dot` or `axpy`, and
`random_int` with an empty range.  Those are bugs, and bugs trap.
