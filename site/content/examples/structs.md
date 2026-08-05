# Structs

A `struct` is a value aggregate. It copies on assignment and on call,
and nobody frees it.

```luce run
struct Rect:
    width: Float
    height: Float

    func area(self) -> Float:
        return self.width * self.height

    func scaled(self, factor: Float) -> Rect:
        return Rect(width = self.width * factor, height = self.height * factor)

    func grow(var self, factor: Float):
        self.width = self.width * factor
        self.height = self.height * factor

func main():
    let unit = Rect(width = 2.0, height = 3.0)
    var copy_of = unit
    copy_of.width = 10.0

    print(f"unit {unit.area()}, copy {copy_of.area()}")
    let big = unit.scaled(3.0)
    print(f"scaled {big.width}x{big.height} area {big.area()}")

    var growing = Rect(width = 1.0, height = 1.0)
    growing.grow(4.0)
    print(f"grown {growing.width}x{growing.height}")
```

```output
unit 6, copy 30
scaled 6x9 area 54
grown 4x4
```

A function declared inside a struct is a **method** when its first
parameter is `self`, and a **namespace function** when it is not.
`unit.area()` *means* `Rect.area(unit)` — the same call, resolved at
compile time, with no dispatch and no inheritance. The long form stays
callable, which is what lets a struct convert one function at a time.

`var self` marks a method that writes its receiver back: `growing.grow(4.0)`
means `growing = Rect.grow(growing, 4.0)`, copy in and copy out. Its
receiver has to be a `var`, and its struct has to carry no objects —
which is the same rule that already governs assignment and ownership,
not a new one.

## Nested places

Assignment targets a place, nested as deep as you like. The place is
read once and rebuilt, so every subscript is evaluated exactly once.

```luce run
struct Position:
    row: Int
    column: Int

struct Cursor:
    at: Position
    label: String

func main():
    var cursor = Cursor(at = Position(row = 0, column = 0), label = "main")
    cursor.at.row = 4
    cursor.at.column += 7
    print(f"{cursor.label} at {cursor.at.row},{cursor.at.column}")

    var cells = new List(Position)
    cells.append(Position(row = 1, column = 1))
    cells[0].column = 9
    print(f"cell {cells[0].row},{cells[0].column}")
```

```output
main at 4,7
cell 1,9
```

## Structs that carry objects

A struct containing a `List`, `Map`, `Array` or `Builder` — directly
or through another struct — is *object-carrying*, and follows the
object rules whenever it is **kept**.

```luce run
struct Bag:
    label: String
    items: List(Int)

func main():
    var bag = Bag(label = "a", items = [1, 2])   # fresh: bag owns it

    var loose = [3, 4]
    var second = Bag(label = "b", items = give loose)

    let alias = bag                # a struct copy aliases the same list
    alias.items.append(9)
    print(f"{bag.label} now has {len(bag.items)}")

    var bags = new List(Bag)
    bags.append(give bag)          # keeping a carrying struct needs a word
    bags.append(give second)
    bags.append(Bag(label = "c", items = [5]))   # fresh: silent
    print(f"{len(bags)} bags, first {bags[0].label}")
```

```output
a now has 3
3 bags, first a
```

Copying a struct never duplicates or moves the objects inside it —
ownership stays where it was. `copy bag` deep-copies them if that is
what you want.

## Recursive value structs

`Struct?` is how a value struct holds one of itself: the recursion
stops at absence rather than at a layout.

```luce run
struct Node:
    value: String
    next: Node?

func length(head: Node?) -> Int:
    var here = head
    var count = 0
    while here != none:
        count += 1
        here = here.next
    return count

func main():
    let c = Node(value = "c", next = none)
    let b = Node(value = "b", next = c)
    let a = Node(value = "a", next = b)
    print(f"{length(a)} nodes starting {a.value}")
    print(f"empty list: {length(none)}")
```

```output
3 nodes starting a
empty list: 0
```
