# Maps

A `map(K, V)` is an insertion-ordered dictionary. `K` is `long` or
`string`. Lookup, insertion and update are O(1): the entries stay a
dense array in arrival order, with a hash index over it.

```luce run
func main():
    var ages = new map(string, long)
    ages["ada"] = 36
    ages["grace"] = 45
    ages["alan"] = 41
    ages["ada"] += 1                 # the key is evaluated once

    for name, age in ages:
        print(f"{name} is {age}")

    print(f"{len(ages)} people")
    print(f"has grace: {ages.has("grace")}")
    print(f"get nobody: {ages.get("nobody", -1)}")

    ages.remove("alan")
    ages.remove("nobody")            # absent: a no-op, not an error
    print(f"{len(ages)} left")
```

```output
ada is 37
grace is 45
alan is 41
3 people
has grace: true
get nobody: -1
2 left
```

Indexing a key that is not there is a **trap**, on purpose. Asking a
map for something you did not put in it is a bug in the program, not
news from the world — so guard with `has`, or use `get(key, default)`,
which cannot trap.

```luce trap
func main():
    var ages = new map(string, long)
    ages["ada"] = 36
    print(string(ages["nobody"]))
```

```output
loom: trap: key not found in map [key_missing]
    at main (main.luc:4:5)
```

## Counting

The `map` counting idiom, which is what most real uses are:

```luce run
import std.strings

func main():
    let text = "the cat sat on the mat the end"
    var counts = new map(string, long)
    for word in text.split(" "):
        counts[word] = counts.get(word, 0) + 1

    for word, seen in counts:
        if seen > 1:
            print(f"{word}: {seen}")
```

```output
the: 3
```

`keys()` and `values()` hand back fresh lists the receiver owns.

```luce run
func main():
    var stock = new map(long, string)
    stock[3] = "fig"
    stock[1] = "pear"

    let ids = stock.keys()
    let names = stock.values()
    print(f"{len(ids)} keys, first {ids[0]}")
    print(f"{len(names)} values, first {names[0]}")
```

```output
2 keys, first 3
2 values, first fig
```
