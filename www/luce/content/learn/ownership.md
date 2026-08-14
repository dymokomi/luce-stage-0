# Memory and ownership

Luce uses scope ownership. It does not use a garbage collector or reference
counting. A binding that receives a new container or resource owns it, and
the owning scope releases it. Most code does not need an explicit memory
operation.

```luce run
func main():
    var xs = [1, 2, 3]
    xs.append(4)
    xs = [5, 6]
    print(f"{len(xs)} elements")
```

```output
2 elements
```

The four ownership forms are `new`, `give`, `copy`, and `free`.

## What is owned

Lists, maps, arrays, and builders are container objects. A struct that
contains one is also owned. `file` and `task` are owned resources and cannot
be copied. Numbers, strings, booleans, enums, functions, and structs with no
owned fields are values and copy normally.

Objects created at file scope as constants belong to the program root; see
[Constants](../constants/). Objects created in a loop or a temporary scope
are released when that scope ends:

```luce run
import std.strings

func main():
    for round in range(0, 3):
        var row = new array(long, 4)
        row.fill(round)
        print(f"round {round} first {row[0]}")
    for word in "a b c".split(""):
        print(word)
```

```output
round 0 first 0
round 1 first 1
round 2 first 2
a
b
c
```

## Aliases

`let y = x` creates another name for the same object. It does not copy it:

```luce run
func main():
    var xs = [1, 2, 3]
    let view = xs
    view.append(4)
    print(f"{len(xs)} elements")
```

```output
4 elements
```

Using an object after its owner was freed is a reported trap:

```luce trap
func main():
    var xs = [1, 2]
    let view = xs
    free(xs)
    print(string(view[0]))
```

```output
loom: trap: object used after free [use_after_free]
    at main (main.luc:5:5)
```

## Keeping an object

Passing an object to a function normally borrows it. Storing a named object
inside another owner requires an explicit choice: `give` moves the existing
object, while `copy` creates a second object.

```luce fail
func main():
    var index = new map(string, list(long))
    var hits: list(long) = [12, 40]
    index["a.luc"] = hits
```

```output
luce: compile failed
main.luc:4:5: a container keeps its owned elements; write give hits to hand it over, or copy hits to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        index["a.luc"] = hits
        ^~~~~~~~~~~~~~~~~~~~~
```

```luce run
func main():
    var index = new map(string, list(long))

    var hits: list(long) = [12, 40]
    index["a.luc"] = give hits

    var template: list(long) = [0, 0]
    index["b.luc"] = copy template
    template.append(1)

    index["c.luc"] = [7, 8]

    print(f"{len(index)} entries, template still has {len(template)}")
```

```output
3 entries, template still has 3
```

After `give`, the source name cannot be used again in that scope:

```luce fail
func main():
    var sink = new list(list(long))
    var xs: list(long) = [1]
    if len(xs) > 0:
        sink.append(give xs)
    print(string(len(xs)))
```

```output
luce: compile failed
main.luc:6:22: xs was given away and cannot be touched again in this scope [OWNERSHIP.md S10, S29] [luce.sema.own]
        print(string(len(xs)))
                         ^~
```

Containers recursively own the objects stored in them. A container carrying
a file or task cannot be copied; only a live owner can give it away.

## Calls and returns

A regular object parameter is a borrow. The callee may read or mutate it but
cannot keep, return, give, or free it through that borrow:

```luce run
func fill(xs: list(long), upto: long):
    for i in range(0, upto):
        xs.append(i * i)

func total(values: list(long)) -> long:
    var sum: long = 0
    for value in values:
        sum += value
    return sum

func main():
    var squares: list(long) = []
    fill(squares, 5)
    print(f"{len(squares)} values totalling {total(squares)}")
```

```output
5 values totalling 30
```

A parameter declared with `give` accepts ownership, and the call site must
also say `give`:

```luce run
func stash(index: map(string, list(long)), hits: give list(long)):
    index["latest"] = give hits

func main():
    var index = new map(string, list(long))
    var mine: list(long) = [1, 2]
    stash(index, give mine)
    stash(index, [3, 4])
    print(f"latest has {len(index["latest"])}")
```

```output
latest has 2
```

The caller owns a returned object. A return therefore moves the local result
to the caller:

```luce run
import std.strings

func squares(upto: long) -> list(long):
    var out: list(long) = []
    for i in range(0, upto):
        out.append(i * i)
    return out

func main():
    var values = squares(5)
    var text: list(string) = []
    for value in values:
        text.append(string(value))
    print(text.join(" "))
```

```output
0 1 4 9 16
```

## Releasing early

`free(x)` releases an owned container or resource before its scope ends and
invalidates the name. It is useful when a large object is finished early;
ordinary code can let scope exit release it.

```luce run
func main():
    var scratch = new list(long)
    scratch.append(1)
    free(scratch)
    print("released")
```

```output
released
```

The [ownership reference](/reference/ownership/) lists the complete S1–S46
contract. Next: [Absence](../absence/).
