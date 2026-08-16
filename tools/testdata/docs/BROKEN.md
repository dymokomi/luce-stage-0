# A current document with one lie in it

`tools/doccheck.zig` compiles every Luce sample in every current
document.  A guard that only ever runs against a clean tree proves
nothing — empty its document list and every test still passes — so
this file is the tree it is pointed at to prove it fails.

Four fences: one that compiles, one that does not, one that must be
refused and is, and one whose whole point is that it is *not*
compiled.

```luce
func main():
    let n = 1
    assert(n == 1)
```

The next one names a type this language has never had.

```luce
func main():
    let n: Integer = 1
    assert(n == 1)
```

And this one is the language as it was spelled before `docs/TYPES.md`
D8 made the builtin names lowercase.  It is shown as history, so it is
rendered and never compiled.

```luce historical
func main():
    let n: Int = 1
    assert(n == 1)
```

And a refusal the compiler still makes, which is a claim of its own.

```luce refused
func main():
    let n = 1
    n = 2
```
