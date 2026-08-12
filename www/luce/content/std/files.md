# std.files

A thin, honest layer over the host's file builtins. Paths resolve
relative to the current directory.

```
import std.files
```

The module is **host-gated**, like the builtins under it: `import
std.files` inside a program compiled without host access is a compile
error, because file access genuinely does not exist there.

## The surface

| Signature | Notes |
|---|---|
| `files.kind(path) -> Kind?!` | what is at the path, or `none` when nothing is. **The primitive question**; the three predicates below are one line each over it |
| `files.exists(path) -> bool!` | is there anything at all here — a question, not a guard |
| `files.is_file(path) -> bool!` | `os.path.isfile` |
| `files.is_dir(path) -> bool!` | `os.path.isdir` — the question `exists` is usually asked by mistake |
| `files.read(path) -> string!` | the whole file |
| `files.write(path, text) -> !` | truncates or creates |
| `files.read_lines(path) -> list(string)!` | newlines stripped; a trailing final newline adds no phantom empty line |
| `files.write_lines(path, lines) -> !` | joined with newlines, ends with one; an empty list writes an empty file |
| `files.append_text(path, text) -> !` | adds to the end, creating the file if it is not there |
| `files.append_lines(path, lines) -> !` | the same, one line at a time, each ending in a newline; an empty list adds nothing at all rather than an empty line |
| `files.delete(path) -> !` | deleting a path that is not there is `io_failed`, not a quiet success |
| `files.rename(from, to) -> !` | moves a file, **replacing** an existing target |
| `files.entries(path) -> list(Entry)!` | what is in a directory, **sorted by name**, each entry carrying its kind — `os.scandir` |
| `files.list(path) -> list(string)!` | the names in a directory, **sorted**; plain names, not paths — `os.listdir` |
| `files.make_directory(path) -> !` | makes a directory **and every directory leading to it**; a directory already there is success |

and the two types they answer with:

| Declaration | Notes |
|---|---|
| `enum files.Kind` | `file`, `directory`, `other`. Three members, because that is the set a program branches on: recurse, read, or leave alone. There is no `symlink` — a link is what it points at |
| `struct files.Entry` | `name`, `path`, `kind` — exactly `os.scandir`'s `DirEntry`. A pane prints `name`, a walk pushes `path`, and neither writes a join |

And the binary half, which is the same file seen as bytes:

| Signature | Notes |
|---|---|
| `files.open(path) -> file!` | a handle to read from the start; the file must be there |
| `files.create(path) -> file!` | a handle to write from the start, creating the file and emptying it |
| `files.append_to(path) -> file!` | a handle to write at the end, creating the file if it is not there |
| `files.read_bytes(path) -> list(byte)!` | the whole file as bytes; nothing here asks whether they are text |
| `files.write_bytes(path, bytes) -> !` | replaces whatever was there |
| `files.append_bytes(path, bytes) -> !` | adds to the end, creating the file if it is not there |

Three of those want a sentence of their own.

**`append_text` is what `write` cannot be.** Read-then-write is two
calls with a window between them, and the second one throws away
whatever landed in the first one's shadow. A log wants the append.

It is spelled `append_text` and not `append` because `append` is a
[reserved name](/ref/lexical/#reserved-names) — it is `xs.append(v)`,
the `list` method — and the reservation applies to a module-qualified
declaration too.

**`rename` replaces.** That is the whole point of write-then-rename: a
file is replaced without ever leaving half of one on disk, because the
rename is the one step that is all or nothing.

**`list` and `entries` both sort, and the host does not.** The host's
order is whatever the file system felt like, which differs between two
machines holding the same files — and a program that prints a listing
should print the same listing. `list` answers plain names: join them
to the directory yourself, or call `entries` and read `path`, which is
the listed path with the name already joined onto it, exactly as
`os.scandir`'s is.

**`make_directory` means "there is a directory here when I return."**
It makes the parents, so a nested layout is one call and not a
splitting loop in every program; and a directory that was already
there is success, so an install path never writes
`if not files.is_dir(p)` in front of it — which would be exactly the
check-then-act race an existence question is not allowed to be. A *file* holding
the name is `io_failed`: you asked for a directory and there is not
one.

```luce run
import std.files
import std.strings

func main() -> !:
    try files.write("notes.txt", "first\n")
    try files.append_text("notes.txt", "second\n")
    try files.append_lines("notes.txt", ["third", "fourth"])
    print(f"{len(try files.read_lines("notes.txt"))} lines")

    # write-then-rename: the replacement is one all-or-nothing step
    try files.write("notes.new", "replaced\n")
    try files.rename("notes.new", "notes.txt")
    print(try files.read("notes.txt"))
    let gone = files.exists("notes.new") catch true
    print(f"the temporary is gone: {not gone}")

    # Written out of order; listed in order, and as plain names.
    for name in ["part-c", "part-a", "part-b"]:
        try files.write(name + ".txt", "")
    var parts: list(string) = []
    for name in try files.list("."):
        if name.starts_with("part-"):
            parts.append(name)
    print(parts.join(" "))

    try files.delete("part-a.txt")
    files.delete("part-a.txt") catch:
        print("deleting what is not there is an error, not a no-op")
```

```output
4 lines
replaced

the temporary is gone: true
part-a.txt part-b.txt part-c.txt
deleting what is not there is an error, not a no-op
```

## Everything that touches a file says `!`

The world decides whether a read or a write lands, so every one of
these is fallible: `try` it to pass the failure on, or `catch` it to
handle it here. Ignoring the outcome is `luce.sema.fallible` — there
is no spelling that drops it silently.

```luce run
import std.files

func main() -> !:
    try files.write("stock.txt", "fig\npear\nplum\n")

    let whole = try files.read("stock.txt")
    print(f"{len(whole)} bytes")

    let lines = try files.read_lines("stock.txt")
    print(f"{len(lines)} lines, last is {lines[len(lines) - 1]}")

    var kept: list(string) = []
    for line in lines:
        if line != "pear":
            kept.append(line)
    try files.write_lines("kept.txt", kept)
    print(f"kept {len(try files.read_lines("kept.txt"))}")
```

```output
14 bytes
3 lines, last is plum
kept 2
```

## What is at a path

`kind` is the primitive question, and it is the one thing on this page
Python has no single spelling for. Three things can happen and each
gets its own channel: a member for what is there, `none` for nothing
there, and `!` for a world that **would not say** — a parent directory
nobody may search, a device that failed.

`match` does not dispatch over an optional, and that is the guarantee
rather than the wart: the absent case is answered before the match, so
a program cannot fall past it.

```luce run
import std.files

func describe(path: string) -> string!:
    let what = try files.kind(path)
    if what == none:
        return "nothing there"
    match what:
        file:
            return "a file"
        directory:
            return "a directory"
        other:
            return "something else"

func main() -> !:
    try files.write("report.txt", "written\n")
    try files.make_directory("archive")
    for name in ["report.txt", "archive", "nowhere"]:
        print(f"{name}: {try describe(name)}")
```

```output
report.txt: a file
archive: a directory
nowhere: nothing there
```

A listing carries the same answer for every entry, so a walk never
opens one to find out what it was:

```luce run
import std.files

func main() -> !:
    try files.make_directory("garden/beds")
    try files.write("garden/plan.txt", "rows\n")

    for entry in try files.entries("garden"):
        match entry.kind:
            directory:
                print(f"{entry.name}/ -> {entry.path}")
            file:
                print(f"{entry.name} -> {entry.path}")
            other:
                continue
```

```output
beds/ -> garden/beds
plan.txt -> garden/plan.txt
```

## exists, is_file and is_dir answer `bool!`, deliberately

Here Luce is **not** Python, and it is worth saying why. Python's
`os.path.exists`, `isfile` and `isdir` swallow every `OSError`,
`PermissionError` included — 3.14 made `pathlib`'s do the same for
consistency — so a file that certainly exists under a directory nobody
may open answers `False`, exactly as a name nothing holds does. Rust
shipped `try_exists()` in 1.63 because that swallowing was a bug
source.

So these three are fallible. A program that wants Python's behaviour
writes `catch false`, which is three visible words and greppable on
purpose.

They are still questions about the **past**, never a guard for the
call after them: there is a window between the two that nothing can
close. Read the file and handle what the read says.

```luce run
import std.files

func main() -> !:
    print(f"before: {files.exists("report.txt") catch false}")

    let missing = files.read("report.txt") catch "(nothing yet)"
    print(missing)

    files.write("report.txt", "written\n") catch:
        print("could not write")

    let there = try files.exists("report.txt")
    let plain = try files.is_file("report.txt")
    let folder = try files.is_dir("report.txt")
    print(f"after: {there}, file: {plain}, directory: {folder}")
    print(files.read("report.txt") catch "(still nothing)")
```

```output
before: false
(nothing yet)
after: true, file: true, directory: false
written
```

## Handling versus propagating

```luce run
import std.files

func load_or_default(path: string) -> string:
    return files.read(path) catch "default contents\n"

func load_or_fail(path: string) -> string!:
    return try files.read(path)

func main() -> !:
    try files.write("present.txt", "real contents\n")
    print(load_or_default("present.txt"))
    print(load_or_default("absent.txt"))
    print(try load_or_fail("present.txt"))
    print(load_or_fail("absent.txt") catch "(handled at the top)")
```

```output
real contents

default contents

real contents

(handled at the top)
```

## A handle is a scope-owned resource

`open`, `create` and `append_to` answer a [`file`](/ref/types/#file).
It is an object like a `list` is an object, and it obeys the same
rules: the binding that received it owns it, the end of that scope
closes the file, `free(f)` closes it early, `give` and `return` move
it, and using one after it is closed traps `use_after_free` — because
it is the same mistake.

There is deliberately no `close`, **and no `with` either — because
there is nothing for one to do.** A Python programmer will look for
both, so here is the sentence once: `var f = try files.open(p)` is
`with open(p) as f:`, and the end of `f`'s scope is the `__exit__`.
Python's `with` is a per-call-site opt-in to a guarantee this language
gives unconditionally, to every owned thing rather than to the ones a
library remembered to write an `__exit__` for. A Luce program cannot
leak a file by forgetting a keyword, because there is no keyword to
forget.

`close()` is not offered rather than merely absent. A working one
would have to poison the receiver exactly as `free` does, which makes
it `free` under a second name for one concept; an idempotent one would
need a "closed but not poisoned" state, which is the one state a
resource must never hold. `free(f)` is the early close and the scope
end is the automatic one.

```luce run
import std.files

func main() -> !:
    try files.write("notes.txt", "abcdef")
    var f = try files.open("notes.txt")
    var buffer = new array(byte, 4)
    print(string(try f.read(buffer)))
    print(string(try f.read(buffer)))
    print(string(try f.read(buffer)))
    try files.delete("notes.txt")
```

```output
4
2
0
```

Four, then the two that were left, then zero. **A read answers how many
bytes landed**, and zero is the end of the file: short is ordinary, not
a refusal. A write says the same thing in the other direction —
`f.write(buffer, count)` answers how many bytes it took, which may be
fewer than you offered, so a caller loops. That is the C shape on
purpose, and it is the shape a socket will want when `std.network`
arrives.

`read_bytes`, `write_bytes` and `append_bytes` are that loop, written
once, the way Go's `os.ReadFile` is a loop over `Read`.

## Bytes are not text until you say so

Nothing on the byte side asks whether what it carries is text. That is
the point: a JPEG reads as happily as a note.

```luce run
import std.files
import std.strings

func main() -> !:
    var bytes = new list(byte)
    bytes.append(byte(0x89))
    bytes.append(byte(0x50))
    bytes.append(byte(0x00))
    try files.write_bytes("image.bin", bytes)
    let back = try files.read_bytes("image.bin")
    print(string(len(back)))
    print(strings.from_bytes(back) else "(not text)")
    try files.delete("image.bin")
```

```output
3
(not text)
```

Going the other way is [`strings.from_bytes`](/std/strings/), which
answers `string?` — "not UTF-8" is the same reason every time, so
absence carries all the information there is.

`files.read` is defined over exactly this: an open, a loop of reads, a
close, and then that check. A file whose bytes are not text is refused
*as a string*, which is true, and it is refused identically wherever
the program runs — the rule lives in the runtime library rather than in
any one host.

## What is missing

**File metadata** — size, times, mode, owner. Each is a promise the
host boundary would have to keep on every platform, and no program in
this tree wants one yet. The two usual reasons are answered elsewhere:
"has this changed" is a content hash, and "how big is it" is answered
by reading it, since a size read before a read is the same race an
existence check was.

**`seek` and `tell`**, and with them the update modes. A random-access
file is a different resource from a stream and should arrive as one.

**Globbing, watching, and recursive copy or delete.** A glob is a
matcher and a matcher is text, so it is
[`strings`](/std/strings/) work over `entries`, written where its
dialect is visible; a watcher needs the host to call *into* a program,
which it never does; and `copytree`/`rmtree` are ten legible lines over
these primitives plus a policy that belongs to the program holding it.

The [status page](/status/) keeps the wider list.
