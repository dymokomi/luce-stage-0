# Structs

A `struct` is a value aggregate. It copies on assignment and on call,
and nobody frees it.

```luce run
struct Rect:
    width: double
    height: double

    func area() -> double:
        return self.width * self.height

    func scaled(factor: double) -> Rect:
        return Rect(width = self.width * factor, height = self.height * factor)

    func grow(factor: double):
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

A plain function inside a struct is a **method** with implied `self`.
A namespace function says `static func` and has none. Methods are
called only through a value — `unit.area()` — with no dispatch or
inheritance and no type-qualified `Rect.area(unit)` form.

The compiler infers that `grow` writes its receiver from the field
stores in its body. `growing.grow(4.0)` therefore requires `growing`
to be a bare `var` binding and changes that slot in place. A reading
method such as `area` or `scaled` accepts a `let` or a temporary.

## Nested places

Assignment targets a place, nested as deep as you like. The place is
read once and rebuilt, so every subscript is evaluated exactly once.

```luce run
struct Position:
    row: long
    column: long

struct Cursor:
    at: Position
    label: string

func main():
    var cursor = Cursor(at = Position(row = 0, column = 0), label = "main")
    cursor.at.row = 4
    cursor.at.column += 7
    print(f"{cursor.label} at {cursor.at.row},{cursor.at.column}")

    var cells = new list(Position)
    cells.append(Position(row = 1, column = 1))
    cells[0].column = 9
    print(f"cell {cells[0].row},{cells[0].column}")
```

```output
main at 4,7
cell 1,9
```

## Structs that carry objects

A struct containing a `list`, `map`, `array` or `builder` — directly
or through another struct — is *object-carrying*, and follows the
object rules whenever it is **kept**.

```luce run
struct Bag:
    label: string
    items: list(long)

func main():
    var bag = Bag(label = "a", items = [1, 2])   # fresh: bag owns it

    var loose: list(long) = [3, 4]
    var second = Bag(label = "b", items = give loose)

    let alias = bag                # a struct copy aliases the same list
    alias.items.append(9)
    print(f"{bag.label} now has {len(bag.items)}")

    var bags = new list(Bag)
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

## Fields a module keeps

A field marked `private` — here through an indented `private:` region —
belongs to the file that declared it. `Account` keeps money in whole
cents so it never rounds, and the only way an importer can get one is
`account.open`, because a required private field closes construction
from outside. That is the factory pattern, and the compiler names it
when you need it.

```luce module file=account.luc
struct Account:
    owner: string

    private:
        cents: long

    func balance() -> double:
        return double(self.cents) / 100.0

    func deposit(amount: double):
        self.cents = self.cents + long(amount * 100.0)

func open(owner: string) -> Account:
    return Account(owner = owner, cents = 0)
```

```luce run
import account

func main():
    var a = account.open("dy")
    a.deposit(12.50)
    a.deposit(0.75)
    print(f"{a.owner} has {a.balance()}")
```

```output
dy has 13.25
```

`owner` said nothing, so it is public and crosses. `cents` did, so the
representation stays where the invariant is enforced:

```luce fail
import account

func main():
    var a = account.open("dy")
    a.cents = 100000
    print(f"{a.owner} has {a.balance()}")
```

```output
luce: compile failed
main.luc:5:5: cents of Account is private to account [luce.sema.private]
        a.cents = 100000
        ^~~~~~~
```

[The visibility chapter](/tour/visibility/) has the rest: the word on
functions and constants, `public`, regions, and what the compiler says
at every kind of crossing.

## Recursive value structs

`Struct?` is how a value struct holds one of itself: the recursion
stops at absence rather than at a layout.

```luce run
struct Node:
    value: string
    next: Node?

func length(head: Node?) -> long:
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
