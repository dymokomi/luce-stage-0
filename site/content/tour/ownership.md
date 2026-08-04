# Memory

Luce has no garbage collector. It has no reference counting — not in
the language, not in the runtime, not hidden anywhere. And it has no
`malloc`/`free` bookkeeping in ordinary code.

What it has instead is **scope ownership**: the binding that received
a fresh object owns it, and the owning scope frees it. Most programs
never write a memory word.

```luce run
func main():
    var xs = [1, 2, 3]        # xs owns this list
    xs.append(4)
    xs = [5, 6]               # the old list is freed right here
    print(f"{len(xs)} elements")
    # the scope ends: everything owned here is freed
```

```output
2 elements
```

The whole model is four words — `new`, `give`, `copy`, `free` — and
three of them are needed only where the compiler genuinely cannot see
what you mean. The full specification is
[43 numbered situations](/ref/ownership/), each one addressable on its
own, and the compiler quotes their numbers in its diagnostics.

## What owns what

Only **objects** are owned: `List`, `Map`, `Array`, `Builder`, and
structs that transitively contain one. **Values** — `Int`, `Float`,
`Bool`, `String`, and plain structs — copy freely and are never
verbed.

An object is freed when its owner dies, and an owner is one of exactly
three things: a binding, a container, or the statement that made it.

```luce run
import std.strings

func main():
    for round in range(0, 3):
        var row = new Array(Int, 4)   # fresh every iteration
        row.fill(round)
        print(f"round {round} first {row[0]}")
        # row is freed here, every time around — memory stays flat
    for word in "a b c".split(""):    # never named: freed when the
        print(word)                   #   for statement completes
```

```output
round 0 first 0
round 1 first 1
round 2 first 2
a
b
c
```

## Aliasing is free

`let y = x` gives you a second name for the same object. Nothing is
tracked and nothing is copied.

```luce run
func main():
    var xs = [1, 2, 3]
    let view = xs             # an alias; xs still owns
    view.append(4)            # one list, two names
    print(f"{len(xs)} elements")
```

```output
4 elements
```

The cost of that freedom is that an alias can outlive its owner. When
it does, using it is a trap with a line number, not undefined
behaviour:

```luce trap
func main():
    var xs = [1, 2]
    let view = xs
    free(xs)                  # released early, on purpose
    print(String(view[0]))
```

```output
loom: trap: object used after free [use_after_free]
    at main (main.luc:5:5)
```

## Keeping something needs a word

Storing a *named* object into a container or a struct field, or handing
it to a function that will keep it, is where the compiler stops
guessing. It wants you to say which you meant.

```luce fail
func main():
    var index = new Map(String, List(Int))
    var hits = [12, 40]
    index["a.luc"] = hits
```

```output
luce: compile failed
main.luc:4:5: a container keeps its object elements; write give hits to hand it over, or copy hits to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        index["a.luc"] = hits
        ^~~~~~~~~~~~~~~~~~~~~
```

The two answers are `give` and `copy`:

```luce run
func main():
    var index = new Map(String, List(Int))

    var hits = [12, 40]
    index["a.luc"] = give hits      # transfer: the map owns it now

    var template = [0, 0]
    index["b.luc"] = copy template  # a duplicate; template stays mine
    template.append(1)

    index["c.luc"] = [7, 8]         # fresh: nobody owned it, no word

    print(f"{len(index)} entries, template still has {len(template)}")
```

```output
3 entries, template still has 3
```

After `give hits`, the name `hits` is *poisoned*: touching it is a
compile error to the end of its scope. That rule is deliberately blunt
— it is source-order and branch-insensitive, so you never have to
reason about which arm of an `if` ran.

```luce fail
func main():
    var sink = new List(List(Int))
    var xs = [1]
    if len(xs) > 0:
        sink.append(give xs)
    print(String(len(xs)))
```

```output
luce: compile failed
main.luc:6:22: xs was given away and cannot be touched again in this scope [OWNERSHIP.md S10, S29] [luce.sema.own]
        print(String(len(xs)))
                         ^~
```

Because keeping always transfers, **a container always owns its object
elements** — a dangling element is not something you can write.
Freeing a container frees everything it owns, recursively.

## Calls borrow

Passing an object to a function is a borrow, with no word at either
end. A borrowed parameter may read and mutate contents freely; what it
may not do is *keep* the object — store it, return it, give it away or
free it.

```luce run
func fill(xs: List(Int), upto: Int):
    for i in range(0, upto):
        xs.append(i * i)

func total(values: List(Int)) -> Int:
    var sum = 0
    for value in values:
        sum += value
    return sum

func main():
    var squares: List(Int) = []
    fill(squares, 5)                 # no word: a borrow
    print(f"{len(squares)} values totalling {total(squares)}")
```

```output
5 values totalling 30
```

A function that *does* want to keep says so in its signature, and the
caller echoes it at the call site. Ownership handoffs are never
invisible.

```luce run
func stash(index: Map(String, List(Int)), hits: give List(Int)):
    index["latest"] = give hits

func main():
    var index = new Map(String, List(Int))
    var mine = [1, 2]
    stash(index, give mine)          # said at both ends
    stash(index, [3, 4])             # fresh needs no word
    print(f"latest has {len(index["latest"])}")
```

```output
latest has 2
```

## return moves

Whatever a function returns, the caller owns. That is the one place a
transfer needs no keyword, because there is nothing else it could
mean — and it is why returning a *borrowed* parameter is a compile
error.

```luce run
import std.strings

func squares(upto: Int) -> List(Int):
    var out: List(Int) = []
    for i in range(0, upto):
        out.append(i * i)
    return out                    # moves out; the caller owns it

func main():
    var values = squares(5)
    var text: List(String) = []
    for value in values:
        text.append(String(value))
    print(text.join(" "))
```

```output
0 1 4 9 16
```

## free, for when you want the memory back now

`free(x)` is legal on an owned name and poisons it exactly like
`give`. Casual code never needs it; a program holding something large
that it has finished with sometimes does.

```luce run
func main():
    var big = new Array(Int, 100000)
    big.fill(7)
    let sum = big[0] + big[99999]
    free(big)                     # done with it, on purpose
    print(f"sum {sum}")
```

```output
sum 14
```

## What this buys

Nothing can leak: every object is owned by a binding, a container, or
a statement temporary, and all three have defined death points. There
is no collector to pause, no reference count to increment on every
assignment, and no cycle problem to have.

What it costs is the one dynamic backstop you have met — an alias used
after its owner released it traps `use_after_free` — plus the
occasional `give` or `copy` on a line the compiler could not read your
mind on.

[Memory without a collector](/guide/memory/) is the long version, with
the measurements and with the alternatives that were considered and
refused.
