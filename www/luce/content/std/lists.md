# std.lists

Comparator-driven list algorithms, implemented in ordinary Luce and
routed through list method syntax. Importing the module enables the
method; there is no `lists.sort_by(...)` namespace function.

## sort_by

```
xs.sort_by(before: func(T, T) -> bool)
```

`before(a, b)` answers whether `a` belongs before `b`. The comparator
should define a consistent strict order. Two elements are equivalent
when neither precedes the other, and stability preserves their original
order. The comparator is borrowed and positional. It may be a named
top-level or namespace function, or a capture-free lambda whose
parameter and result types come from the list.

```luce run
import std.lists

struct Player:
    name: string
    score: long

func by_score(a: Player, b: Player) -> bool:
    return a.score > b.score

func main():
    var players = [
        Player(name = "ada", score = 20),
        Player(name = "grace", score = 30),
        Player(name = "lin", score = 20),
    ]
    players.sort_by(by_score)
    for player in players:
        print(f"{player.name}: {player.score}")

    var values = [3, 1, 2]
    values.sort_by((a, b) -> a < b)
    print(f"{values[0]} {values[1]} {values[2]}")
```

```output
grace: 30
ada: 20
lin: 20
1 2 3
```

The sort mutates the list in place, is **stable**, and is O(n log n).
Empty and one-element lists are unchanged. Every element type is
accepted, including structs and heap objects. Object elements move
through the merge rather than being copied, so the ownership rules do
not acquire a comparator exception.

Without `import std.lists`, `sort_by` is a `luce.sema.import` error
that names the import to add. The checked implementation is a private
source template specialized by the compiler at the receiver's
monomorphic element type; neither MIR nor the runtime has a sorting
primitive.
