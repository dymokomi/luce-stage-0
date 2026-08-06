# std.paths

Pure text over path names. Nothing here touches the host, so the
module works even in a program compiled without host access, no
function can fail or trap on any input, and every answer is a plain
`string` or `bool`.

```
import std.paths
```

The separator is `/`, the one the hosts loom runs on use. There are no
drive letters, no backslashes and no `.` / `..` cleaning — a path is
taken as written, and only the seams the module itself creates are
kept tidy. The shapes follow Go's `path` package where Go and Python
agree, and Python where they differ on taste: a leading dot is a
hidden file's name, not an extension.

| Signature | Notes |
|---|---|
| `paths.is_absolute(path: string) -> bool` | true when the path starts at the root |
| `paths.join(head: string, tail: string) -> string` | one separator at the seam; an empty side answers the other, an absolute `tail` answers itself |
| `paths.base(path: string) -> string` | the last element; trailing separators do not count; `base("/")` is `"/"` |
| `paths.dir(path: string) -> string` | everything but the last element; a bare name answers `"."`, the root is its own directory |
| `paths.extension(path: string) -> string` | the last element's extension, dot included, or `""`; a leading dot is a name, not an extension |
| `paths.stem(path: string) -> string` | the last element without its extension |

```luce run
import std.paths

func main():
    let p = paths.join("/usr/local", "bin/luce")
    print(p)
    print(paths.dir(p))
    print(paths.base(p))
    print(paths.join("src", "main.luc"))
```

```output
/usr/local/bin/luce
/usr/local/bin
luce
src/main.luc
```

`dir` and `base` take a path apart so that `join` puts it back:
`join(dir(p), base(p))` names the same file `p` does, on every shape —
a bare name's directory is `"."` precisely so that this holds.

```luce run
import std.paths

func main():
    print(paths.extension("notes/report.tar.gz"))
    print(paths.stem("notes/report.tar.gz"))
    print(paths.base("notes/report.tar.gz"))
    print(paths.extension(".bashrc"))
    print(paths.stem(".bashrc"))
```

```output
.gz
report.tar
report.tar.gz

.bashrc
```

`stem` and `extension` are a partition of the base:
`stem(p) + extension(p)` is always `base(p)`.

Deliberately absent: normalisation (`clean`, `..` resolution),
relative-path computation, globbing, and anything that would need to
ask the host a question — an absolute-path *resolver* belongs to the
world, and this module answers only what the text alone can.
