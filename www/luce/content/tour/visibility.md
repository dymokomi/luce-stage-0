# Visibility

A declaration is **public**. A function, a top-level constant, a
struct, its fields and its methods are all reachable through an
`import` the moment you write them: say nothing, and the whole file is
the module's surface.

One word takes a name back. `private`, written in full, withholds a
declaration from every other file. It is a keyword the compiler
enforces rather than a convention it hopes you follow — which is why
Luce refuses a leading underscore outright
([a name starts with a letter](/ref/lexical/#identifiers)). A sigil
nothing checks grows folklore meanings; a keyword does not.

## A helper that stays in

`tally.luc` counts how often a word occurs in a line of text. `clean`
exists so that `count` can do its job. It is scaffolding, not surface,
and the module says so.

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

Inside the file, nothing changed. `count` is public and calls `clean`
on every word, and that is ordinary code: the unit of visibility is
the **file**, so a module trusts itself completely. `private` governs
who may *refer* to a name, never who may call whom.

```luce run
import tally

func main():
    print(string(tally.count("Bee bee BEE tree", "bee")))
```

```output
3
```

From another file, `count` is there and `clean` is not.

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

That sentence is worth reading twice, because it carries the privacy
decision you will feel most often. The compiler says *private*, not
"unknown function": the name exists, it is withheld, and the message
traces back to a `private` somebody typed. Suggestions follow the same
rule — a did-you-mean never offers a private name — so a misspelling
never sends you hunting for a typo that is not there.

## Regions: saying it once for a group

Inside a struct — and only inside a struct — `private:` opens an
indented **region** of members. Everything in the block is private,
fields and functions alike, the way every colon in Luce opens a block.

```luce module file=gauge.luc
struct Gauge:
    label: string

    private:
        reading: long
        scale: long

    func show(self) -> string:
        return f"{self.label}: {self.reading * self.scale}"

    func add(var self, amount: long):
        self.reading = self.reading + amount

func open(label: string, scale: long) -> Gauge:
    return Gauge(label = label, reading = 0, scale = scale)
```

`label` sits outside the region, so it takes the default and is
public. `reading` and `scale` are the module's own arithmetic. The two
methods sit outside the region too, and are public like everything
else unmarked — which is what lets an importer drive a `Gauge` without
ever seeing inside one.

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

`public:` is a label as well, regions may repeat and appear in any
order, and members outside every region take the default. A lone field
is usually clearer marked on its own line: the region above and two
`private` words, one per field, mean exactly the same thing to the
compiler. What you may not do is both at once — a `private` word
*inside* a `private:` region is refused, because the block already
said it.

## A private field decides who may construct

`Gauge` has a private field with no default, and that one fact closes
construction to the outside world. An outside site may name unmarked
fields only, so nothing it can write fills `reading`.

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

The diagnostic names the way out rather than leaving you to find it,
and `gauge.open` is that way: a public function of the module, which
is inside the wall and may say `reading = 0`. That is the **factory**
pattern, and the standard library lives on it — `math.rng(42)` is
exactly this, a constructor for a generator whose `state` is private.

A private field *with* a default is quieter: it is filled from the
default, silently, and the outsider simply never mentions the slot.
Only a required private field closes construction.

Reading a private field from outside is refused for the same reason,
and says the same kind of sentence:

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

None of this hides the *shape* of a `Gauge`. A struct is a value: an
importer can hold one, copy it, put it in a list, and hand it back to
`gauge.show`. What it cannot do is name a field the module kept.

## public, written out loud

`public` is legal anywhere `private` is, and where it restates the
default it is inert: it asserts, quietly, what was already true. A
module that wants its surface spelled out may spell it.

```luce run
public let width = 40

public func banner(title: string) -> string:
    return title

public struct Line:
    public text: string

    private:
        marker: long

    func mark(var self):
        self.marker = self.marker + 1

public func main():
    print(f"{banner("loom")} {width}")
```

```output
loom 40
```

`main` is the one name that never needs either word. The runtime
starts it by name, not through an import, so `public main` is inert
like any other restated default — and `private main` is refused, with
its own sentence, because an entry the world cannot start is a
contradiction.

## Where a marker may not stand

Visibility is about the module boundary, and there is no smaller
boundary for it to mean anything at. A local `let` is nobody's
surface:

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

And a region belongs to a struct. At file scope the declarations are
few and long, and each one carries its own word rather than half a
file living one level deep:

```luce fail
private:
    let limit = 10

func main():
    print(string(limit))
```

```output
luce: compile failed
main.luc:1:1: a visibility region belongs inside a struct; at file scope mark each declaration [luce.parse.top]
    private:
    ^~~~~~~~
```

## The standard library obeys the same rule

`std` modules are ordinary Luce source, so they are marked the same
way and refused with the same sentence. `strings` keeps two byte-level
helpers to itself:

```luce fail
import std.strings

func main():
    print(strings.fold_case("MIXED", 65, 90, 32))
```

```output
luce: compile failed
main.luc:4:11: fold_case is private to strings [luce.sema.private]
        print(strings.fold_case("MIXED", 65, 90, 32))
              ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

The method spelling `"MIXED".fold_case(...)` routes to the same
declaration and gets the same refusal, so a private name has no second
door.

The [reference](/ref/modules/#visibility) has the exact rules,
including what happens when a public function's signature mentions a
private type. Next: [the outside world](../host/) — printing,
arguments, files and the terminal.
