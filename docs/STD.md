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
refused (`luce.import.collision`); the remedy is aliasing the sibling
(`import math as m2`, docs/PACKAGES.md D2) — a standard module keeps
its own name, so `import std.math as m` is refused at parse time.
`import std.nope` lists the modules that do exist
(`luce.import.standard`), and `import std` is refused because the
namespace is not a module — no `std.luc` can be imported
(`luce.import.reserved`).

Being ordinary modules, std code obeys every language rule — the
ownership model, the checked arithmetic, and the host gate:
`import std.files` inside a host-less program is a compile error,
because file access genuinely does not exist there.

Sources live in `src/luce/std/*.luc`; the table that embeds them is
in `src/luce/01_source/load.zig`; the suite proving them is
`src/luce/specs/std_spec.zig` and the language specs — all nine
modules are ordinary source, with each program run on both engines and
compared (docs/ENGINE.md).

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

## lists

Comparator-driven list algorithms.  `sort_by` is ordinary Luce in
`std.lists`, reached through list method syntax after the module is
imported:

```luce
import std.lists

func descending(a: long, b: long) -> bool:
    return a > b

func main():
    var values: list(long) = [3, 1, 4, 1, 5]
    values.sort_by(descending)
    values.sort_by((a, b) -> a < b)
```

For a `list(T)`, `xs.sort_by(before)` expects
`before: func(T, T) -> bool`.  `before(a, b)` means that `a` belongs
before `b`.  It should define a consistent strict order; two elements
are equivalent when neither precedes the other, and stability preserves
their original order.  The comparator is borrowed and positional; it
may be a named function or a capture-free lambda.  The sort is in place,
**stable**, and O(n log n).  Empty and one-element lists are unchanged,
and every element type is accepted, including structs and heap objects.
Object elements are moved through the merge, never copied.

This is a routed std method, not a builtin.  Without
`import std.lists`, the call is `luce.sema.import` and names the import
to add.  Stage 4 specializes the one checked source template at the
list's monomorphic element type; MIR and `libluce_rt` gain no sorting
primitive.

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

strings.find(s, needle, start = 0)  # long? — first occurrence at or
                                    # after start, or absence; the
                                    # fallback form is
                                    # find(...) else -1 (docs/ARGS.md)
strings.contains(s, needle)      # bool
strings.is_digit(b)  strings.is_alpha(b)  strings.is_alnum(b)
strings.is_upper(b)  strings.is_lower(b)  strings.is_space(b)
                                 # the ASCII classes, on the byte
                                 # byte_at answers; bytes above 127
                                 # are in none of them
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

strings.to_bytes(s)              # list(byte) — total; a string always
                                 # has bytes
strings.from_bytes(xs)           # string? — absent when the bytes are
                                 # not valid UTF-8
```

The asymmetry of the last pair is its whole content (docs/BYTES.md R3).
A `string` is already valid UTF-8, so taking its bytes is a reading of
something certainly there; handing bytes back is a *claim* about them,
and it can be false.  `from_bytes` answers `string?` and not `string!`
for the reason `parse_int` does: "not UTF-8" is the same reason every
time, and a carried message adds nothing the name did not.  The
validator behind it is `libluce_rt`'s — the same one `files.read` uses
— so there is one answer to what "not text" means.

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

### The byte channel (docs/BYTES.md)

The same files, seen as bytes.  Nothing here asks whether what it
carries is text; that is what `strings.from_bytes` is for, and it is
why a JPEG reads as happily as a note.

```text
files.open(path)                 # file! — read, from the start
files.create(path)               # file! — write, creating and emptying
files.append_to(path)            # file! — write, at the end
files.read_bytes(path)           # list(byte)!
files.write_bytes(path, bytes)   # !
files.append_bytes(path, bytes)  # !
```

`open`, `create` and `append_to` answer a **`file`**, which is a
scope-owned resource: the binding that received it owns it, the end of
that scope closes it, `free(f)` closes it early, `give` and `return`
move it, and using one after it is closed traps `use_after_free`,
because it is the same mistake.  There is deliberately no `close` — a
file you have to remember to close is a file somebody will not, and
the compiler already knows where a name's life ends.

The handle's own three are `f.read(buffer)`, `f.write(buffer, count)`
and `f.flush()`, all fallible.  The buffer is an `array(byte, _)` the
caller owns, with its extent supplied at construction; a read fills it
and answers **how many bytes landed**,
where zero is the end of the file, and a write answers how many landed,
which may be fewer than were offered.  That is the C shape on purpose:
short is ordinary, the caller loops, and the same three serve a socket
when `std.network` arrives.

`read_bytes`, `write_bytes` and `append_bytes` are those loops written
once — the Go layering, where `os.ReadFile` is a loop over `Read`.
`files.read` and `files.write` are defined over the same channel, with
the runtime's own UTF-8 check on the reading side, so "not text" means
one thing wherever a program runs.

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
like `print` and `file_read`.  This module also owns the deliberately
small shell seam used by host tools such as the example editor.

```
import std.os

os.total_memory()           # long — bytes of physical memory
os.available_memory()       # long — bytes it could still hand out
os.cpu_count()              # long — logical processors
os.used_memory()            # long — total minus available, both read
                            # here: it does not equal a difference you
                            # computed from readings taken elsewhere

try os.shell.run("loom luce examples/hello.luc")
                            # string! — captured stdout/stderr and exit status
```

`os.shell.run(command)` sends one command string to the host shell and
returns its combined standard output and standard error, followed by a
line describing the exit status. Quote paths and other arguments for that
shell. It is host-gated and fallible: a shell the host cannot start is an
`io_failed` error. This is a tool boundary, not a portable process or
argument-vector API.

### `os.term` and `os.term.ui`

Terminal operations now have a Luce-owned home instead of making every
program call the flat `term_*` and `key_*` builtins directly. `std.os` is
the full system module (`os.term`), and `std.term` is the short terminal
module (`term`) for programs that do not need the other OS facts:

```
import std.os
import std.term

let rows = os.term.rows()
let cols = os.term.cols()
os.term.move(0, 0)
os.term.style(80, bold = true)
os.term.write(os.term.ui.junction(top = true, right = true, bottom = true, left = true))
os.term.flush()
let name = os.term.io.read()
let text = os.term.io.text()
let mouse_row = os.term.io.row()

term.write(term.ui.horizontal())
```

The `os.term` methods are hosted and retain the existing raw-mode,
alternate-screen, mouse-reporting, frame-buffering and sanitization rules.
`os.term.io` is one event stream: `read()` answers keyboard names,
`mouse_press`/`mouse_release`/`mouse_drag`/`mouse_wheel`, or `resize`; its
`text`, `row`, `column`, `button`, `modifiers` and `value` methods describe
the event just read. Buttons are left `0`, middle `1`, right `2`, and `-1`
for keyboard, resize and wheel events; modifier bits are shift `1`, alt `2`
and ctrl `4`. `os.term.ui` is pure Unicode geometry:
`horizontal()`, `vertical()`, the four corners,
`junction(top, right, bottom, left)`, and light/dark one-cell shadows. The
four booleans describe the lines that continue through a cell, so a layout
can draw uninterrupted borders and correct intersections rather than
overwriting a corner with a generic plus sign. The existing flat builtins
remain the compiler/ABI seam underneath these facades.

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

`cpu_count()` went in before Luce had threads, because the machine's
facts are one subject and one ABI version: asking for it a release
later would have cost every artifact in the world a rebuild to learn
one number.  Since workers landed (`docs/THREADS.md`) it is the number
that sizes a spawn count.

---

## zip

ZIP archives and DEFLATE, in pure Luce — and the module that says out
loud where the host boundary stops.  Nothing here is a builtin and
nothing here touches the world: every function takes bytes and answers
bytes.

**Written against the normative documents, and every structure in the
source names its clause.**  The container is PKWARE's APPNOTE.TXT
6.3.10 — 4.3.7 local header, 4.3.12 central directory, 4.3.16 end
record, 4.4.4 flags, 4.4.5 methods, 4.4.3.2 the version an entry
needs.  The compression is RFC 1951 — §3.2.2 canonical Huffman,
§3.2.4 stored blocks, §3.2.5 the length and distance tables
(transcribed as printed, code 285's lone 258 included), §3.2.6 the
fixed codes, §3.2.7 the dynamic ones.  A member's method-8 data is a
**raw** deflate stream: no zlib header, no Adler-32 trailer.  The
CRC-32 is zlib's reflected 0xEDB88320, preconditioned with ones and
complemented at the end, exactly as APPNOTE 4.4.7 says.

The six printed tables are written as what they are: one program-root
CRC array, four length/distance base and extra lists, and the
code-length order array, all `private const`.  Each runtime
materializes them once before the module's code runs; `crc32`,
`inflate` and `deflate` borrow the shared rows instead of rebuilding
them per call or block.

```text
import std.zip

zip.read(path)                   # list(byte)! — an archive off the disk
zip.write(path, archive)         # ! — what writer.finish() answered

zip.bytes(content)               # string -> list(byte), the UTF-8 bytes
zip.text(data)                   # list(byte) -> string?, absent when
                                 # the bytes are not text

zip.crc32(data)                  # long — crc32("123456789") is 3421780262

zip.entries(archive)             # list(Entry)! — the central directory
zip.extract(archive, entry)      # list(byte)! — checked against size and CRC
  entry.name()   entry.size()   entry.packed()
  entry.crc()    entry.deflated()

zip.writer()                     # Writer — a new, empty archive
  writer.add(name, data, compress = false)   # !
  writer.finish()                            # list(byte), fresh each call

zip.inflate(data)                # list(byte)! — stored, fixed and dynamic
zip.deflate(data)                # list(byte) — one fixed-Huffman block
```

**Bytes are a `list(byte)`, one byte to an element** — and one byte of
memory, since `list` gave up the boxed slot (docs/BYTES.md R1).  This
module is where that cost was first measured: it used to read "bytes
are a `list(long)`", because a `list(byte)` was twenty-four bytes an
element *and* a conversion at every store, so the honest choice was the
width the arithmetic happens at.  The buffers are a quarter of what
they were and not a line of the algorithms changed.

One thing the narrower element made explicit rather than changed: a
`byte` widens to `int` in an operator (docs/TYPES.md D5), so a 32-bit
field's top byte would shift into a sign bit.  `read_u32` lifts its
four bytes to `long` and says so; everything else fits.

**An archive on disk is reachable.**  `zip.read(path)` and
`zip.write(path, archive)` are the only two things here that touch the
world, and they are what the module was written for: until a Luce
program could read a file that was not text, "takes bytes" meant
"takes bytes somebody computed", and no real archive could reach any
of it.  Everything between still takes bytes and answers bytes, which
is why the two doors are one line each.

Two clauses a conforming reader has to tolerate are tolerated: an
entry written without seeking, whose local header carries zeros where
the CRC and sizes belong (4.4.4 bit 3, read from the directory 4.4.7
requires to be right), and an archive with a program in front of it,
whose offsets are shifted by however far its directory really begins
from where it claims to.  Everything else — encryption, an unknown
method, a name that is not text, contents that fail their checksum, a
comment holding a false end-record signature — is refused by name.

The spec suite is `src/luce/specs/zip_spec.zig`, and it is the one
std suite whose fixtures are **other people's bytes**: five archives
embedded as the decimal numbers they are, four of them written by
Info-ZIP and Python and one shaped by hand, covering stored, fixed
Huffman, dynamic Huffman, a data descriptor and a prepended program.
A library that only reads what it wrote has proven nothing about ZIP.

---

## json

JSON, in pure Luce.  Parse a document, walk it, read the leaves, print
it back.  Nothing here is a builtin, nothing here imports anything
(not even `std.strings`), and nothing here touches the world: `parse`
takes a string and answers a document.

**Written against RFC 8259**, and every rule in the source names the
clause it implements — §2 the structural characters and the four
whitespace bytes, §3 the three literal names, §4 objects, §5 arrays,
§6 numbers, §7 strings and their escapes, §8.1 encoding, §8.2 unpaired
surrogates, §9 nesting.  ECMA-404 is cited where the two documents
leave a reader a choice.  The spec suite is
`src/luce/specs/json_spec.zig`, and most of it is **refusals**: a
parser is defined by what it will not take, and the fixtures are
Nicolas Seriot's JSONTestSuite (*Parsing JSON is a Minefield*, 2016) —
its `y_` rows, which every parser must accept, its `n_` rows, which
every parser must refuse, and its `i_` rows, which real parsers
disagree about and this one decides out loud.

```text
import std.json

json.parse(text)                 # Document! — the whole grammar, or an
                                 # error naming the byte and the problem
json.quote(text)                 # string -> a JSON string literal, the
                                 # escaping done right

doc.root()                       # Node — the one top-level value
doc.get(node, name)              # Node? — an object's member, or absent
doc.at(node, index)              # Node — an element; past the end traps
doc.items(node)                  # list(Node) — every child, in order
doc.keys(node)                   # list(string) — every member name
doc.write(node)                  # string — JSON with no whitespace
doc.pretty(node, spaces)         # string — the same, indented

node.kind()                      # Kind — object array text number
                                 #        boolean null
node.count()                     # long — members or elements; 0 for a leaf
node.key()                       # string — its member name, decoded
node.raw()                       # string — its text exactly as written
node.is_null()                   # bool
node.as_bool()  node.as_long()  node.as_double()  node.as_text()
                                 # bool? long? double? string?
```

**Lazy, in simdjson's On-Demand sense.**  A parse walks the text once,
checks that every byte of it is grammatical, and records where each
value begins and ends; it does not turn `"1e3"` into a double or a
`𝄞` into 𝄞 until somebody asks.  A document read for one
field pays for one field, and `node.raw()` is always exactly what the
author wrote.

**A document is flat, and a node is a value that points into it.**
`Document` owns one `list(Node)` holding every value in document
order; a `Node` is a plain value — a kind, two spans of text, three
numbers — so it copies for nothing, returns from any function, and
needs no ownership verb anywhere.  Each node records the index one
past its own subtree, which is simdjson's tape: a container's first
child is the node after it, and any value's next sibling is that
index.  Navigation is therefore a method on the *document*, because a
node on its own does not know where the rest of the document lives.

That shape is what the language allows rather than a preference.  A
nested tree of `list(Node)` children cannot answer `get(name) ->
Node?` at all: returning an object-carrying struct read out of a
container is refused (OWNERSHIP.md S17, S22), and returning a `copy`
of one would deep-copy the whole subtree on every field access.  Flat
costs one heap object for a document of any size, and the reading path
allocates only what it hands back.

Reaching a member is two steps, because `get` answers `Node?` and a
method needs a `Node` — and the narrowing is a function, which is
legal precisely because a node returns from one:

```text
func child(doc: json.Document, node: json.Node, name: string) -> json.Node:
    let found = doc.get(node, name)
    if found != none:
        return found
    trap("no member named " + name)
```

**Reading a file is three calls and this module makes none of them:**
`files.read_bytes(path)`, then `strings.from_bytes(bytes)`, then
`json.parse(text)`.  UTF-8 needs no checking on the way (RFC 8259
§8.1): the input is a Luce string, so it is valid UTF-8 by
construction and the encoding question was answered before the text
arrived.

The calls other parsers argue about, each with its reason:

| | this module |
|---|---|
| **Nesting** | bounded at **128** (§9 allows a limit).  The parse is iterative and would not care, but a document is *walked* by callers, and loom lets a program nest 128 calls before `call_depth_exceeded` — so accepting a deeper one would hand a caller a tree no recursive function of theirs can walk.  serde_json's default is the same number from the other direction.  A 10,000-deep array is an error with a name, not a machine falling over |
| **Duplicate names** | `get` resolves to the **last** (§4: names SHOULD be unique, behaviour otherwise unpredictable), as JavaScript, Python and Go all do.  The document is not edited to match — `count`, `items` and `keys` still show every member as written, because a reader who wants to know a document repeats itself should be able to find out |
| **Unpaired surrogates** | **refused** by name at the byte (§8.2 warns; ECMA-404 permits the code unit).  A Luce string is UTF-8 and half a pair has none, so the alternatives were refusing and quietly substituting U+FFFD.  A well-formed pair is one codepoint |
| **`as_long`** | reads the **notation**: `42` answers 42, and `4.2`, `42.0` and `4.2e1` all answer `none` and are read with `as_double`.  A number written as a real is a real; absence says so, where truncating would drop information silently.  Too large for a `long` is `none` too, exactly as `parse_int` says it |
| **NaN, Infinity** | not JSON (§6 has one number grammar and no names in it), refused like any other unknown word |
| **`write`** | not a byte-for-byte echo — the whitespace a document arrived with is not kept — but every *token* is the one that was read, escapes and number notation and all.  So `parse → write → parse → write` is a fixed point, and a document that arrived minified comes back identical |

`has` is missing on purpose: it is a reserved name (`m.has(k)`, the map
method), so `doc.get(node, name) != none` is the membership question
and it is the same one call.

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
no mutable module state (top-level `const` may hold a folded value or a
program-root immutable table — the RNG's returned `Rng` is the idiom
for mutable state), and a function that may find
nothing answers a `T?` while one that may *fail* says `!`
(docs/LANGUAGE.md) — `files` is written that way throughout. `math` has been revisited too: the five
reductions over an array — `mean`, `vmin`, `vmax`, `variance`,
`stddev` — answer `double?`, because an empty array has no mean and
"there is nothing there" is the same fact every time with no reason
worth carrying.  The seven traps left are domains a caller was handed
and could have checked: `ln` of a non-positive number, `pow` and
`ipow` outside theirs, a shape mismatch in `dot` or `axpy`, and
`in_range` with an empty range.  Those are bugs, and bugs trap.
