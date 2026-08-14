# Access Control

Top-level declarations and struct members are public unless marked
`private`. The compiler enforces this at module boundaries. A leading
underscore is not a visibility convention; identifiers must start with a
letter.

## Private helpers

`private` keeps a declaration available inside its own file while hiding it
from importers:

```luce module file=tally.luc
import std.strings

private func clean(word: string) -> string:
    return strings.lower(strings.trim(word))

func count(text: string, wanted: string) -> long:
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
    print(string(tally.count("Bee bee BEE tree", "bee")))
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

## Struct regions

Inside a struct, `private:` and `public:` introduce indented regions. A
member outside a region uses the public default.

```luce module file=gauge.luc
struct Gauge:
    label: string

    private:
        reading: long
        scale: long

    func show() -> string:
        return f"{self.label}: {self.reading * self.scale}"

    func add(amount: long):
        self.reading = self.reading + amount

func open(label: string, scale: long) -> Gauge:
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

A required private field also prevents outside construction. A public
factory inside the module can initialize it:

```luce fail
import gauge

func main():
    var g = gauge.Gauge(label = "power")
    print(g.show())
```

```output
luce: compile failed
main.luc:4:13: Gauge cannot be constructed here: reading is marked private in gauge and has no default; construction belongs to a public function of gauge [luce.sema.private]
        var g = gauge.Gauge(label = "power")
                ^~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

A private field with a default does not need to be supplied by an importer.
Reading a private field remains forbidden:

```luce fail
import gauge

func main():
    var g = gauge.open("power", 10)
    print(string(g.reading))
```

```output
luce: compile failed
main.luc:5:18: reading of Gauge is private to gauge [luce.sema.private]
        print(string(g.reading))
                     ^~~~~~~~~
```

Visibility hides names, not the fact that a public struct value exists. An
importer can store and pass the struct without naming its private fields.

## Writing `public`

`public` is allowed on declarations and members when a module wants to
state its public API explicitly:

```luce run
public const width = 40

public func banner(title: string) -> string:
    return title

public struct Line:
    public text: string

    private:
        marker: long

    func mark():
        self.marker = self.marker + 1

public func main():
    print(f"{banner("Luce")} {width}")
```

```output
Luce 40
```

`main` is the entry point and must not be private.

## Where visibility markers are valid

Visibility applies to file-scope declarations and struct members, not local
bindings:

```luce fail
func main():
    private let limit = 10
    print(string(limit))
```

```output
luce: compile failed
main.luc:2:5: visibility applies to file-scope declarations and struct members [luce.parse.expected]
        private let limit = 10
        ^~~~~~~
```

A region must be inside a struct:

```luce fail
private:
    const limit = 10

func main():
    print(string(limit))
```

```output
luce: compile failed
main.luc:1:1: a visibility region belongs inside a struct; at file scope mark each declaration [luce.parse.top]
    private:
    ^~~~~~~~
```

Standard-library modules use the same rules. The exact boundary rules and
signature checks are in the
[module reference](/guide/reference/modules/#visibility).
Continue with [Modules and Imports](/guide/modules/).
