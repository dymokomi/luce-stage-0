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
| `files.exists(path) -> Bool` | a question, not a guard |
| `files.read(path) -> String!` | the whole file |
| `files.write(path, text) -> !` | truncates or creates |
| `files.read_lines(path) -> List(String)!` | newlines stripped; a trailing final newline adds no phantom empty line |
| `files.write_lines(path, lines) -> !` | joined with newlines, ends with one; an empty list writes an empty file |
| `files.append_text(path, text) -> !` | adds to the end, creating the file if it is not there |
| `files.append_lines(path, lines) -> !` | the same, one line at a time, each ending in a newline; an empty list adds nothing at all rather than an empty line |
| `files.delete(path) -> !` | deleting a path that is not there is `io_failed`, not a quiet success |
| `files.rename(from, to) -> !` | moves a file, **replacing** an existing target |
| `files.list(path) -> List(String)!` | the names in a directory, **sorted**; plain names, not paths |

Three of those want a sentence of their own.

**`append_text` is what `write` cannot be.** Read-then-write is two
calls with a window between them, and the second one throws away
whatever landed in the first one's shadow. A log wants the append.

It is spelled `append_text` and not `append` because `append` is a
[reserved name](/ref/lexical/#reserved-names) — it is `xs.append(v)`,
the `List` method — and the reservation applies to a module-qualified
declaration too.

**`rename` replaces.** That is the whole point of write-then-rename: a
file is replaced without ever leaving half of one on disk, because the
rename is the one step that is all or nothing.

**`list` sorts, and the host does not.** The host's order is whatever
the file system felt like, which differs between two machines holding
the same files — and a program that prints a listing should print the
same listing. The names are plain names: join them to the directory
yourself.

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
    print(f"the temporary is gone: {files.exists("notes.new")}")

    # Written out of order; listed in order, and as plain names.
    for name in ["part-c", "part-a", "part-b"]:
        try files.write(name + ".txt", "")
    var parts: List(String) = []
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

the temporary is gone: false
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

    var kept: List(String) = []
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

## exists is the exception, and it is not a guard

`exists` answers a plain `Bool`, because asking whether a path is
there is not itself an operation that can half-succeed. But it is a
question about the **past**, never a guard for the call after it:
there is a window between the two that nothing can close, and a guard
could not tell "not there" from "would not open" anyway.

Read the file and handle what the read says.

```luce run
import std.files

func main():
    print(f"before: {files.exists("report.txt")}")

    let missing = files.read("report.txt") catch "(nothing yet)"
    print(missing)

    files.write("report.txt", "written\n") catch:
        print("could not write")

    print(f"after: {files.exists("report.txt")}")
    print(files.read("report.txt") catch "(still nothing)")
```

```output
before: false
(nothing yet)
after: true
written
```

## Handling versus propagating

```luce run
import std.files

func load_or_default(path: String) -> String:
    return files.read(path) catch "default contents\n"

func load_or_fail(path: String) -> String!:
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

## What is missing

**Path manipulation.** Joining, splitting and extending a path is pure
text, so it is not a host gap at all: it wants a `paths` module over
[`std.strings`](/std/strings/), designed against a program that needs
one rather than guessed at. It is the only thing on this page's list.

There is no way to create or remove a directory, no file metadata
(size, times, kind), and no way to tell a directory from a file except
by trying to read it — `list` names sub-directories like everything
else, and `read` on one answers no, which is the honest sequence. The
[status page](/status/) keeps the wider list.
