# Lists

A `List(T)` is a growable sequence. A literal infers its element type;
an empty literal needs an annotation.

```luce run
func main():
    var xs = [3, 1, 4, 1, 5]
    var empty: List(String) = []

    xs.append(9)
    xs.insert(0, 2)
    xs.remove(1)                 # by index
    print(f"{len(xs)} elements starting {xs[0]}")

    xs.sort()                    # in place, stable, O(n log n)
    xs.reverse()
    print(f"largest {xs[0]}, smallest {xs[len(xs) - 1]}")

    print(f"find(4) = {xs.find(4)}, find(77) = {xs.find(77)}")
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
[status page](/status/) admits: `Int?` exists now and the sentinel has
nothing holding it up.

## Slices copy

`xs[a:b]` allocates a new list, owned by whoever receives it. Open
ends default to the beginning and the end.

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

A container always owns its object elements, so putting a *named* list
into another one needs `give` or `copy`.

```luce run
func main():
    var rows = new List(List(Int))
    rows.append([1, 2])              # fresh: no word needed

    var loose = [3, 4]
    rows.append(give loose)          # transfer

    var template = [0]
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
    var rows = new List(List(Int))
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
