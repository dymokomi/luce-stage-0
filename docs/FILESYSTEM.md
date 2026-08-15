# The filesystem surface — `std.paths`, `std.files`, and opening files

Luce's filesystem surface is modelled on Python's `os.path` + `os` +
`open` — the half of Python's filesystem that maps onto Luce with no new
language surface at all. There is deliberately no `Path` type: a path is
an ordinary `string`, path arithmetic is free functions in `std.paths`,
and world operations are free functions in `std.files`. A Python
programmer arriving at `paths.join(here, name)` or `files.entries(dir)`
is not being asked to learn anything.

The split between the two modules is honest about what each does:

- **`std.paths`** is the *name*. Every function is pure text — it never
  touches the host, cannot fail, and is true of any string — so the
  module works even where no files exist and no import gates it beyond
  its own.
- **`std.files`** is the *world*. Every function that touches a file
  answers `T!`, is host-gated, and the `import std.files` line says so:
  a correct program given correct input can still be told no, which is
  what makes it an error rather than a trap (`docs/FAILURE.md`).

You can see from the import line which half of the surface a call comes
from, and `paths` is provably total.

## `std.paths` — pure path text

The separator is `/`. There are no drive letters, no backslashes, and no
`.`/`..` cleaning — a path is taken as written, and only the seams these
functions create are kept tidy. Empty strings answer the empty-ish thing
each function documents rather than trapping, so a path routine never
turns its callers into guards.

| function | shape | answer |
|---|---|---|
| `is_absolute(path)` | `-> bool` | true when the path starts at the root (`/…`) |
| `join(head, tail)` | `-> string` | `head` and `tail` with one separator at the seam; an absolute `tail` resets, as Python's `join` does |
| `joined(parts)` | `-> string` | every part folded through `join`, left to right; `[]` answers `""` |
| `base(path)` | `-> string` | the last element: `base("a/b.luc")` is `"b.luc"`; the root's is `"/"` |
| `dir(path)` | `-> string` | everything but the last element: `dir("a/b.luc")` is `"a"`; a bare name's is `"."` |
| `extension(path)` | `-> string` | the last element's extension, dot included: `".luc"`, or `""` when there is none (a leading dot is a hidden name, not an extension) |
| `stem(path)` | `-> string` | the last element without its extension; `stem(p) + extension(p)` is always `base(p)` |

`joined` is the one place `/`-chaining is genuinely missed: Python writes
`os.path.join(a, b, c)`, and with no variadics and no `/` operator, a
list literal is the Luce spelling. It has exactly `join`'s rules — an
empty part contributes nothing, an absolute part starts again, piled
separators collapse — so `joined([a, b])` and `join(a, b)` are the same
string.

```luce
import std.paths

func target(root: string, name: string) -> string:
    return paths.joined([root, "build", name + ".out"])

func main():
    print(target("proj", "app"))
```

Path spellings are free functions and only free functions. Writing
`p.base()` on a `string` does not route anywhere — in Python `join` on a
string receiver is the separator-join with the arguments the other way
round, so filesystem methods on `string` are refused to keep that
confusion out. The diagnostic names the module that has the function:
write `paths.base(p)` with `import std.paths`.

## `std.files` — the world

### What is at a path

The primitive question is `files.kind`, and the three predicates are one
line each over it.

```text
enum Kind:
    file
    directory
    other
```

`Kind` has three members because that is the set a program branches on:
recurse, read, or leave alone. `other` is honest and total — a socket, a
device, a fifo, a filesystem that will not say more — and it is one
member rather than a taxonomy because a program that must tell a block
device from a door is writing an operating system, not using one. There
is no `symlink` member: links are followed, so a kind describes the same
file the next line touches, and a broken link is nothing there. A member
added later becomes a compile error at every `match` that missed it
(`docs/ENUMS.md`), so the set can only grow.

| function | shape | answer |
|---|---|---|
| `kind(path)` | `-> Kind?!` | what is at the path; `none` when nothing is |
| `exists(path)` | `-> bool!` | whether there is anything at all at the path |
| `is_file(path)` | `-> bool!` | whether an ordinary file is there (`os.path.isfile`) |
| `is_dir(path)` | `-> bool!` | whether a directory is there (`os.path.isdir`) |

The two ways `kind` can answer are different facts on different channels:
`none` means *nothing is there* — the same reason every time, no message
worth carrying — and `!` means *the world would not say*: a parent
nobody may search, a device that failed.

The predicates answer `bool!` and not `bool` on purpose. A file that
certainly exists under a directory nobody may open is not absent — the
world refused to look — and a plain `bool` has no room to say so. Python
3.14 made its three predicates swallow every `OSError`, `PermissionError`
included; Rust added `try_exists()` because that swallowing was a bug
source. A Luce program that wants Python's behaviour writes `catch
false`, which is three visible words:

```luce
import std.files

func check(p: string) -> !:
    if (try files.is_dir(p)):
        print("dir")
    let there = files.exists(p) catch false
    if there:
        print("exists")

func main():
    print("ok")
```

`exists` is still a question about the past, so it is still never a guard
for the call after it: read the file, and handle what the read says.

### The kind question

`match` does not dispatch over an optional, which is the guarantee rather
than a wart: it refuses to let a program `match` its way past the absent
case. So the shape is bind, answer the `none`, then `match` — and once
inside the `match`, an `else`-less arm for every member means a `Kind`
grown later is a compile error here:

```luce
import std.files

func walk(p: string):
    print("walk " + p)

func classify(p: string) -> !:
    let what = try files.kind(p)
    if what == none:
        print(p + " is not there")
        return
    match what:
        directory:
            walk(p)
        file:
            print("file " + p)
        other:
            print("skip " + p)

func main():
    print("ok")
```

### Reading and writing whole files

| function | shape | meaning |
|---|---|---|
| `read(path)` | `-> string!` | the whole file as text; refused if the bytes are not UTF-8 |
| `write(path, text)` | `-> !` | replaces the file's contents |
| `read_lines(path)` | `-> list(string)!` | the file's lines, with newlines stripped; a trailing final newline makes no phantom empty line |
| `write_lines(path, lines)` | `-> !` | the lines joined with newlines and ended with one; `[]` writes an empty file |
| `append_text(path, text)` | `-> !` | adds text to the end, creating the file if absent |
| `append_lines(path, lines)` | `-> !` | adds the lines, each ending in a newline; `[]` adds nothing |
| `delete(path)` | `-> !` | removes the file |
| `rename(from, to)` | `-> !` | moves the file, replacing an existing `to` |
| `make_directory(path)` | `-> !` | ensures a directory exists at the path, making parents |

Two line conventions differ from Python deliberately, and both are what
every caller means: `read_lines` and `read_line` **strip** the trailing
newline (Python keeps it and every reader opens with `.rstrip()`), and
`write_lines` **ends** each line with a newline (Python's `writelines`
concatenates with none). A program that must know whether a file ended in
a newline reads it whole rather than by lines.

`make_directory` means "there is a directory at this path when I return",
so a directory already there is success — the alternative makes every
caller write a `files.exists` guard, and that guard is a race. A *file*
holding the name is still an error: you asked for a directory and there
is not one.

```luce
import std.files
import std.paths

func save(path: string, lines: list(string)) -> !:
    try files.write_lines(path, lines)

func stage(root: string, name: string, text: string) -> string!:
    let target = paths.joined([root, "build", name + ".out"])
    try files.make_directory(paths.dir(target))
    try files.write(target, text)
    return target

func main():
    print("ok")
```

Renaming onto an existing name replaces it, which is what makes
write-then-rename the way to replace a file without ever leaving half of
one on disk.

### Listing a directory

`files.entries` is `os.scandir`: it answers each entry carrying its kind,
so a walk branches on `entry.kind` without a second syscall.

```text
struct Entry:
    name: string
    path: string
    kind: Kind
```

The two path fields are the two things a caller wants: a file pane prints
`name`, a walk pushes `path`, and neither writes a join. `path` is the
listed path with the name joined on — `entries(".")` answers `"./notes"`,
`entries("src")` answers `"src/luce.zig"` — exactly as `os.scandir` does.

| function | shape | answer |
|---|---|---|
| `entries(path)` | `-> list(Entry)!` | each entry with its kind, sorted by name (`os.scandir`) |
| `list(path)` | `-> list(string)!` | the plain names, sorted (`os.listdir`) |

Both are sorted, because the host's order is whatever the file system
felt like and two machines holding the same files answer differently; a
program that prints a listing should print the same listing.

`list` survives beside `entries` for the reason Python keeps both and
PEP 471 explains: most callers want only the names. `list` is `dir_list`
sorted and asks the host for no kinds; `entries` is the one that fetches
a kind per entry. An entry the listing named but whose kind has since
become nothing was removed while the loop ran, and is left out rather
than reported — a listing is a statement about a moment. A world that
*refuses* to say is a different matter and travels in the error channel.

```luce
import std.files

func show(dir: string) -> !:
    let listing = try files.entries(dir)
    for entry in listing:
        match entry.kind:
            directory:
                print(entry.name + "/")
            file:
                print(entry.name)
            other:
                print(entry.name + " ?")

func main():
    print("ok")
```

A directory walk is `entries` plus a stack. Bind the `try` result to a
name before iterating it:

```luce
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
        let listing = try files.entries(here)
        for entry in listing:
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

## Opening files

For streaming — reading or writing a file a chunk at a time rather than
whole — `std.files` opens a `file` handle:

| function | shape | opens |
|---|---|---|
| `open(path)` | `-> file!` | an existing file, to read from the start |
| `create(path)` | `-> file!` | a file to write from the start, creating and emptying it |
| `append_to(path)` | `-> file!` | a file to write at its end, creating it if absent |

The `file` these answer is a reference-counted resource with the byte
methods `read`, `write`, and `flush`; the full reference for the handle,
its C-shaped read/write primitive, and the whole-file byte conveniences
(`files.read_bytes`, `files.write_bytes`, `files.append_bytes`) is
`docs/BYTES.md`.

### No `with`, no `close`, and nothing leaks

A `file` is a reference-counted resource (`docs/MEMORY.md`), closed
deterministically the instant its last reference is released — for a
plain local, the end of the scope that holds it — by the same machinery
that frees a `list`. A Luce program cannot leak a file by forgetting a
keyword, because there is no keyword to remember; Python's `with` is a
per-call-site opt-in to a guarantee Luce gives unconditionally. There is
no `close()` method, because releasing the last reference already closes
the file, and an explicit `close()` would only add a "closed but not
closed-yet" state beside the reference count:

```text
f.close()
# luce.sema.method: file has no method close: the file closes when its
#   last reference is released — the end of the scope that holds it —
#   which is why there is no 'with' either
```

## Where this is not Python

| Python | Luce | why |
|---|---|---|
| `open(p, "w")` | opening modes are named doors (`files.create`, `files.append_to`) | a mode string is a magic value with no type and no completion |
| `with open(p) as f:` | `var f = try files.open(p)` | the reference count already closes the file |
| `f.close()` | let the last reference go | a `close()` is a second lifetime story |
| `for line in f:` | `files.read_lines(p)`, or a loop over the byte handle | Luce has no generators |
| `os.path.join(a, b, c)` | `paths.joined([a, b, c])` | no variadics, no `/` operator |
| `os.path.exists(p)` returning `False` on refusal | `files.exists(p) -> bool!`, `catch false` for Python's behaviour | a refusal has somewhere to go |
| `os.mkdir` / `os.makedirs` | `files.make_directory(p)` | one call that makes parents and is idempotent |

## Not yet built

Three shapes are designed but not built; they change no signature above
when they land:

- **A free `open(path, mode)` builtin** with a predeclared `FileMode`
  enum (`read`/`write`/`append`), to sit beside the whole-file
  conveniences the way Python's `open` sits beside `os`. Today the
  streaming doors are `files.open`, `files.create`, and `files.append_to`.
- **Text and byte convenience methods on the `file`** —
  `read_text`, `read_bytes`, `read_line`, `read_lines`, `write_text`,
  `write_bytes`, `write_lines` — over a read buffer inside `libluce_rt`.
  Today a `file` answers the C-shaped `read`/`write`/`flush`
  (`docs/BYTES.md`), and whole-file text and bytes go through
  `files.read`/`files.write` and `files.read_bytes`/`files.write_bytes`.

## Deliberately absent

These are not gaps to fill; each is a decision, with the reason:

- **A `Path` type.** A Luce `Path` could not look like pathlib — its feel
  is the `/` operator and properties, both of which Luce refuses — so it
  would cost a new type and a conversion at every boundary and buy no
  familiarity. Reopened only by a type-safety customer, never by an
  ergonomics argument.
- **`stat`** — size, mtime, mode, inode. Each field is a promise the ABI
  must keep on every platform, and no current customer wants one. "How
  big is it" is answered by reading it, and the compile cache keys on
  content, not mtime.
- **`seek`, `tell`, `truncate`, and the `"r+"`/`"w+"` modes.** A
  random-access file is a different resource from a stream and would
  arrive as one, with its own design.
- **`encoding=`, `newline=`, `errors=`.** A Luce `string` is validated
  UTF-8 by construction; bytes that are not text are `read_bytes`'s
  business.
- **Watchers** (inotify, FSEvents, kqueue) — the host never calls into a
  program.
- **Globbing.** A glob is text matching, so it is `strings` work over
  `files.entries`, written where its dialect is visible.
- **Permissions, `chmod`, ownership, ACLs** — an operating-system
  decision `docs/V2.md` deferred.
- **Symlink creation, reading, or resolution.** `kind` gives the whole
  symlink surface a program needs: a link is what it points at, and a
  broken one is nothing.
- **Recursive helpers** (`shutil.copy`, `rmtree`, `copytree`). Each is a
  loop over the primitives plus a policy; once `kind` exists these are a
  few legible lines with their policy in view, and a recursive delete in
  a standard library is a foot-gun with no undo.
- **Current-directory calls** (`getcwd`, `chdir`, `abspath`). A program
  that can move its own cwd makes every relative path in it ambiguous;
  loom resolves relative to the directory it was started in.
- **Temporary files, a second path separator, drive letters, UNC paths.**
  A path says `/` and says so out loud; when a Windows host is real, it
  is its own design.
