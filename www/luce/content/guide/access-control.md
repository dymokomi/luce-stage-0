# Access Control

Top-level declarations and struct members are **private to their file**
unless marked `pub`. The compiler enforces this at module boundaries. A
leading underscore is not a visibility convention; identifiers must start
with a letter.

## Private helpers

A declaration says nothing to expose itself; `pub` is the one marker, and
without it a name is available inside its own file but hidden from
importers:

```luce module file=tally.luc
import std.strings

func clean(word: str) -> str:
    return strings.lower(strings.trim(word))

pub func count(text: str, wanted: str) -> i64:
    let words = strings.split(text, " ")
    let target = clean(wanted)
    var found = 0
    for word in words:
        if clean(word) == target:
            found = found + 1
    return found
```

```luce run
import tally

func main():
    print(str(tally.count("Bee bee BEE tree", "bee")))
```

```output
3
```

```luce fail
import tally

func main():
    print(tally.clean("  Bee "))
```

```output
luce: compile failed
main.luc:4:11: clean is private to tally [luce.sema.private]
        print(tally.clean("  Bee "))
              ^~~~~~~~~~~~~~~~~~~~~
```

The diagnostic distinguishes a private name from an unknown name.

## Private fields

A struct is exposed with `pub`, and each field states its own visibility.
An unmarked field is private to the declaring file; `pub` on a field lets
importers name it:

```luce module file=gauge.luc
pub struct Gauge:
    pub label: str
    reading: i64
    scale: i64

    pub func show() -> str:
        return f"{self.label}: {self.reading * self.scale}"

    pub func add(amount: i64):
        self.reading = self.reading + amount

pub func open(label: str, scale: i64) -> Gauge:
    return Gauge(label = label, reading = 0, scale = scale)
```

```luce run
import gauge

func main():
    var g = gauge.open("power", 10)
    g.add(3)
    g.add(4)
    print(g.show())
    print(g.label)
```

```output
power: 70
power
```

A required private field also prevents outside construction. A `pub`
factory inside the module can initialize it:

```luce fail
import gauge

func main():
    var g = gauge.Gauge(label = "power")
    print(g.show())
```

```output
luce: compile failed
main.luc:4:13: Gauge cannot be constructed here: reading is private in gauge and has no default; construction belongs to a public function of gauge [luce.sema.private]
        var g = gauge.Gauge(label = "power")
                ^~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

A private field with a default does not need to be supplied by an importer.
Reading a private field remains forbidden:

```luce fail
import gauge

func main():
    var g = gauge.open("power", 10)
    print(str(g.reading))
```

```output
luce: compile failed
main.luc:5:15: reading of Gauge is private to gauge [luce.sema.private]
        print(str(g.reading))
                  ^~~~~~~~~
```

Visibility hides names, not the fact that a public struct value exists. An
importer can store and pass the struct without naming its private fields.

## Marking `pub`

`pub` goes immediately before the declaration or member it exposes. A file
states its API by marking exactly the names that cross:

```luce run
pub const width = 40

pub func banner(title: str) -> str:
    return title

pub struct Line:
    pub text: str
    marker: i64

    func mark():
        self.marker = self.marker + 1

func main():
    print(f"{banner("Luce")} {width}")
```

```output
Luce 40
```

`main` is the entry point: the runtime starts it by name, so it needs no
marking and stays private like any unmarked declaration.

Type aliases follow the same file boundary:

```text
alias InternalId = i64
pub alias UserId = i64
```

A `pub` alias may re-export a `pub` type. It cannot expose a private
structure, enum, union, class, or interface under a new public name; the
compiler points to the alias declaration and offers the two honest fixes.

## Where the marker is valid

`pub` applies to file-scope declarations and struct members, not local
bindings:

```luce fail
func main():
    pub let limit = 10
    print(str(limit))
```

```output
luce: compile failed
main.luc:2:5: visibility applies to file-scope declarations and struct members [luce.parse.expected]
        pub let limit = 10
        ^~~
```

There is no region form: `pub` marks one declaration at a time, so a
`pub:` block is refused with the sentence that names the fix:

```luce fail
pub:
    const limit = 10

func main():
    print(str(limit))
```

```output
luce: compile failed
main.luc:1:1: `pub` marks one declaration; write it before each name, not as a region [luce.parse.top]
    pub:
    ^~~~
```

Standard-library modules use the same rules. The exact boundary rules and
signature checks are in the
[module reference](/guide/reference/modules/#visibility).
Continue with [Modules and Imports](/guide/modules/).
