# std.files

`std.files` is the host-facing file API. Paths are resolved by the host from
the process's current directory. Every operation that touches the filesystem
is fallible: the world may refuse a valid request, so handle it with `try` or
`catch`.

```text
import std.files
```

Programs compiled without host access cannot use this module. An open file is
a `File`, an ordinary class this module declares, and there is no source
`close` call. ARC closes the descriptor at the last strong release. See
[Memory Management](/guide/reference/memory/#m7).

## Text files and directories

| Signature | Result |
|---|---|
| `files.kind(path: str) -> Kind?!` | `Kind.file`, `Kind.directory`, or `Kind.other`; `none` when absent |
| `files.exists(path: str) -> bool!` | whether anything is present; refusal remains an error |
| `files.is_file(path: str) -> bool!` | whether the path names an ordinary file |
| `files.is_dir(path: str) -> bool!` | whether the path names a directory |
| `files.read(path: str) -> str!` | reads the whole file as text |
| `files.write(path: str, text: str) -> !` | creates or replaces a text file |
| `files.read_lines(path: str) -> list[str]!` | lines without newline bytes; a final newline adds no empty line |
| `files.write_lines(path: str, lines: list[str]) -> !` | writes one newline after each line; an empty list writes an empty file |
| `files.append(path: str, text: str) -> !` | appends text and creates the file if needed |
| `files.append_lines(path: str, lines: list[str]) -> !` | appends newline-terminated lines; an empty list does nothing |
| `files.delete(path: str) -> !` | removes a path; absence is an `io_failed` error |
| `files.rename(from: str, to: str) -> !` | moves a path and replaces an existing target |
| `files.make_directory(path: str) -> !` | creates the directory and missing parents; an existing directory is success |
| `files.list(path: str) -> list[str]!` | sorted names in the directory |
| `files.entries(path: str) -> list[Entry]!` | sorted entries with their names, paths, and kinds |

`Kind` has three members: `file`, `directory`, and `other`. Links are
followed; a dangling link is absent. `Entry` has public fields `name`,
`path`, and `kind`. `list` returns names only; `entries` returns the joined
path and avoids a second `kind` call in a directory walk.

`exists`, `is_file`, and `is_dir` are questions about the past, not guards
for a later read or write. The path can change between calls. Read or write
the resource and handle the result it gives you.

```luce run
import std.files

func main() -> !:
    try files.write("notes.txt", "one\ntwo\n")
    try files.append_lines("notes.txt", ["three"])
    let lines = try files.read_lines("notes.txt")
    print(str(len(lines)))

    try files.make_directory("archive")
    for entry in try files.entries("."):
        if entry.name == "notes.txt":
            print(f"{entry.kind} {entry.path}")

    try files.delete("notes.txt")
```

```output
3
file ./notes.txt
```

The listing is sorted by `name`, independent of the filesystem's directory
order. `make_directory` creates all parents and succeeds when the directory
already exists; it fails when a file occupies the requested name.

## Byte files

Use the byte API when the file is not necessarily UTF-8. It treats a file as
`list[u8]` and leaves text validation to `std.strings.from_bytes`.

| Signature | Result |
|---|---|
| `files.read_bytes(path: str) -> list[u8]!` | reads the complete file as bytes |
| `files.write_bytes(path: str, data: list[u8]) -> !` | replaces the file with bytes |
| `files.append_bytes(path: str, data: list[u8]) -> !` | appends bytes |

An open file is made the way any class instance is made — with `new` —
and construction is fallible because the world decides whether the open
lands:

```text
try files.File(path: str, mode: Mode = Mode.read) -> File!
```

`Mode` names the three doors, instead of numbering them or spelling
them in a mode string:

| Mode | Opens |
|---|---|
| `Mode.read` | from the start, to read; the file must be there |
| `Mode.create` | to write from the start, creating the file and emptying it |
| `Mode.append` | to write at the end, creating the file if it is not there |

`mode` defaults to `Mode.read`, so `try files.File(path)` opens a
file to read and `try files.File(path, files.Mode.append)` opens a
log. `File` is an ordinary class. Assignment shares one ARC reference,
`weak` storage works as it does for any class, and the descriptor it
wraps is a private field no program reaches directly. There is no
`close` method — `f.close()` is the ordinary class diagnostic
`files.File has no method close` — because the last strong release
already closes the descriptor.

A `File` conforms to [`io.Reader` and `io.Writer`](/library/io/) and
has three methods:

| Method | Behavior |
|---|---|
| `f.read(buffer: array[u8, _]) -> i64!` | fills a caller-owned buffer and returns the number of bytes read; `0` means end of file |
| `f.write(buffer: array[u8, _], count: i64) -> i64!` | writes at most `count` bytes and returns how many were written |
| `f.flush() -> !` | asks the host to flush pending writes |

Reads may be short and writes may accept fewer bytes than requested. The
convenience functions loop until all bytes are handled.

```luce run
import std.files
import std.strings

func main() -> !:
    var data: list[u8] = [0, 255, 128]
    try files.write_bytes("data.bin", data)
    let loaded = try files.read_bytes("data.bin")
    print(str(len(loaded)))
    print(strings.from_bytes(loaded) else "(not text)")
    try files.delete("data.bin")
```

```output
3
(not text)
```

`files.read` is the text convenience operation. It reads bytes and then
requires valid UTF-8; a binary file should be read with `read_bytes` instead.

## Handling failure

Propagate an error when the caller should decide, or handle it where a
fallback is meaningful:

```luce run
import std.files

func main():
    let text = files.read("config.txt") catch "default config"
    print(text)

    files.write("/path/that/does/not/exist", "x") catch reason:
        print(reason)
```

```output
default config
cannot write /path/that/does/not/exist
```

The host reports file refusals as `io_failed`; it does not promise a more
specific distinction such as “not found” versus “permission denied”.
