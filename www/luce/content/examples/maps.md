# Maps

A `map(K, V)` is an insertion-ordered dictionary. `K` is `long` or
`string`. Lookup, insertion and update are O(1): the entries stay a
dense array in arrival order, with a hash index over it.

```luce run
func main():
    var ages = {"ada": 36, "grace": 45, "alan": 41}
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

`{key: value, ...}` creates a fresh mutable map. Entries are evaluated
in order, so a later equal key replaces the earlier value. Empty `{}`
is refused because it cannot say either type; use `new map(K, V)`.

A file-scope map is declared with `const` and belongs to the program
root. It is immutable, and duplicate folded keys are a compile error:

```luce run
const WORDS = {"and": true, "break": true, "const": true}

func main():
    print(string(WORDS.has("const")))
```

```output
true
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
        counts[word] += 1

    for word, seen in counts:
        if seen > 1:
            print(f"{word}: {seen}")
```

```output
the: 3
```

There is no first-sighting arm, and no `get(word, 0)`. **A compound
store defines the key it writes into**, at the value type's zero — so
`counts[word] += 1` starts a new word at `0` and increments it, and
`notes[key] += "text"` starts a new one at `""`. The zero is the
value, not an identity element: `counts[missing] *= 2` is `0`.

This is the one read in the language that creates what it reads, and
it is a read the operator to its left has already declared a write.
`counts[word] = counts[word] + 1` still traps on the first
occurrence — a read on the right of an `=` declares nothing, and a map
that invented values on being asked would answer `0` for every
mistyped key. It is the distinction an operating system draws when it
maps a page of zeroes on the first *write* and faults on a wild read.

Maps only: `xs[0] += 1` on an empty list is still `index_bounds`. An
index is a position in something that already has a shape, and
`append` is the verb that grows a list.

`keys()` and `values()` hand back fresh lists the receiver owns.
`values()` copies the map's values into that list, so it is refused
when the value type carries `file` or `task`.

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
