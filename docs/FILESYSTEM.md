# The filesystem surface — `open()`, `std.files`, `std.paths`, and the three things that are actually missing

**Status: PARTLY BUILT (2026-08-12).**  The three genuinely missing
pieces — `kind`, listings that carry kinds, and a multi-part join —
and everything that follows from them are **built, on both engines,
with specs**: steps 1 to 4 of Sequencing, plus the documentation.
`open()`, `FileMode` and the seven file-surface methods (D4–D8, steps
5 and 6) are **not** built and are the precise remainder; the As-built
section at the bottom says what shipped, what departed and why, and
what a second run picks up.  Everything below this line is the design
memo as ratified, unaltered.  Every fenced block is
```` ```text ````, because a design memo's examples are the design's
and not the build's — though every shape below that could be checked
against the installed toolchain was, and the memo says so wherever that
changed a decision.  Two of the previous revision's examples were
checked and **did not compile**; they are corrected here and the
corrections are evidence items, because a memo whose code does not
compile is a memo whose design has not been tried.

**This revision refuses the `Path` type and keeps the shape the tree
already has.**  The owner's direction was Python fidelity:

> *"I'd like the code the people will write to be exactly like in
> python.  So built in open() that returns a File and then
> std.os.pathlib with all the implications."*

and the ruling, after that direction was worked through:

> *"I lean A as well."* — **`os.path` + `open()`.  No `Path` type.**

That is not a retreat from fidelity; it is the conclusion fidelity
reaches when the two candidates are written out.  **Python has two
filesystem surfaces and Luce can be literally faithful to exactly one of
them.**  `os.path` + `os` + `open()` maps onto Luce with *no new
language surface at all*; `pathlib` maps onto Luce as a chain of method
calls that shares pathlib's vocabulary and none of its feel, bought with
a new type and a conversion at every boundary.  Choosing the surface we
can actually deliver is the fidelity decision, and the rest of this memo
is the argument and what remains to be built.

Everything the previous revisions *measured* survives unchanged.  The
run's real content is three genuinely missing pieces — `kind`, listings
that carry kinds, and a multi-part join — plus `open()` as the owner
asked for it by name.

The first consumers of this surface are one run away — `luce install`
laying out a store, a build tool, the registry's server side, and
`examples/zipper` already.  The `strings.find` precedent applies with
full force: an API wart fixed before consumers exist costs nothing, and
after costs everyone.

Version numbers below are of 2026-08-11: `abi.version` 16,
`format_version` 41.

---

## What this revision changes

| | previous revision | this revision | why |
|---|---|---|---|
| `Path` value type | **built** | **refused** (D2) | It cannot look like pathlib — see the three findings below.  A construct that exists to imitate something it cannot imitate is a weird exception with a bill attached. |
| `std.paths` / `std.files` | merged, then deleted | **both kept, unmerged, free functions** (D1) | They are `os.path` and `os`, which is the half of Python that maps 1:1 with zero new language surface.  The measured objection to the split survives as a *wart*, recorded honestly, not as a reason to merge. |
| opening a file | `files.open` / `create` / `append_to` | **one free builtin, `open(path, mode = FileMode.read)`** (D4) | The directive names it.  `file_open(path, mode: long)` was always this builtin wearing a number instead of a name. |
| mode | which door you took | **`FileMode`, a predeclared enum** (D5) | §53: `"w"` is the magic value.  A default makes `open(path)` the common call. |
| the `file` value | `read`/`write`/`flush` only | **gains `read_text`, `read_bytes`, `read_line`, `read_lines`, `write_text`, `write_bytes`, `write_lines`** (D7) | `open()` cannot vary its return type by mode, so one file carries both channels.  The C-shaped pair keeps its name *and* its meaning — no rename, because sockets are meant to share it. |
| `Kind` / `Entry` / kinds in listings | ratified | **kept, verbatim in substance**, as `files.Kind` / `files.Entry` | Measured, argued, unaffected by which surface won. |
| `files.exists` | `bool!` | **`bool!`** | The measured bug was the bool that *swallows*, not the name. |
| multi-part join | absorbed by `p.join()` chaining | **`paths.joined(parts)`** (D18) | With no `/` operator and no `Path`, `join(join(a, b), c)` is the one place chaining is genuinely missed.  This is the honest Luce answer. |
| `other: pass` in the walk example | written | **`other: continue`** | There is no `pass` statement (evidence 20). |
| `match try files.kind(p):` | written | **bind, test for `none`, then `match`** | Checked: matching an optional enum is refused by name (evidence 23). |

---

## The evidence, measured

Items 1–13 are the previous revisions' and stand unaltered.  Items
14–24 were checked against the installed toolchain on 2026-08-11.

**1. `files.exists` answers a question its name does not ask.**
`files.exists(p)` is `file_exists(p)`, which is `Dir.cwd().openFile(io,
path, .{})` — and Zig 0.16's `OpenFileOptions.allow_directory` defaults
to `true`.  So it opens directories and answers `true` for them:

```text
files.exists("probe/sub")        # true  — a directory
files.exists("probe/note.txt")   # true  — a file
files.exists("probe/nope")       # false
```

It has always meant *there is an entry at this name*, and nothing — not
the doc comment in `files.luc`, not the row in `docs/STD.md`, not
`abi.FileExistsFn` — says so.  The two live callers rely on the
undocumented meaning: `examples/zipper/zipper.luc:116` writes `if not
files.exists(into)` where `into` must be a **directory**, and gets the
answer it wants by accident.  Hand it a *file* and zipper proceeds, then
fails on the first `make_directory` with `io_failed`.

**2. It also lies in the other direction.**  A file that certainly
exists, under a directory that refuses to be opened:

```text
$ chmod 000 locked
files.exists("locked/inside.txt")   # false
```

`false` here does not mean "nothing is there".  It means "I was not
allowed to look", and the bool has no room to say so.  This is the same
shape `docs/FAILURE.md` refused for `key_read` — an in-band answer a
loop falls past, leaving the bug writable — decided the other way by
default rather than on purpose.

**3. There is no way to ask what kind of thing is at a path.**  No
`is_directory`, no `kind`, nothing in `paths`, nothing in `files`, no
host slot.  A program can only find out by trying:
`files.read("probe/sub")` raises `io_failed` with *"cannot read
probe/sub"*, which is the answer to a different question and arrives too
late to change what the program does.

**4. `files.list` answers names with no kinds**, so a recursive walk is
not writable.  `list(path) -> list(string)!` sorted, no `.`, no `..`.
To walk, a program must open every entry and infer the kind from the
failure — a syscall per entry *and* a conflation of "it is a directory"
with "the disk is broken".

**5. The flagship example is paying for it now.**
`examples/editor/editor.luc:492` fills its file pane with
`files.list(".")`; `open_selected` (line 518) calls `files.read` on
whatever is selected.  Selecting a subdirectory in the editor's own file
pane produces `cannot read src` in the status bar and no way forward.
The pane cannot even mark a directory with a trailing `/`, because it
does not know.

**6. The host already has the kind and throws it away.**  `host.zig`'s
`loadDirectory` iterates with `std.Io.Dir.Iterator`, whose `Entry` is
`{ name, kind, inode }`, and appends **only `entry.name`** to the
NUL-joined buffer.  The information a walk needs has been measured by
the operating system, handed to loom, and discarded, once per entry,
since `dir_list` was written.

**7. `dir_create` (ABI 16) removed one reason to ask and not the
others.**  It is idempotent and makes parents precisely so that no
caller writes `if not files.exists(p)` in front of it
(`docs/MISSING.md`, `abi.DirCreateFn`).  That argument closes the
*guard* use of `exists`.  It says nothing about the walk, the pane, or
the "is this a directory" question, which are not guards — they are the
program's actual subject.

**8. `p.base()` does not work, and the diagnostic sends you to the wrong
module.**  Value-method sugar on a `string` routes by name construction
into `std.strings` alone (`04_semantics/calls.zig`'s `stringsCall`).
With `import std.paths` in scope:

```text
p.base()
# luce.sema.import: string manipulation lives in the standard library:
#                   import std.strings to use base (docs/STD.md)
```

Take that advice and you get *"string has no method base, and neither
has the strings module"*.  Path spellings are free functions —
`paths.base(p)` — and only free functions.

**9. Struct construction is named-only, and that is ratified language.**
`docs/ARGS.md` D8: *"Construction stays named-only — it does not gain
positional arguments."*  D6 refuses positional-only and keyword-only
markers.  So `Path("src")` — Python's single most-typed filesystem
expression — **is not expressible in Luce and cannot be made expressible
without reopening ARGS.md.**  This is one of the three findings that
refuse the type (D2).

**10. The host gate fires at the *builtin call site*, and a host-less
program cannot print.**  `04_semantics/construct.zig:835` raises
`luce.sema.host` where a gated builtin is called, and every imported
module's bodies are checked whether or not the program reaches them.
So the pure/world module split's one *concrete* payoff is a program that
can compute path names it can never show anybody: `print` is gated too
(`errors_spec.zig:2692`).  **This survives as a recorded wart on D1, not
as a reason to merge the modules** — the split's real payoff was never
that program; it is that a reader can see from the import line which
half of the surface a call came from, and that `paths` is provably
total.

**11. The router already knows a second module — for a different
receiver.**  `listsCall` (`calls.zig:1967`) routes `xs.sort_by(f)` into
`std.lists`, with the import as the feature gate and the arguments
positional, deliberately parallel to `stringsCall`.  So "the router can
learn another module" is settled; what is *not* settled is a second
module on the **same** receiver type, which is where the cost lives
(D3).

**12. Python 3.14 doubled down on the conflation this memo measured.**
The pathlib documentation now states that `exists()`, `is_dir()`,
`is_file()`, `is_symlink()` and the rest **return `False` instead of
raising any `OSError`, including `PermissionError`**, for consistency
with `os.path.exists()`, and directs callers to `stat()` when they need
to tell the cases apart.  Rust went the other way and added
`try_exists()` in 1.63 *because the swallowing was a bug source*.  This
is the one place where being faithful to Python means shipping a known
defect, and this memo says so out loud and declines (D13).

**13. A struct is already a std facade in this tree, methods, `!` and
all.**  `std/os.luc` ships `struct Term`/`IO`/`UI` reached through a
file-scope `const term`; `std/zip.luc` ships `struct Entry` used from
outside as `zip.Entry` and `enum Kind` lives in `std/json.luc`.
`new list(zip.Entry)` was checked and compiles, so `list(files.Entry)`
will.  Every mechanism `Kind` and `Entry` need is shipped today.

**14. `import std.os.pathlib` is refused by the grammar, by name.**
`03_parse/grammar.zig`'s `importDecl` reads one identifier after `std.`
and then reports *"'import std.os' names one standard module: there are
no deeper paths"*.  The std namespace is flat by construction.  With the
`Path` type refused this is no longer load-bearing, but it is recorded
because it is the reason the directive's literal spelling could never
have been taken as written.

**15. The `os.term.ui` shape cannot carry a *type*.**  `os.term.ui`
works because `term` is a `const` holding a `Term` whose `ui` field is a
`UI` — a chain of **values**, carrying methods and nothing else.  A
struct body declares fields and functions only; `struct` inside `struct`
is not a form.  So a namespace-inside-a-module could never have held
`Path` either.

**16. Reserved names cover struct methods.**  Checked:

```text
struct S:
    func print() -> long: ...      # luce.sema.reserved: print is a reserved name
    func read() -> long:  ...      # ok
    func open() -> long:  ...      # ok  (today)
```

`context.reserved_names` holds every free builtin plus the older
container method names, and `signatures.collectFunction` applies it to
*every* function including methods — while the `file` resource's own
`read`/`write`/`flush` are **not** on that list and a user method may
take those names today.  The consequence for this design: **making
`open` a builtin confiscates the word `open` from every struct in the
language**, not just from file scope.  Nothing in the corpus loses a
name (`open_selected`, `opens_block`, `opens_with`, `opening`, `opened`
are other words), but a future `Door.open()` does.  The fix is a
one-paragraph narrowing of an over-broad rule, and it is a "can wait"
item below rather than part of this run.

**17. `open` collides with nothing else.**  Not a keyword
(`02_lex/token.zig`'s table), not a builtin, not in `reserved_names`,
and no `.luc` in the tree declares or binds it.  The one name that goes
is `files.open`, which this design retires into the builtin.

**18. `T?!` is expressible and checks.**  `func kind(p: string) ->
Kind?!` and `func read_line() -> string?!` both compile, `try` unwraps
the `!` to leave the `?`, and `if k == none:` narrows it.  The previous
revision listed this as a shape to check before starting; it is checked.

**19. `entries` is a legal name, and an f-string hole takes a call.**
`print(f"{largest} {largest_size}")` compiles, and so does a method call
inside a hole.

**20. There is no `pass` statement.**  The keyword table has no such
word and a `match` arm needs a body.  The previous revision's flagship
example wrote `other: pass` and would not have compiled.  The
do-nothing arm inside a loop is `continue`.

**21. Chaining onto `open` costs two `try`s and a paren.**  Checked
against today's `files.open`:

```text
let n = try files.open("a.txt").read(buffer)
# luce.sema.fallible: files.open can fail: write 'try files.open(…)' …

let n = try (try files.open("a.txt")).read(buffer)      # ok
```

So Python's `open(p).read()` has no one-line Luce equivalent worth
writing, which is why `files.read(path)` — the whole-file convenience —
stays the everyday spelling and `open()` is the streaming door.

**22. There is no `seek` and no `tell`, and no host slot for either.**
The five handle slots are open, read, write, flush, close
(`docs/BYTES.md` B7).  Python's `"r+"`, `"w+"` and `"a+"` update modes
have nothing to update, which is half of why `FileMode` has three
members and not eight.

**23. `match` does not dispatch over an optional enum.**  Checked:

```text
match try files.kind(p):
# luce.sema.match: match dispatches over an enum, and Kind? is not one;
#   chain if and elif …; bind it to a name and test that
#   (let x = …, then if x != none:), or supply a fallback (… else …)
```

Both spellings the diagnostic names do compile — `let what = try
files.kind(p)` then `if what == none:` then `match what:`, and
`match (try files.kind(p)) else Kind.other:`.  The previous revision's
"the kind question" example used the refused form.  **This is a point in
favour of the design, not against it**: the compiler refuses to let a
program `match` its way past the absent case, which is exactly the
guarantee D11's `?` was chosen for.

**24. list literals exist and pass inline.**  `joined(["a", "b", "c"])`
compiles against `func joined(parts: list(string)) -> string`, with the
literal owned by the call and released after it.  This is what makes
D18's multi-part join writable without variadics.

---

## The decision, argued

Three shapes were weighed.  **A — `os.path` + `open()`, no new type — is
chosen.**  The two it beats are written out because the arguments are
the design's reasons and because both will be proposed again.

### C — a `Path` value type, refused

A plain value struct over one private `string`, carrying pathlib's whole
vocabulary as methods.  It was the previous revision's choice and it is
refused now, on three findings.

**1. A Luce `Path` cannot look like pathlib.**  pathlib's ergonomics are
almost entirely two things Luce refuses on purpose: the `/` operator and
properties.  Written out, the comparison is not close:

```text
# Python                          # Luce, with a Path type
Path("src") / "luce" / "std"      pathlib.path("src").join("luce").join("std")
p.parent.name                     p.parent().name()
Path(root) / f"{name}.luc"        pathlib.path(root).join(f"{name}.luc")
```

The right column shares pathlib's *vocabulary* and none of its *feel* —
it is a method chain, which is precisely the shape a Luce program
already writes for everything else.  And `Path("src")` is not even
available: construction is named-only (evidence 9), so the door is
`pathlib.path("src")`, a lower-case factory beside an upper-case type.
**We would pay for a new type and a conversion at every boundary and not
get the familiarity we bought it for.**  A construct that exists to
imitate something it cannot imitate is a weird exception, and §44 and
§45 both name it.

**2. The boundaries are not few, and they do not shrink.**  A `Path`
type means a conversion at `main`'s `args`, at every `print` and
f-string hole, at `dir_list`'s answer, at every diagnostic that names a
file, at `luce.yaml` and every configuration string a package tool will
read, at `shell.run`'s command, and at every struct field a program
declares for a path today.  The previous revision called these
"enumerable and few".  They are enumerable; they are not few, and the
number grows with every consumer this surface was being fixed *for*.

**3. It buys a second vocabulary for one concept.**  §62.  The previous
revision answered that by deleting the first vocabulary — retiring
`std.paths` and `std.files` entirely — which turned a "new type" run
into a "rewrite every filesystem call in the tree" run for an
ergonomics claim finding 1 disproves.

What the type genuinely offered was **discovery** — one place to find
the whole vocabulary — and §8 — `"hello world".read_text()` never
type-checking.  The first is answered by `docs/STD.md` and by the two
module names being the two Python names.  The second is answered by
never putting filesystem operations on `string` at all, which is D3.

### B — path methods on string receivers, refused

Extend `stringsCall` so a `string` receiver reaches `std.paths` when
imported: `p.base()`, `p.join(x)`, `p.extension()`.  It is the cheapest
design on this page and it is a dead end, for a reason that is worse
than the router cost:

```text
# Python
",".join(parts)          # the SEPARATOR joins the parts
"etc".join("app.conf")   # "app.conf" — a string join, and nothing to do with paths
```

**In Python, `join` on a string receiver is string-join, and its
receiver is the separator.**  A Luce `here.join(name)` meaning path-join
would read, to exactly the audience this design serves, as the *other*
operation with the arguments the *other* way round.  It would actively
mislead the people it was built to help.  That alone closes B; the rest
is confirmation:

- `stringsCall` would become a search over an ordered list of modules,
  and the order is a language rule a reader cannot see in their own
  source.
- `strings` and `paths` would share one namespace forever.  `split` is
  live today; `join`, `count`, `replace` and `parts` are all plausible
  on both sides.  The only sound rule is *a name in two routable modules
  is a compile error*, which means a std addition can break a program
  that never changed.
- `"hello world".delete()` would type-check under the impure half.
  §8's whole point.

Record it as a dead end so it is not re-proposed as an ergonomic win.

### A — `os.path` + `open()`, chosen

**It maps 1:1 with zero new language surface.**  Not as a slogan — as a
table:

| Python | Luce | status |
|---|---|---|
| `open(p)` | `open(p)` | **D4**, new |
| `open(p, "w")` | `open(p, FileMode.write)` | **D5**, new |
| `f.read()` | `f.read_text()` | **D7**, new |
| `os.path.join(a, b)` | `paths.join(a, b)` | ships today |
| `os.path.join(a, b, c)` | `paths.joined([a, b, c])` | **D18**, new |
| `os.path.basename(p)` | `paths.base(p)` | ships today |
| `os.path.dirname(p)` | `paths.dir(p)` | ships today |
| `os.path.splitext(p)[1]` | `paths.extension(p)` | ships today |
| `os.path.splitext(p)[0]` | `paths.stem(p)` — of the last element | ships today |
| `os.path.isabs(p)` | `paths.is_absolute(p)` | ships today |
| `os.path.exists(p)` | `files.exists(p)` | ships, becomes `bool!` (**D13**) |
| `os.path.isfile(p)` / `isdir(p)` | `files.is_file(p)` / `files.is_dir(p)` | **D13**, new |
| `os.listdir(p)` | `files.list(p)` | ships today |
| `os.scandir(p)` | `files.entries(p)` | **D14**, new |
| `os.mkdir` / `os.makedirs` | `files.make_directory(p)` | ships today |
| `os.remove(p)` | `files.delete(p)` | ships today |
| `os.rename(a, b)` | `files.rename(a, b)` | ships today |
| `p.read_text()` (pathlib) | `files.read(p)` | ships today |
| `p.write_text(s)` (pathlib) | `files.write(p, s)` | ships today |

Nine of nineteen rows are already installed and correct.  **And this is
not legacy trivia**: an enormous amount of real Python is written this
way — `os.path.join` remains one of the most-called functions in the
language, and the `import os, os.path` idiom is what most scripts,
build tools and CI glue still use.  A Python programmer arriving at
`paths.join(here, name)` is not being asked to learn anything.

One honest asymmetry, worth naming because a reader will hit it:
**`os.path` is not a pure module.**  `os.path.exists`, `isfile`, `isdir`,
`getsize`, `getmtime` and `realpath` all touch the world while living in
the module named for the *name*.  Luce's split puts those in
`std.files`, which is more honest than Python's and costs a Python
reader exactly one lookup — and which is D1's whole argument, made by
Python's own counterexample.

---

## Decisions

| | decision |
|---|---|
| **D1** | **`std.paths` and `std.files` stay, unmerged, as modules of free functions.**  `paths` is the *name* — every function total, host-free, no `!`, true of any string.  `files` is the *world* — every function `!`, host-gated, and the import line says so.  They are `os.path` and `os`, which is the point.  **The recorded wart** (evidence 10): the split's one *concrete* payoff — path arithmetic in a program compiled with `allow_host` off — is nearly worthless, because such a program cannot `print` the answer either.  The split earns its keep on the two things that remain true: a reader sees from the import line which half a call comes from, and `paths` is provably total, which is a property a merged module could only assert. |
| **D2** | **There is no `Path` type, and there will not be one.**  Refused on the three findings above, the first of which is decisive: a Luce `Path` cannot look like pathlib, because pathlib's feel is `/` and properties and Luce refuses both on purpose.  If it is ever reopened, the trigger is not ergonomics — it is a *type-safety* customer: a program that demonstrably confused a path with a non-path string in a way `!` and the module names did not catch. |
| **D3** | **No filesystem operations on `string` receivers, pure or impure.**  `p.base()` will not route anywhere.  In Python `join` on a string receiver is the separator-join, so borrowing that syntax for path-join would mislead exactly the audience being served; and the impure half would make `"hello world".delete()` type-check.  The router does not change (D19). |
| **D4** | **`open` is a free, host-gated builtin.**  `open(path: string, mode: FileMode = FileMode.read) -> file!`.  It is not an addition to the builtin count: it **replaces `file_open(path, mode: long)`**, which was always this builtin wearing a number instead of a name (`docs/BYTES.md` B7: *"a builtin speaks what the host slot speaks, and the library is where it gets a name"* — the library is now the language).  `files.open`, `files.create` and `files.append_to` retire into it, and `std.files`' own byte conveniences call it.  `open` joins `reserved_names` and the `allow_host` list; `file_open` leaves both.  It is a builtin and not `files.open` because the owner named it as one, and because it is the one filesystem call a program makes without wanting a module in front of it — Python's judgement, arrived at the same way. |
| **D5** | **`FileMode` is a predeclared enum**: three members, `read`, `write`, `append`, backed by `int`, spelled `FileMode.write` with no import anywhere.  Predeclared because it is *the argument of a predeclared function*, exactly as `file` is a type name no program declares; an enum needing `import std.files` would make `open(p, FileMode.write)` cost an import that `open(p)` does not, which is a seam a reader trips on every time.  **There is no binary member**: `open()` cannot vary its return type by mode (no overloading, no dependent types), so the file carries *both* channels and `"b"` becomes a property of the call — `f.read_text()` or `f.read_bytes()` — rather than of the open.  There is no `"r+"`/`"w+"` (nothing to seek, evidence 22) and no `"x"` (no exclusive-create host mode).  Python's six common mode strings collapse to three members because two of the three axes they encode are answered elsewhere or not at all. |
| **D6** | **No mode strings, in any position, ever.**  `open(p, "w")` is the magic value §53 refuses: three characters with no type, no completion, no did-you-mean, and a typo that reaches the host.  A `string` where a `FileMode` is expected is an ordinary type error naming the three members. |
| **D7** | **The `file` gains the Python surface, and the C-shaped pair keeps its names.**  New: `read_text() -> string!`, `read_bytes() -> list(byte)!`, `read_line() -> string?!`, `read_lines() -> list(string)!`, `write_text(text) -> !`, `write_bytes(bytes) -> !`, `write_lines(lines) -> !`.  Unchanged: `read(buffer) -> long!`, `write(buffer, count) -> long!`, `flush() -> !` — `docs/BYTES.md` R4's ratified primitive, **not renamed**, because it is the shape `std.network`'s sockets are meant to arrive wearing and because a rename is cost this design does not need to spend.  The consequence is stated rather than hidden: **`f.read()` is not Python's `f.read()`** — it is the counted read into a caller's buffer — and the diagnostic says so in one sentence: *"file.read fills a byte buffer you own; for the whole file as text write `f.read_text()`"*.  `read_line` answers `none` at end of file, not `""`: Python's empty-string sentinel is exactly the in-band answer `docs/FAILURE.md` refused for `key_read`. |
| **D8** | **The file resource gains a read buffer inside `libluce_rt`.**  `read_line()` cannot be a syscall per byte and cannot be written in Luce (a builtin method has no Luce body), so the one implementation of the semantic buffers, exactly as every stdio does.  `read(buffer)` drains the buffer before it asks the host, so the two views never disagree; writes stay unbuffered, which is what keeps `flush()` meaning what it means.  **No host slot moves** — all of D7 is `libluce_rt` over the five handle slots that already exist. |
| **D9** | **`with` is unnecessary, not missing, and a Python reader is told so once, plainly.**  `var f = try open(p)` — the `file` is a reference-counted resource (`docs/MEMORY.md`), and it closes deterministically the instant its last reference is released, which for a plain local is the end of the scope that holds it.  A Luce program cannot leak a file by forgetting a keyword, because there is no keyword to remember; the close is driven by the reference count, the same machinery that frees a list.  **`close()` is not offered**: the file already closes at its last release, so an *idempotent* `close()` would only add a "closed but not closed-yet" state — a second lifetime story beside the reference count, and the one state §8 says the type must never hold.  The diagnostic teaches it in one sentence: *"file has no method close; the file closes when its last reference is released — the end of the scope that holds it."*  This sentence belongs in `docs/STD.md`, on luce.luciaos.com, and in the diagnostic — three places, because a Python programmer will look in all three. |
| **D10** | **There is no lazy line iteration, and both honest substitutes ship.**  `for line in f` is a generator, and Luce does not have generators and will not.  So: `for line in try files.read_lines(path):` — or `f.read_lines()` on an open file — reads exactly like Python and costs the whole file resident; a `while` over `f.read_line()` streams in constant memory and costs three lines and a `?`.  Both are in the worked programs below, and the memo names the cost of each rather than picking one and hiding the other. |
| **D11** | **`files.kind(path) -> Kind?!` is the primitive question, and `Kind` is an enum in `std.files` with three members: `file`, `directory`, `other`.**  Three because that is the set Go, Rust and Python each expose to ordinary code and the set a program branches on: recurse, read, or leave alone.  `other` is honest and total — a socket, a device, a fifo, a filesystem that will not say — and it is one member rather than Zig's eleven because a program that must tell a block device from a door is writing an operating system, not using one.  A member added later is a compile error at every `match` that missed it (`docs/ENUMS.md` R1), so the set reopens as a superset and costs nothing to keep small.  `none` means *nothing is there* — the same reason every time, no message worth carrying — and `!` means *the world would not say*: a refused parent, a disk that failed.  Two different answers, one place for each (`docs/FAILURE.md`).  **This is the design's one addition to Python's vocabulary**, and it is what removes the two-syscall race the three predicates otherwise are. |
| **D12** | **`Kind` describes what the path *names*, with links followed.**  `stat`, not `lstat` — the same thing `open`, `read`, `write` and `delete` already mean, so a `kind` that answered otherwise would describe a different file from the one the next line touches.  A **dangling** link is therefore `none`: nothing is there to read, which is exactly what the program will find.  `symlink` is deliberately not a `Kind` member. |
| **D13** | **`files.exists`, `files.is_file` and `files.is_dir` are `bool!`** — Python's three names, each one line over `kind`, each fallible so a refusal has somewhere to go.  `is_file` and `is_dir` are new; `exists` keeps its name and changes its type.  **Here Luce is deliberately better than Python and says so in `docs/STD.md`**: Python 3.14 made all three swallow every `OSError` including `PermissionError` (evidence 12), and Rust shipped `try_exists()` in 1.63 because that swallowing was a bug source.  A Luce program that wants Python's behaviour writes `catch false` — three visible words, and `catch` is greppable on purpose. |
| **D14** | **`files.entries(path) -> list(Entry)!`, where `Entry` is `{ name: string, path: string, kind: Kind }`, sorted by name.**  This is `os.scandir` — whose `DirEntry` carries exactly `name`, `path` and the kind — and the two fields are not redundancy, they are the two things a caller wants: a file pane prints `name`, a walk pushes `path`, and neither writes a join.  **`files.list` survives** as `os.listdir` and becomes one line over `entries`, so there is one host path and two surface names, which is precisely why Python keeps both and PEP 471 says so.  Sorted, because the host's order is whatever the file system felt like and two machines holding the same files answer differently. |
| **D15** | **The kinds in a listing are fetched per entry, inside `std.files`, and that is an implementation detail behind D14's signature.**  `files.entries` is `dir_list` plus one `path_kind` per name: N+1 host calls where the host could answer in one — and when that matters, an appended `dir_entries` slot makes it one call **and not one Luce program changes**, because the signature already carries the kind.  §30 keeps the option, §23 puts the cost in one module instead of every caller, §63 spends one slot now instead of two.  Why it is not merely free today: the kind an OS directory iterator hands over is the *link's* kind and may be "unknown" on some filesystems, so a host filling `dir_entries` must `stat` those entries to keep D12's one meaning. |
| **D16** | **One new host slot: `path_kind`.**  `PathKindFn(context, path, path_length, kind: *i64) -> Answer`, appended, optional, fail-closed like every service.  `yes` with a kind code — 0 nothing, 1 file, 2 directory, 3 other — is the world answering; `no` is the world refusing, which the program meets as `io_failed`.  **The absent case is `yes` with 0 and not `no`**, because `abi.Answer` cannot carry the distinction D11 turns on and the out-parameter can: widening the payload rather than inventing a fourth `Answer` keeps `abi.Answer` meaning what it means everywhere else.  `file_exists` is retired from use in the same bump, exactly as the whole-file text slots were at `docs/BYTES.md` R2 — the vtable stays append-only, nothing reorders, and no artifact at the new version indexes it. |
| **D17** | **New intrinsics: `path_kind`, and the seven file-surface methods of D7.**  `file_exists` retires; `file_open` is respelled `open` and keeps its lowering.  `path_kind` lowers to `luce_rt_path_kind` answering a boxed `Kind?`, with the runtime raising the `io_failed` itself and naming the path (`docs/BYTES.md` B8/B9's shape unchanged, because the runtime is the side that knows the path).  `file_read`, `file_write` and `file_append` stay exactly as they are — they are what `files.read`, `files.write` and `files.append_text` already lower to. |
| **D18** | **Multi-part join is `paths.joined(parts: list(string)) -> string`.**  `paths.join(head, tail)` keeps its name, its two-argument shape and its exact semantics; `joined` is the fold over it, left to right, with the same seam and absolute-part rules, and an empty list answering `""`.  This is the one place `/`-chaining is genuinely missed, and it is missed *by the two-argument function*, not by the absent type: `paths.join(paths.join(root, "build"), name)` is the shape that pushed the previous revision toward `Path`.  The Luce spelling is a list literal, which is checked and reads well (evidence 24): `paths.joined([root, "build", name + ".out"])`.  **Not variadics** — Luce has none and one library function is not the customer that should introduce them (`docs/ARGS.md` D6's shape).  **Not defaulted trailing parameters** — `join(a, b, c = "", d = "")` would work, because `""` is already `join`'s identity element rather than a magic value, but it caps the arity at whatever number the author guessed, which is §53 wearing a different hat.  `joined` is named for what it answers, one letter from `join`, and the pair reads as a pair. |
| **D19** | **The string-method router does not change, and its diagnostic does.**  `p.base()` on a `string` will not route anywhere, and the current message sends the reader to `std.strings`, which does not have it either (evidence 8).  The honest sentence names the module that does: *"string has no method `base`; path spellings are free functions — write `paths.base(s)` with `import std.paths`"*.  Two sentences in `calls.zig`, independent of everything else here. |
| **D20** | **`files.make_directory` keeps its idempotent, parents-making meaning and takes no arguments.**  Python's `mkdir(parents=False, exist_ok=False)` makes every caller pass the pair they always want; §25 says the module should make the right choice.  It means "there is a directory at this path when I return", so a directory already there is success, and a *file* holding the name is still `io_failed`. |
| **D21** | **Two line deviations from Python, both deliberate, both stated in `docs/STD.md`.**  `read_lines` and `read_line` **strip** the newline; Python keeps it, and every Python program that reads lines opens with `.rstrip()`.  `write_lines` **adds** a newline after each; Python's `writelines` concatenates with no separator, which is the single most surprising method on the file object.  Each choice is what every caller means and each is §7 — an error defined out of existence rather than a hazard passed on.  The cost is named beside the method: a program that must know whether the file ended in a newline cannot learn it from `read_lines`, and should read it whole.  `std.files`' existing `read_lines`/`write_lines` already behave this way; D21 makes it a stated rule and gives the file methods the same one. |
| **D22** | **`files.append_text` keeps its name, and the wart is recorded, not fixed here.**  `append` is a reserved container-method name and nothing user-declared may take one, module-qualified or not (evidence 16).  `docs/MISSING.md` records it and continues to; the narrowing that would fix it is a "can wait" item with its own trigger, because it is a language-rule change and this run should not carry one. |

---

## The kind question, argued

Three shapes were weighed, and the answer is unchanged by which surface
won, because Python has all three too.

**Separate predicates alone** — `is_file(p)`, `is_dir(p)` and nothing
else — lose on two counts.  They are two host calls to answer one
question about one path, which is a race with itself: a name can change
between them.  And each must decide what to answer when the world
refuses, which puts evidence 2's lie in two places instead of removing
it — which is exactly what Python did, twice, most recently in 3.14.

**A `stat`-shaped answer** — a struct with size, times, mode — is
refused in Non-goals and does not compete: every field is a promise the
ABI must keep on every platform, and no current customer wants one.

**One question, one answer, three outcomes** wins because the language
has exactly three ways to answer and no two of them mean the same
thing.  The predicates then sit *on top* of it, one line each, keeping
the familiar names without reintroducing the lie.  The spelling is
checked (evidence 23) — `match` will not dispatch over `Kind?`, so the
absent case is answered *before* the match, which is the guarantee the
`?` was chosen for:

```text
let what = try files.kind(p)
if what == none:
    print(p + " is not there")
    return
match what:
    directory:
        walk(p)
    file:
        visit(p)
    other:
        skip(p)
```

where the caller does not care why:

```text
if files.is_dir(p) catch false:
    ...
```

and where a walk wants one branch and a default:

```text
match (try files.kind(p)) else Kind.other:
    directory:
        pending.append(p)
    file:
        visit(p)
    other:
        continue
```

`none` and `!` are not two spellings of failure being awkwardly
reconciled; they are the two things that can actually happen, and
FAILURE.md's rule assigns each without a tie-break.  `catch false` is
the deliberate discard, and it is three visible words rather than a
library's silent default.

---

## Listing with kinds, priced both ways

| | one call per entry (D15 today) | one call for the listing (`dir_entries`, later) |
|---|---|---|
| host calls for N entries | N + 1 | 1, plus one per link or unknown-kind entry (D12) |
| ABI cost | none beyond `path_kind` | one more appended slot, one more retired (`dir_list`) |
| runtime cost | none — `entries` is a Luce loop | a second parallel run (one kind byte per entry) beside the NUL-joined names |
| what a Luce program writes | `files.entries(p)` | `files.entries(p)` — **identical** |

A store of five thousand files costs five thousand extra `fstatat`
calls, on the order of milliseconds; PEP 471's measurements say that
becomes 2–20× on a deep walk once the tree is large enough to matter.
So the fast path is worth having and is not worth having *first*: it
changes no signature, no spec, no example and no document, which is the
definition of something that can wait.  What cannot wait is D14, because
after `luce install` and a build tool exist, changing the listing's
return type stops costing one line.

---

## The same program, both languages

*Walk a directory tree, read every `.luc` file, report the largest.*

### Python — `os` + `os.path` + `open`

```text
import os
import os.path

def main(root):
    pending = [root]
    largest, largest_size = None, 0
    while pending:
        here = pending.pop()
        for entry in os.scandir(here):
            if entry.is_dir():
                pending.append(entry.path)
            elif os.path.splitext(entry.name)[1] == ".luc":
                text = open(entry.path).read()
                if len(text) > largest_size:
                    largest, largest_size = entry.path, len(text)
    print(largest, largest_size)
```

### Luce, in this design

```text
import std.files
import std.paths

func main(args: list(string)) -> !:
    var pending = new list(string)
    pending.append(args[0])

    var largest = ""
    var largest_size: long = 0

    while len(pending) > 0:
        let here = pending[len(pending) - 1]
        pending.remove(len(pending) - 1)
        for entry in try files.entries(here):
            match entry.kind:
                directory:
                    pending.append(entry.path)
                file:
                    if paths.extension(entry.name) == ".luc":
                        let text = try files.read(entry.path)
                        if len(text) > largest_size:
                            largest = entry.path
                            largest_size = len(text)
                other:
                    continue

    print(f"{largest} {largest_size}")
```

**The headline: the two programs are the same program.**  Same walk,
same stack, same fields on the same entry, same names on the same
functions — `entry.path`, `entry.name`, `splitext`/`extension`,
`scandir`/`entries`.  Four differences, and every one of them is a
general Luce rule rather than a filesystem decision:

- `try` in front of the two world calls, because `!` is where the
  boundary lives (D1).  Python's are the same two calls; it just does
  not say so.
- `match entry.kind` where Python writes `entry.is_dir()`, because D14's
  entry *carries* the kind instead of costing a second syscall — and
  because a member added to `Kind` later becomes a compile error here
  rather than a silently skipped branch.
- `files.` and `paths.` prefixes where Python writes `os.` and
  `os.path.` — the same two modules, one character shorter.
- `largest_size: long`, `new list(string)`, and `pending.remove(…)`
  instead of `pop()` — static types and this language's list, neither of
  which is this design's business.

There is **no** conversion, no factory, no `.text()`, no wrapper type,
and nothing on either side that the other side does not have.

*Now write files.*

### Python

```text
import os
import os.path

def save(path, lines):
    with open(path, "w") as f:
        for line in lines:
            f.write(line + "\n")

def append_note(path, note):
    with open(path, "a") as f:
        f.write(note + "\n")

def stage(root, name, text):
    target = os.path.join(root, "build", name + ".out")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w") as f:
        f.write(text)
    return target
```

### Luce, in this design

```text
import std.files
import std.paths

func save(path: string, lines: list(string)) -> !:
    try files.write_lines(path, lines)

func append_note(path: string, note: string) -> !:
    try files.append_text(path, note + "\n")

func stage(root: string, name: string, text: string) -> string!:
    let target = paths.joined([root, "build", name + ".out"])
    try files.make_directory(paths.dir(target))
    try files.write(target, text)
    return target
```

and the same `save` written through the builtin, which is what a program
does when the lines arrive one at a time rather than all at once:

```text
func save(path: string, lines: list(string)) -> !:
    var f = try open(path, FileMode.write)
    for line in lines:
        try f.write_text(line + "\n")
```

**No `with`, no `close()`, and nothing leaks.**  The end of `save`
closes its file — not because `save` remembered to, but because there is
no way for it to forget: the file is reference-counted, and its last
release closes it, the same machinery that frees a list.  Python's
`with` is a per-call-site opt-in to the guarantee Luce gives
unconditionally, which is why the Luce column here is *shorter* than the
Python column rather than longer.  `paths.joined([...])` is D18 in the
one place Python writes `os.path.join(a, b, c)`, and
`files.make_directory` needs no `exist_ok=True` because §25 already
chose (D20).

*And read a file line by line, both ways Luce offers.*

```text
# Python
with open("notes.txt") as f:
    for line in f:
        print(line.rstrip())
```

```text
# Luce — the whole file, and the closest thing to `for line in f`
for line in try files.read_lines("notes.txt"):
    print(line)
```

```text
# Luce — streaming, constant memory, when the file may be large
var f = try open("notes.txt")
while true:
    let line = try f.read_line()
    if line == none:
        break
    print(line)
```

The first costs the whole file resident and reads like Python's — minus
the `.rstrip()`, which D21 already did.  The second costs three lines
and a `?` and never holds more than one line.  Python's lazy `for line
in f` is both at once because it is a generator; Luce has no generators,
so it offers the two halves separately and names the price of each
rather than pretending one of them is the other (D10).

---

## Where this cannot be Python, and what it is instead

Seven places, and no others.  Each is a language fact, and each belongs
in `docs/STD.md` where a reader meets it.

| Python | why not | what Luce writes |
|---|---|---|
| `open(p, "w")` — mode strings | §53 magic values; Luce has enums | `open(p, FileMode.write)` |
| `open(p, "rb")` answering a different type | no overloading, no dependent types | one `file` answering `read_text()` **and** `read_bytes()` |
| `with open(p) as f:` | the reference count already closes it — Luce being better, not shorter | `var f = try open(p)` |
| `f.close()` | releasing the last reference closes it; an explicit `close()` is a second lifetime story (§8) | let the last reference go — for a local, the end of its scope |
| `f.read()` | `read` is the ratified counted read into a caller's buffer, shared with sockets | `f.read_text()`, with the diagnostic saying so |
| `for line in f:` | no generators, permanently | `files.read_lines(p)` / `f.read_lines()`, or a `while` over `read_line()` |
| `os.path.join(a, b, c)` | no variadics, and no `/` operator | `paths.joined([a, b, c])` |
| `f.readline()` answering `""` at EOF | FAILURE.md refuses in-band sentinels | `read_line() -> string?!`, `none` at the end |

And three where Luce is deliberately *not* Python because Python is
wrong, each with the citation:

- **`files.exists` answers `bool!`.**  Python 3.14 swallows
  `PermissionError`; Rust added `try_exists()` because that was a bug
  source (evidence 12).  `catch false` spells Python's behaviour in
  three visible words.
- **`read_lines` strips and `write_lines` separates** (D21).
- **`files.make_directory` needs no arguments** — Python's
  `parents=True, exist_ok=True` is the pair every caller passes (§25).

---

## What changes in the corpus

Small, because nothing is renamed and nothing is deleted except three
doors that become one builtin.

| today | tomorrow |
|---|---|
| `files.open(p)` | `open(p)` |
| `files.create(p)` | `open(p, FileMode.write)` |
| `files.append_to(p)` | `open(p, FileMode.append)` |
| `files.exists(p)` as a `bool` | `files.exists(p)` needs `try` or `catch` |
| `files.list(p)` in a walk or a pane | `files.entries(p)`, and the caller gains the kinds it was missing |
| everything else | **unchanged** |

Site by site: `zipper.luc:116`'s `if not files.exists(into)` becomes
`if (files.kind(into) catch none) != Kind.directory`, which catches the
file-in-the-way case the current line waves through; `editor.luc:492`'s
file pane moves to `files.entries(".")` and can finally mark directories
and refuse to `read` one; `editor.luc`'s builtin keyword table loses
`file_exists` and `file_open` and gains `open`; `host_spec.zig`'s
`file_exists` row goes; `docs/STD.md`'s `files` section gains `kind`,
`entries`, `is_file`, `is_dir` and the `open` note, and its `paths`
section gains `joined`; the site's builtin and std reference pages
follow.  `journal.luc`, `dice.luc`, `wordcount.luc`, `zip.luc` and
`json.luc` are **untouched** — which is the clearest single measure of
what refusing the type saved.

---

## What this costs

- **`abi.version` 16 → 17.**  One appended slot (`path_kind`), one
  retired from use (`file_exists`).  **The whole file surface of D7
  costs no slot**: it is `libluce_rt` over the five handle slots
  `docs/BYTES.md` B7 installed.  A version bump is a rebuild of every
  artifact there is, and a stale one is refused by name rather than run.
- **`format_version` 41 → 42.**  Appended: `path_kind` and the seven
  file-surface intrinsics.  Retired: `file_exists`.  Respelled:
  `file_open` → `open`, same lowering.  Plus one predeclared enum row
  for `FileMode`.  No migration; modules recompile.
- **`libluce_rt`:** `luce_rt_path_kind`, seven file exports, and **a read
  buffer on the file object** (D8) — the one genuinely new piece of
  runtime, and the one every stdio in the world already has.  Both
  engines reach it through the same exports, so the oracle threads none
  of it separately.
- **The builtin table and its gate change**: `open` in, with an
  enum-typed defaulted parameter (`term_style` already proves defaulted
  builtin parameters); `file_open` and `file_exists` out.  `allow_host`'s
  list in `CLAUDE.md` and `docs/MODES.md` follows.  `open` joins
  `reserved_names`, which costs the word to every struct in the language
  (evidence 16) — no corpus name, one future `Door.open()`.
- **Stage 4 learns one predeclared enum** — the first.  A row in the enum
  table stage 4 already consults, a reserved word, three interned member
  names; MIR sees an integer, `libluce_rt` sees nothing.
- **No new type, no conversions, no boundary rewrite, no router change,
  no rename of the byte primitives, and no module deleted.**  This is the
  paragraph the previous revision could not write, and it is the price
  difference between the two designs.
- **`std/`:** `files.luc` gains `kind`, `entries`, `is_file`, `is_dir`,
  `Kind`, `Entry`, and loses `open`/`create`/`append_to`; `exists`
  changes type.  `paths.luc` gains `joined`.  The std table does not move.
- **Both engines in lockstep**, as always, and the artifact-refusal row
  for the bump is written the way `docs/BYTES.md`'s was.
- **Specs:** two-engine rows for each `Kind`, for absence, for a refused
  parent, for a dangling link, for a listing carrying kinds, for
  `exists`/`is_file`/`is_dir` over a refused parent, for the host with
  `path_kind` absent (`host_unavailable`, fail-closed); for `open` in
  each mode, including opening a missing file for reading and reading
  from a file opened for writing; for `read_line` across a buffer
  boundary and at end of file; for `read_text` on bytes that are not
  text; for `write_lines` on an empty list; for `paths.joined` on the
  empty list, one part, an absolute part in the middle, and seams that
  collapse — and the two path invariants continue to be walked.

---

## Sequencing

**Before the first real consumer.**  This is one movement and should
land in one run, on both engines, with specs at each step — before
`luce install`, before a build tool, before the registry's server side.
`files.list` has **one** caller today and `files.exists` has **two**.
After `luce install` ships, changing the listing costs everyone forever
and the wart in `exists` becomes permanent by weight rather than by
argument.

**Do not race the version numbers.**  This run moves both `abi.version`
and `format_version`.  `docs/BITWISE.md`'s lesson, repeated by
`docs/BYTES.md` and `docs/UNION.md`: two runs through one version number
is the way to lose both.  Anything else in flight that moves either
waits or goes first.

**Land it in this order**, because each step is provable on its own:

1. **`paths.joined`** — pure Luce, pure text, no ABI, no host.  It is
   the one piece with no dependency on anything below it and it can be
   proved and shipped on its own.
2. **`path_kind`** — slot, intrinsic, runtime export, both engines,
   specs.  Nothing user-visible yet.
3. **`Kind`, `files.kind`, `is_file`, `is_dir`, and `exists` becoming
   `bool!`** — the three predicates over the one primitive, and the two
   corpus sites that meet the type change.
4. **`Entry` and `files.entries`**, with `files.list` rewritten over it;
   the editor's file pane and zipper's guard.
5. **`FileMode` and `open`** — the predeclared enum, the builtin
   replacing `file_open`, `files.open`/`create`/`append_to` retired and
   `std.files`' byte conveniences rewritten over the builtin.
6. **The file surface** (D7, D8) — the seven methods and the read
   buffer, with the `f.read()` diagnostic.
7. **Documentation last, and all at once**: `docs/STD.md`, the `with`
   sentence in three places, the site's builtin and std pages, and
   `docs/MISSING.md`'s two open items updated.

**Can wait, in this order.**

1. **The `dir_entries` fast path (D15).**  Pure optimization behind an
   unchanged signature.  Its trigger is a measured walk — the package
   store's, most likely — and `bench/` is where the number goes.
2. **Narrowing the reserved-name rule.**  A free builtin's name would be
   reserved for file-scope declarations, imports' bindings and locals —
   where a user declaration stands between a call site and the builtin —
   and not for *methods*, where `p.open()` and `open(p)` are different
   syntax.  The tree already lives by the narrow rule for `read`,
   `write` and `flush` (evidence 16).  It would let a `Door` have an
   `open`, and it would close `files.append_text`'s wart (D22).  Its
   trigger is the second program that loses a name to it; it is a
   language-rule change and this run should not carry one.
3. **`paths.relative_to` / containment.**  Its trigger is the *second*
   program that hand-writes a containment gate.  Zipper is the first and
   its gate is half archive-format policy; a lexical answer is unsound
   across symlinks and the memo that lands it must say so.
4. **`files.walk`.**  Its trigger is two programs walking with the same
   policy.  Python needed `top_down=`, `on_error=` and
   `follow_symlinks=` to serve everybody's, which is the argument for
   waiting.

---

## For ratification

Five, and only the ones that genuinely need the owner.  Everything else
above had one honest answer and was taken as a decision rather than
spending a question on it.

| | question | recommendation |
|---|---|---|
| **R1** | **Is `FileMode` predeclared, or does it live in `std.files`?**  Predeclared makes `open(p, FileMode.write)` need no import and costs the language its first predeclared enum.  Std-resident costs no language change and makes the two-argument call require an import the one-argument call does not. | **Predeclared** (D5).  A builtin whose *first* argument needs nothing and whose *second* needs an import is a seam a reader trips on every time, and `open` is the most-called function in this design.  `file` is already a type name no program declares; `FileMode` is the same kind of thing — the argument of a predeclared function rather than a library's idea.  If the owner would rather not open that door, the fallback is `files.FileMode` and the note in `docs/STD.md` that the mode needs `import std.files`; it is a wart, not a defect. |
| **R2** | **Does `close()` exist?**  Python programmers will type it.  Options: refused, with the diagnostic teaching that the last release closes it (recommended); or an idempotent no-op-if-closed, which is Python's actual behaviour. | **Refused** (D9).  The file closes when its last reference is released, so a `close()` has nothing to add but a hazard: an idempotent one needs a "closed but not closed-yet" state, a second lifetime story beside the reference count and the one state §8 says the type must never hold.  The sentence a Python reader needs is one sentence and it goes in three places: the diagnostic, `docs/STD.md`, and loom's own documentation. |
| **R3** | **Do `f.read`/`f.write` keep their C-shaped meaning, or are they renamed `read_into`/`write_from` so `f.read()` can be Python's?**  This memo keeps them (D7) and pays for it with a diagnostic.  **This is the one place I think the ruling could reasonably go the other way**, so it is a question rather than a decision. | **Keep them.**  `docs/BYTES.md` R4 ratified the primitive, `std.network`'s sockets are meant to arrive wearing it, and on a socket `read_into` is right while `read_text` is meaningless — so the pair that must stay stable is the primitive, and the conveniences are the ones that should carry the qualifier.  The cost is a Python programmer typing `f.read()` and getting a type error; the diagnostic answers it in one sentence and costs nothing else.  The counter-argument is real and short: `f.read()` is *the* method on a Python file, and a rename is a contained change to one table, `std.files`, `std.zip` and the byte specs.  If the owner weights the first-hour experience above the socket family, rename. |
| **R4** | **Does `files.list` survive beside `files.entries`?**  Python keeps `os.listdir` and `os.scandir` and PEP 471 explains why; §62 says one vocabulary for one concept. | **It survives** (D14), as one line over `entries`.  There is one host path, one implementation and one sort order; the second name costs a row in `docs/STD.md` and saves every caller that only wants names from writing a comprehension.  It is also the only `os.` row in the 1:1 table that already ships correctly, and removing it would be breaking something to prove a point. |
| **R5** | **Does `Entry` carry both `name` and `path`, or only one?**  Both is `os.scandir`'s shape and is mild redundancy; `path` alone is smaller and makes a file pane write `paths.base(entry.path)`; `name` alone makes every walk write a join. | **Both** (D14).  It is exactly `os.scandir`'s `DirEntry`, the two fields serve the two real callers measured in this tree (the editor's pane wants `name`, a walk wants `path`), and the join it deletes from the top of every walk loop is the one that was getting written wrong.  The redundancy is one string per entry in a list that is already one allocation per entry. |

---

## Non-goals — what must not be built, and why

- **A `Path` type.**  D2.  Reopened only by a type-safety customer, never
  by an ergonomics argument.
- **A filesystem abstraction layer, a VFS, or a pluggable backend.**
  `LuceHost` *is* the seam, and it is already narrow, optional and
  fail-closed.  A second layer inside the language would be §50's
  premature extensibility with a §42 pass-through in front of it.
- **`stat`.**  Size, mtime, mode, inode, uid, gid, nlink.  Each is a
  promise the ABI must keep on every platform, and no current customer
  wants one.  The two usual ones are answered elsewhere: the compile
  cache keys on the program's *content* hash (`docs/PACKAGES.md`), and
  "how big is it" is answered by reading it, since a size read before a
  read is the same race `exists` was.  If a customer names a field — a
  `luce install` that must not re-download, an `ls -l` in loom — that
  field, and only it, gets designed.
- **`seek`, `tell`, `truncate`, and the `"r+"`/`"w+"` modes.**  No host
  slot and no customer; a random-access file is a different resource
  from a stream and should arrive as one, with its own memo.
- **`encoding=`, `newline=`, `errors=`.**  A Luce `string` is validated
  UTF-8 by construction (`docs/BYTES.md`); there is no second encoding to
  name, and bytes that are not text are `read_bytes`'s business.
- **Watchers** (inotify, FSEvents, kqueue).  A callback protocol, a
  thread nobody spawned, a platform matrix, and an event model the
  language does not have — the host never calls *into* a program.
- **Globbing** (`glob`, `fnmatch`, `rglob`).  A glob is a matcher and a
  matcher is text, so it is `strings` work over `files.entries`, written
  in Luce where its dialect is visible.  Baking one in bakes a dialect
  (`**`?  `{a,b}`?  case?) into the host boundary.
- **Permissions, `chmod`, ownership, ACLs.**  `abi.Answer` is
  `yes`/`no`/`exhausted` on purpose, and a permission model is an
  operating-system decision `docs/V2.md` deferred with capabilities.
- **Symlink creation, reading, or resolution** — `symlink`, `readlink`,
  `realpath`.  D12 gives the whole symlink surface a program needs: a
  link is what it points at, and a broken one is nothing.
- **Recursive helpers** — `shutil.copy`, `move`, `rmtree`, `copytree`.
  Each is a loop over the primitives plus a policy (follow links?  stop
  on the first error, or carry on?  preserve what?), and a recursive
  delete in a standard library is a foot-gun with no undo.  Once `kind`
  exists these are ten legible lines in the program that wants them, with
  its own policy in view.
- **Current-directory calls** — `os.getcwd`, `chdir`, `abspath`,
  `realpath`.  §31 and §51: a program that can move its own cwd makes
  every relative path in it ambiguous, including the ones already in
  flight.  loom resolves relative to the directory it was started in and
  says so.
- **`os.path.normpath` and `.`/`..` cleaning.**  Deferred with
  `relative_to`, same trigger, same paragraph: a lexical answer is
  unsound across symlinks and should arrive with the customer that can
  say which unsoundness it accepts.
- **Temporary files and directories.**  A naming policy, a cleanup
  policy, and a security argument about `/tmp`, for no customer.
- **A second path separator, drive letters, or UNC paths** — and so no
  `splitdrive`, `altsep` or `os.sep`.  A path says `/` and says so out
  loud.  When a Windows host is real, it is a memo, not a flag.

---

## As built (2026-08-12) — the `kind` half

Steps 1 to 4 of Sequencing, in one run, on both engines, with specs at
each step.  The memo left several things open that the code had to
answer, and it got two of its own sentences wrong; each is here with
the reason, and each has a spec.

| | decision, and where it is proved |
|---|---|
| **B1** | **`path_kind` is an ordinary host-slot intrinsic, not a `luce_rt_*` export.**  D17 said it would lower to `luce_rt_path_kind` "with the runtime raising the `io_failed` itself", by analogy with the byte channel.  The analogy does not hold: the byte channel lives in `libluce_rt` because a handle's **close** happens at a scope's end, where no generated code is standing to hand a host table in (`docs/BYTES.md` B6).  Nothing about asking what is at a path happens outside a standing engine, so it takes `dir_list`'s and `dir_create`'s shape instead — the engine calls the slot and raises — and `libluce_rt` learns nothing at all.  The observable behaviour is D17's; only the seam moved. |
| **B2** | **The intrinsic answers a `long!` and the names live in `std.files`.**  Zero nothing, 1 file, 2 directory, 3 other.  The runtime is deliberately never handed the program's type table, so an enum could not cross the boundary — the same sentence that makes the byte channel's mode a number here and a named door there.  `files.kind` is the four-way `if` that turns the number into `Kind?`, and it is the only place the numbers are written down on the language side. |
| **B3** | **The refusal's verb is `inspect`**, appended to `vocabulary.FileAct`: *"cannot inspect locked/inside.txt"*.  The act needed a name because both engines have to spell the same sentence, and "cannot read" would have been a lie about a call that never read anything.  Deliberately not the absent case — nothing is there travels in the value. |
| **B4** | **`files.list` is *not* one line over `entries`.**  D14 said it would be, for "one host path and two surface names"; both spellings already have one host path, because both are `dir_list`.  What "one line over `entries`" would have added is one `path_kind` per name for a caller that asked for names, plus a behaviour change nobody wanted — an entry that vanished mid-listing would silently drop out of `os.listdir`.  So `list` is `dir_list` sorted, exactly as it was, and `entries` is the one that pays for kinds.  This is the memo's own §23 read the other way: the cost belongs in the module, and here the module is where it is *avoided*. |
| **B5** | **`entries` drops an entry whose kind has become nothing**, and says so where it is declared.  The listing named it and it is no longer there, so there is nothing to report; a world that *refuses* to say is a different matter and travels in the error channel like everything else.  The alternative — an `Entry` with no kind — would have put an optional in the field that exists to remove one. |
| **B6** | **`Entry.path` is `paths.join(listed, name)`, so `entries(".")` answers `./notes`.**  Exactly `os.scandir`'s behaviour, and the reason `path` is a field at all: the join it deletes from the top of every walk loop is the one that was getting written wrong.  The editor, which lists `"."`, is the customer that showed this needs a matching *un*-join — see B9. |
| **B7** | **`file_exists` is retired everywhere: the builtin, the intrinsic, the reserved name, and the slot's contents.**  The `abi.Host` field keeps its position and its type — the table is append-only and nothing reorders — and every host in this tree leaves it null, exactly as the whole-file text slots were left at version 12.  It gains a `retired_builtins` row, which grows a table whose comment says "never to grow": the forcing reason is that it was a published builtin for the whole of v2 and is on the documentation site, so `unknown function file_exists` would point nowhere.  The row names both replacements and the `try`/`catch` the type change requires. |
| **B8** | **`close()` is refused by name rather than by did-you-mean**, with the answer and the `with` sentence in the same breath: *"file has no method close: the file closes when its last reference is released — the end of the scope that holds it — which is why there is no 'with' either"*.  D9 asked for the sentence in three places and it is in three: this diagnostic, `docs/STD.md`, and luce.luciaos.com's `std/files` page. |
| **B9** | **The editor's file pane walks into a directory** rather than refusing one, which is the choice D-nothing left open and evidence 5 asked for.  A pane that can *see* a row is a directory is a pane whose reader will press Enter on it, and "src is a directory" leaves them exactly as stuck as *"cannot read src"* did.  So `State` gained a `directory`, the pane gained a `../` row when it is not at the top, and directories are marked with a trailing `/` — the mark and the walk are one decision.  One thing the walk forced: `State.under(here, name)` answers the bare name when the pane is showing `"."`, because `"./notes.txt"` and `"notes.txt"` are one file and a pane that renamed it opened a second buffer onto it.  That is B6's join and its inverse, and it is the only place in the tree that needs one. |
| **B10** | **Zipper asks `files.is_dir`.**  `if not files.exists(into)` was right by accident, as evidence 1 measured: a *file* in the way passed the gate and the run failed later, inside the extraction loop, with a message about a directory nobody had asked for.  It now refuses up front and leaves the file untouched, which was checked by hand against a real tree as well as in the suite. |

**What the memo checked and the build confirmed.**  Every shape
evidence 14–24 measured held: `T?!` compiles and `try` leaves the `?`
(`files.kind`); `match` refuses `Kind?` and the bind-test-match
spelling is what `std.files`' own doc comment teaches; a list literal
passes inline to `paths.joined`; `entries` is a legal name; there is
no `pass`.  Two shapes the memo did not check and the build found:
struct construction is `Entry(name = …)` and not `Entry(name: …)`,
and a `catch` **block** cannot initialize a binding, so the editor's
listing declares `found` first and guards the assignment.

**The version numbers.**  `abi.version` 16 → **17** (one appended
slot, one retired from use), `format_version` 41 → **42**
(`file_exists` out of `mir.Intrinsic`, `path_kind` in after
`dir_create`, so every tag between `file_write` and the end
renumbers twice over).  The wire fingerprint moved with them and its
comment records why.

**The four lockstep sites**, as always: `src/apps/host.zig` (one
`statFile` with links followed; `FileNotFound` and `NotDir` are the
only two failures that mean "nothing is there", everything else is a
refusal), `src/luce/specs/hosts.zig` (a `kinds` script and a
`refused_kinds` prefix list on `World`, read by both test hosts),
`src/luce/interpreter/machine.zig`, and `src/luce/08_llvm/lower.zig`.
A host that withholds the slot traps `host_unavailable` on both
engines, and `host_spec.zig` has the row.

### What is left, precisely

D4 through D8 and their consequences — **`open()`, `FileMode`, and the
seven file-surface methods** — are untouched.  Concretely, a second
run owes:

- `FileMode` as the language's **first predeclared enum** (D5, R1):
  a row in the table stage 4 already consults, a reserved word, three
  interned member names.  This is the only language-surface change in
  the remainder and the reason it was not carried here.
- `open(path, mode = FileMode.read) -> file!` as a free host-gated
  builtin replacing `file_open` (D4, D6), with `files.open`,
  `files.create` and `files.append_to` retiring into it and
  `std.files`' byte conveniences rewritten over it.  `open` joins
  `reserved_names`, which costs the word to every struct in the
  language (evidence 16).
- `read_text`, `read_bytes`, `read_line`, `read_lines`, `write_text`,
  `write_bytes`, `write_lines` on the `file` (D7), over **a read
  buffer in `libluce_rt`** (D8) — the one genuinely new piece of
  runtime — with the `f.read()` diagnostic D7 names.  `read`, `write`
  and `flush` keep their names and their meaning (R3).
- The specs the memo lists for those: `open` in each mode, reading
  from a file opened for writing, `read_line` across a buffer boundary
  and at end of file, `read_text` on bytes that are not text,
  `write_lines` on an empty list.

None of it moves anything this run built: no signature here changes,
and `path_kind`, `Kind`, `Entry`, `entries`, the three predicates and
`joined` are what they will be.  It costs one more `format_version`
and no `abi.version` (D7 spends no slot), and the "do not race the
version numbers" rule applies to it exactly as it applied here.

**Can wait, unchanged** from the list above: the `dir_entries` fast
path (D15, whose trigger is a measured walk — and B4 makes it a
smaller win than the memo priced, since `list` no longer pays), the
reserved-name narrowing, `paths.relative_to`, and `files.walk`.
