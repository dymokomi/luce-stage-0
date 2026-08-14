# std.lists

`std.lists` adds one method to every `list(T)`: `sort_by`. It is a method
route, not a namespace function, so write `values.sort_by(comparator)` after
importing the module.

```text
import std.lists
```

## `sort_by`

```text
values.sort_by(before: func(T, T) -> bool)
```

`before(a, b)` returns `true` when `a` belongs before `b`. The sort mutates
the receiver in place, is stable, and uses O(n log n) comparisons. When
neither element precedes the other, their original order is preserved. Empty
and one-element lists are unchanged.

The comparator can be a named function, a static function, or a capture-free
lambda. Its parameter type is the list's element type. The comparator is
borrowed for the call; sorting does not change ownership of object elements.

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
        print(player.name)

    var numbers = [3, 1, 2]
    numbers.sort_by((a, b) -> a < b)
    print(f"{numbers[0]} {numbers[1]} {numbers[2]}")
```

```output
grace
ada
lin
1 2 3
```

Without `import std.lists`, `sort_by` is not a list method. It is available
only for lists, not arrays, and the receiver must be mutable because the
operation writes its order.
