# Memory

Luce has no garbage collector. It has no reference counting — not in
the language, not in the runtime, not hidden anywhere. And it has no
`malloc`/`free` bookkeeping in ordinary code.

What it has instead is **scope ownership**: the binding that received
a fresh container object or resource owns it, and the owning scope
releases it. Most programs never write a memory word.

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
[46 numbered situations](/ref/ownership/), each one addressable on its
own, and the compiler quotes their numbers in its diagnostics.

## What owns what

**Container objects** — `list`, `map`, `array`, `builder` — are owned,
as are structs that transitively contain one. **Resources** — `file`
and `task` — use the same one-owner model, but cannot be copied because
there is one file or worker behind the handle. A struct carrying a
resource inherits that rule: the whole struct is owned and non-copyable.
**Values** — `long`, `double`, `bool`, `string`, and structs carrying
nothing owned — copy freely and are never verbed.

An ordinary run-created object or resource is released when its owner
dies. Its owner is a binding, a container, or the statement that made
it. A file-scope constant container instead belongs to the program
root and dies when that runtime is torn down; [the constants
chapter](../constants/) shows that fourth owner.

```luce run
import std.strings

func main():
    for round in range(0, 3):
        var row = new array(long, 4)   # fresh every iteration
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
    print(string(view[0]))
```

```output
loom: trap: object used after free [use_after_free]
    at main (main.luc:5:5)
```

## Keeping something needs a word

Storing a *named* container object, resource or carrying struct into a
container or a struct field, or handing it to a function that will keep
it, is where the compiler stops guessing. It wants you to say which you
meant.

```luce fail
func main():
    var index = new map(string, list(long))
    var hits = [12, 40]
    index["a.luc"] = hits
```

```output
luce: compile failed
main.luc:4:5: a container keeps its owned elements; write give hits to hand it over, or copy hits to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        index["a.luc"] = hits
        ^~~~~~~~~~~~~~~~~~~~~
```

For the resource-free graph in this example, the two answers are `give`
and `copy`. A graph carrying `file` or `task` cannot be copied, and only
a live owning name can be given. A borrowed resource parameter needs a
`give` signature plus ownership from every caller; a field/index view or
an alias with no available live owner must remain a borrow or be
restructured before an adopting use:

```luce run
func main():
    var index = new map(string, list(long))

    var hits: list(long) = [12, 40]
    index["a.luc"] = give hits      # transfer: the map owns it now

    var template: list(long) = [0, 0]
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

Because keeping always transfers, **a container always owns its owned
elements** — container objects, resources, and carrying structs alike.
A dangling element is not something you can write. Releasing a
container recursively releases everything it owns.

## Calls borrow

Passing a container object, resource, or carrying struct to a function
is a borrow, with no word at either end. A borrowed parameter may use
the borrowed thing freely; what it may not do is *keep* it — store it,
return it, give it away, or free it.

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
func stash(index: map(string, list(long)), hits: give list(long)):
    index["latest"] = give hits

func main():
    var index = new map(string, list(long))
    var mine: list(long) = [1, 2]
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

func squares(upto: long) -> list(long):
    var out: list(long) = []
    for i in range(0, upto):
        out.append(i * i)
    return out                    # moves out; the caller owns it

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

## free, for when you want the memory back now

`free(x)` is legal on an owned container or resource handle and poisons
it exactly like `give`. A carrying struct releases its fields at scope
end rather than taking this explicit form. Casual code never needs
`free`; a program holding something large that it has finished with
sometimes does.

```luce run
func main():
    var big = new array(long, 100000)
    big.fill(7)
    let sum = big[0] + big[99999]
    free(big)                     # done with it, on purpose
    print(f"sum {sum}")
```

```output
sum 14
```

## What this buys

The ratified rule says nothing can leak: every ordinary container object
or resource is owned by a binding, a container, or a statement
temporary, while a constant container is owned by the program root; all
four have defined death points. There is no collector to pause or
reference count to increment on every assignment.

One current implementation breach is tracked explicitly: an adopting
store can still put an owner inside its own descendant, creating a
self-owned cycle with no death point. The proposed fix is an
`ownership_cycle` trap at the store; it is pending rather than being
rounded up as fixed on this page. The compiler's direct refusal of
resource `x = x` or `x = alias_of_x` is a different, redundant
same-graph assignment check and does not inspect descendant adoption.

What it costs is the one dynamic backstop you have met — an alias used
after its owner released it traps `use_after_free` — plus the
occasional `give` or `copy` on a line the compiler could not read your
mind on.

[Memory without a collector](/guide/memory/) is the long version, with
the measurements and with the alternatives that were considered and
refused.
