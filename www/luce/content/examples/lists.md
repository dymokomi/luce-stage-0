# Lists

A `list(T)` is a growable sequence. A literal infers its element type;
an empty literal needs an annotation.

```luce run
func main():
    var xs = [3, 1, 4, 1, 5]
    var empty: list(string) = []

    xs.append(9)
    xs.insert(0, 2)
    xs.remove(1)                 # by index
    print(f"{len(xs)} elements starting {xs[0]}")

    xs.sort()                    # in place, stable, O(n log n)
    xs.reverse()
    print(f"largest {xs[0]}, smallest {xs[len(xs) - 1]}")

    print(f"find(4) = {xs.find(4) else -1}, find(77) = {xs.find(77) else -1}")
    print(f"contains(5) = {xs.contains(5)}")

    let last = xs.pop()
    print(f"popped {last}, {len(xs)} left")

    empty.append("only")
    print(f"{empty[0]} / {len(empty)}")
```

```output
6 elements starting 2
largest 9, smallest 1
find(4) = 2, find(77) = -1
contains(5) = true
popped 1, 5 left
only / 1
```

`find` answers `-1` when the value is absent, which is a wart the
[status page](/status/) admits: `long?` exists now and the sentinel has
nothing holding it up.

## Sorting by a comparator

`std.lists` adds stable, in-place `sort_by`. Its comparator may be a
named function or a capture-free lambda and answers whether the first
argument belongs before the second.

```luce run
import std.lists

struct Player:
    name: string
    score: long

func main():
    var players = [
        Player(name = "ada", score = 20),
        Player(name = "grace", score = 30),
        Player(name = "lin", score = 20),
    ]
    players.sort_by((a, b) -> a.score > b.score)
    for player in players:
        print(f"{player.name}: {player.score}")
```

```output
grace: 30
ada: 20
lin: 20
```

The equal-score pair keeps its original order because the guarantee
is stable. The algorithm is O(n log n) and accepts owned elements as
well as values.

## Slices copy

`xs[a:b]` allocates a new list, owned by whoever receives it. Open
ends default to the beginning and the end. The slice deep-copies owned
elements. If the element type carries `file` or `task`, only equal
compile-time `long` bounds are admitted, because they prove the result
is empty and no resource is copied. A dynamically empty range is still
refused.

```luce run
func main():
    var xs = [10, 20, 30, 40, 50]
    var head = xs[0:2]
    let tail = xs[3:]
    head.append(999)
    print(f"head {len(head)}, tail {len(tail)}, source {len(xs)}")
```

```output
head 3, tail 2, source 5
```

## Lists of lists

A container always owns its owned elements, so putting a *named* list
into another one needs `give` or `copy`.

```luce run
func main():
    var rows = new list(list(long))
    rows.append([1, 2])              # fresh: no word needed

    var loose: list(long) = [3, 4]
    rows.append(give loose)          # transfer

    var template: list(long) = [0]
    rows.append(copy template)       # duplicate; template stays mine
    template.append(1)

    for index, row in rows:
        print(f"row {index} has {len(row)}")
    print(f"template still has {len(template)}")
```

```output
row 0 has 2
row 1 has 2
row 2 has 1
template still has 2
```

`pop()` hands an element *out* — the receiver owns it — while
`remove`, `clear` and overwriting an element free the old one right
away.

```luce run
func main():
    var rows = new list(list(long))
    rows.append([1, 2, 3])
    rows.append([4])

    var taken = rows.pop()           # ownership moves to `taken`
    print(f"took {len(taken)}, {len(rows)} rows left")

    rows[0] = [9, 9, 9, 9]           # the old [1,2,3] is freed here
    print(f"row 0 now has {len(rows[0])}")
    rows.clear()
    print(f"{len(rows)} rows")
```

```output
took 1, 1 rows left
row 0 now has 4
0 rows
```
