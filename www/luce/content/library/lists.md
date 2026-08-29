# std.lists

`std.lists` adds one method to every `list[T]`: `sort_by`. It is a method
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

Use the built-in `values.sort()` when the element type already has the natural
ascending order you want. Use `sort_by` for descending order, a field of a
structure, case-insensitive text, or another application-defined relation.

The comparator describes order; it is not a scoring function. It should be
consistent for the duration of the call:

- `before(a, a)` is false;
- if `a` precedes `b`, `b` does not precede `a`;
- if `a` precedes `b` and `b` precedes `c`, `a` precedes `c`.

An inconsistent comparator does not give the algorithm one coherent order to
produce. Keep it deterministic and avoid mutating the list being sorted from
inside the callback.

The comparator can be a named function, a static function, a lambda, or a
capturing closure. Its parameter type is the list's element type. Sorting
calls the function during the operation and only rearranges the list's
existing elements; reference elements keep their identity.

```luce run
import std.lists

struct Player:
    let name: str
    let score: i64

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
    numbers.sort_by((a, b) => a < b)
    print(f"{numbers[0]} {numbers[1]} {numbers[2]}")
```

```output
grace
ada
lin
1 2 3
```

Stability is visible in the first result: Ada and Lin both score 20, and Ada
remains before Lin because she appeared first in the input. Stable sorting
lets a program sort by a secondary field and then by a primary field without
losing the earlier ordering.

## Capture sort policy

A block closure can carry a local choice without adding policy to the element
type:

```luce run
import std.lists

func main():
    let descending = true
    var values = [4, 1, 3, 2]
    let before: func(i64, i64) -> bool = func(a, b):
        if descending:
            return a > b
        return a < b
    values.sort_by(before)
    print(f"{values[0]} {values[1]} {values[2]} {values[3]}")
```

```output
4 3 2 1
```

The function type is non-fallible because sorting cannot partially reorder a
list and then propagate an error as though the original order remained. Do
fallible preparation before the call and let the comparator be a pure answer
over two elements.

The implementation is a stable merge sort written in Luce. It uses temporary
lists proportional to the input and O(n log n) comparisons. Elements are
moved among those lists rather than deep-copied; a value element keeps its
ordinary value semantics and a reference element keeps the same ARC identity.

Without `import std.lists`, `sort_by` is not a list method. It is available
only for lists, not arrays, and the receiver must be mutable because the
operation writes its order. A list slice is the straightforward way to sort
an independent outer list while keeping the original order:

```text
var ordered = values[0:len(values)]
ordered.sort_by(before)
```

Reference elements inside the slice remain shared. See [Collection
Types](/guide/collections/) for that copy boundary and [Closures](/guide/closures/)
for capture lifetime.
