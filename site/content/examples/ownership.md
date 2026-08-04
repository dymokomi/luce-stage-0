# give, copy and free

Most Luce code never says any of these. They appear at exactly four
places: storing a named object somewhere that outlives the statement,
passing one to a function that will keep it, duplicating one, and
releasing one early.

## The default: nothing to say

```luce run
func main():
    var xs = [1, 2, 3]          # xs owns the list
    xs.append(4)
    xs = [5, 6]                 # the old list is freed here
    let alias = xs              # two names, one object
    alias.append(7)
    print(f"{len(xs)} elements")
    # the scope ends: everything owned here is freed
```

```output
3 elements
```

## give — transfer

```luce run
func main():
    var index = new Map(String, List(Int))
    var hits = [12, 40]
    index["a.luc"] = give hits    # the map owns it now
    print(f"stored {len(index["a.luc"])}")
```

```output
stored 2
```

After `give`, the name is poisoned to the end of its scope — using it
is a compile error, not a runtime surprise.

```luce fail
func main():
    var sink = new List(List(Int))
    var xs = [1, 2]
    sink.append(give xs)
    print(String(len(xs)))
```

```output
luce: compile failed
main.luc:5:22: xs was given away and cannot be touched again in this scope [OWNERSHIP.md S10, S29] [luce.sema.own]
        print(String(len(xs)))
                         ^~
```

Poisoning is source-order and branch-insensitive, which is why giving
an outer name from inside a loop is refused: the second iteration
would use a name that is gone.

```luce fail
func main():
    var sink = new List(List(Int))
    var xs = [1]
    for i in range(0, 3):
        sink.append(give xs)
```

```output
luce: compile failed
main.luc:5:21: xs is declared outside this loop; the next iteration would use a given-away name — create it fresh inside the loop, or copy [OWNERSHIP.md S30] [luce.sema.own]
            sink.append(give xs)
                        ^~~~~~~
```

## copy — duplicate

`copy` is a deep copy: the object and everything it owns, recursively.
Its cost is visible at the call site, which is the point.

```luce run
func main():
    var nested = new List(List(Int))
    nested.append([1, 2])

    let independent = copy nested
    independent[0].append(3)

    print(f"source inner {len(nested[0])}, copy inner {len(independent[0])}")
```

```output
source inner 2, copy inner 3
```

`copy` is always legal on anything you can read, including a borrowed
parameter — it is the escape hatch when `give` is not what you meant.

```luce run
func remember(store: List(List(Int)), values: List(Int)):
    store.append(copy values)      # values is borrowed; copy is allowed

func main():
    var store = new List(List(Int))
    var mine = [1, 2, 3]
    remember(store, mine)
    mine.append(4)
    print(f"stored {len(store[0])}, mine {len(mine)}")
```

```output
stored 3, mine 4
```

## give at both ends

A function that keeps a parameter says so in its signature, and the
caller echoes it. There is no way to hand over ownership silently.

```luce run
func stash(store: List(List(Int)), values: give List(Int)):
    store.append(give values)

func consume(values: give List(Int)):
    print(f"consuming {len(values)}")
    # values is owned here and dies here

func main():
    var store = new List(List(Int))
    stash(store, [1, 2])           # fresh: no word
    var mine = [3, 4, 5]
    stash(store, give mine)        # named: said at both ends
    consume([9])
    print(f"{len(store)} stored")
```

```output
consuming 1
2 stored
```

A borrowed parameter may mutate contents all it likes. Borrowing is
about *lifetime*, not about immutability.

```luce fail
func keep(store: List(List(Int)), values: List(Int)):
    store.append(values)

func main():
    var store = new List(List(Int))
    keep(store, [1])
```

```output
luce: compile failed
main.luc:2:18: a container keeps its object elements; values is a borrowed parameter and can never be given away — store copy values, or take values as give in the signature [OWNERSHIP.md S12, S21] [luce.sema.own]
        store.append(values)
                     ^~~~~~
```

## free — early release

```luce run
func main():
    var big = new Array(Int, 200000)
    big.fill(3)
    let sample = big[199999]
    free(big)                      # the memory goes back now
    print(f"sample {sample}")
```

```output
sample 3
```

`free` poisons the name exactly like `give`, so the compiler catches
the ordinary mistake. What it cannot catch is an *alias*, and that
traps:

```luce trap
func main():
    var xs = [1, 2]
    let view = xs
    free(xs)
    print(String(view[0]))
```

```output
loom: trap: object used after free [use_after_free]
    at main (main.luc:5:5)
```

The other dynamic backstop is giving away an object a container
already owns, reached through an alias:

```luce trap
func main():
    var first = new List(List(Int))
    var second = new List(List(Int))
    var item = [1]
    let alias = item
    first.append(give item)        # first owns it now
    second.append(give alias)      # …and this is the one dynamic check
```

```output
loom: trap: object is owned by a container [not_owned]
    at main (main.luc:7:5)
```
