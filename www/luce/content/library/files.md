# std.files

`std.files` is the host-facing file API. Paths are resolved by the host from
the process's current directory. Every operation that touches the filesystem
is fallible: the world may refuse a valid request, so handle it with `try` or
`catch`.

```text
import std.files
```

Programs compiled without host access cannot use this module. A file is a
shared reference resource, and there is no source `close` call. ARC closes its
host handle at the last strong release. See [Memory
Management](/guide/reference/memory/#m7).

## Text files and directories

| Signature | Result |
|---|---|
| `files.kind(path: string) -> Kind?!` | `Kind.file`, `Kind.directory`, or `Kind.other`; `none` when absent |
| `files.exists(path: string) -> bool!` | whether anything is present; refusal remains an error |
| `files.is_file(path: string) -> bool!` | whether the path names an ordinary file |
| `files.is_dir(path: string) -> bool!` | whether the path names a directory |
| `files.read(path: string) -> string!` | reads the whole file as text |
| `files.write(path: string, text: string) -> !` | creates or replaces a text file |
| `files.read_lines(path: string) -> list(string)!` | lines without newline bytes; a final newline adds no empty line |
| `files.write_lines(path: string, lines: list(string)) -> !` | writes one newline after each line; an empty list writes an empty file |
| `files.append_text(path: string, text: string) -> !` | appends text and creates the file if needed |
| `files.append_lines(path: string, lines: list(string)) -> !` | appends newline-terminated lines; an empty list does nothing |
| `files.delete(path: string) -> !` | removes a path; absence is an `io_failed` error |
| `files.rename(from: string, to: string) -> !` | moves a path and replaces an existing target |
| `files.make_directory(path: string) -> !` | creates the directory and missing parents; an existing directory is success |
| `files.list(path: string) -> list(string)!` | sorted names in the directory |
| `files.entries(path: string) -> list(Entry)!` | sorted entries with their names, paths, and kinds |

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
    print(string(len(lines)))

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
`list(byte)` and leaves text validation to `std.strings.from_bytes`.

| Signature | Result |
|---|---|
| `files.open(path: string) -> file!` | opens from the beginning for reading |
| `files.create(path: string) -> file!` | opens for writing, creating and truncating |
| `files.append_to(path: string) -> file!` | opens for writing at the end, creating if needed |
| `files.read_bytes(path: string) -> list(byte)!` | reads the complete file as bytes |
| `files.write_bytes(path: string, bytes: list(byte)) -> !` | replaces the file with bytes |
| `files.append_bytes(path: string, bytes: list(byte)) -> !` | appends bytes |

An owned `file` has three methods:

| Method | Behavior |
|---|---|
| `f.read(into: array(byte, _)) -> long!` | fills a caller-owned buffer and returns the number of bytes read; `0` means end of file |
| `f.write(from: array(byte, _), count: long) -> long!` | writes at most `count` bytes and returns how many were written |
| `f.flush() -> !` | asks the host to flush pending writes |

Reads may be short and writes may accept fewer bytes than requested. The
convenience functions loop until all bytes are handled.

```luce run
import std.files
import std.strings

func main() -> !:
    var bytes: list(byte) = [0, 255, 128]
    try files.write_bytes("data.bin", bytes)
    let loaded = try files.read_bytes("data.bin")
    print(string(len(loaded)))
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
