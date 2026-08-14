# Unions

An enum names alternatives. A union names alternatives that may also carry
data. The member name identifies the active shape, and `match` is the only
way to read its payload.

```luce run
union Shape:
    empty
    circle(radius: double)
    rect(width: double, height: double)

func area(s: Shape) -> double:
    match s:
        empty:
            return 0.0
        circle(radius):
            return 3.0 * radius * radius
        rect(width, height):
            return width * height

func main():
    print(string(area(Shape.circle(radius = 2.0))))
    print(string(area(Shape.rect(width = 3.0, height = 4.0))))
```

```output
12
12
```

Members are qualified (`Shape.circle`) and payload fields are named at
construction. A union with only payload-free members should be declared as
an enum:

```luce fail
union Flag:
    yes
    no

func main():
    return
```

```output
luce: compile failed
main.luc:1:1: no member of union Flag carries a payload; a set of bare names is an enum — write enum Flag: [luce.sema.union]
    union Flag:
    ^~~~~~~~~~
```

## `match` and payloads

An arm may bind all payload fields by their declared names, or bind none
with `member:`. A partial binding list is an error:

```luce fail
union Shape:
    empty
    rect(width: double, height: double)

func main():
    let s = Shape.empty
    match s:
        empty:
            return
        rect(width):
            return
```

```output
luce: compile failed
main.luc:10:9: this arm of Shape.rect is missing field height; an arm binds every field, or write 'rect:' to bind none [luce.sema.match]
            rect(width):
            ^~~~~~~~~~~
```

As with enums, a match without `else` must name every member:

```luce fail
union Shape:
    empty
    circle(radius: double)
    rect(width: double, height: double)

func main():
    let s = Shape.empty
    match s:
        empty:
            print("empty")
        circle(radius):
            print(string(radius))
```

```output
luce: compile failed
main.luc:8:5: this match has no arm for member rect of Shape; write one, or an else for everything the arms above do not name [luce.sema.match]
        match s:
        ^~~~~~~
```

## Payload ownership

Value payloads copy. A container payload is an alias to the object owned by
the union value, just as a struct field is:

```luce run
union Json:
    null
    array(items: list(long))

func main():
    let doc = Json.array(items = [1, 2])
    match doc:
        null:
            print("null")
        array(items):
            items.append(3)
    match doc:
        null:
            print("null")
        array(items):
            print(f"{len(items)} items, ending {items[2]}")
```

```output
3 items, ending 3
```

A union that may carry an object follows the normal `give` and `copy`
rules. The compiler therefore requires an explicit choice when placing a
named union in a container:

```luce fail
union Json:
    null
    number(value: double)
    array(items: list(Json))

func main():
    var values = new list(Json)
    var j = Json.number(value = 3.0)
    values.append(j)
```

```output
luce: compile failed
main.luc:9:19: a container keeps its owned elements; write give j to hand it over, or copy j to keep your own [OWNERSHIP.md S21] [luce.sema.own]
        values.append(j)
                      ^
```

## Zero and recursion

The zero value of a union is its first member, with each payload at its own
zero:

```luce run
union Reading:
    missing
    sample(value: double, count: long)

func main():
    var r: Reading
    match r:
        missing:
            print("missing")
        sample(value, count):
            print(f"{value} over {count}")
```

```output
missing
```

A value union cannot contain itself directly because that would have an
infinite size. Use an optional or a container for recursion:

```luce fail
union Chain:
    nil
    cons(head: long, tail: Chain)

func main():
    return
```

```output
luce: compile failed
main.luc:3:22: union Chain contains itself: Chain.cons.tail is Chain; a union is a value, so write tail: Chain? to let the chain end at absence [luce.sema.union]
        cons(head: long, tail: Chain)
                         ^~~~~~~~~~~
```

```luce run
union Json:
    null
    number(value: double)
    array(items: list(Json))

func total(j: Json) -> double:
    match j:
        null:
            return 0.0
        number(value):
            return value
        array(items):
            var sum: double = 0.0
            for item in items:
                sum = sum + total(item)
            return sum

func main():
    var items = new list(Json)
    items.append(Json.number(value = 1.5))
    items.append(Json.number(value = 2.5))
    items.append(Json.null)
    let doc = Json.array(items = give items)
    print(string(total(doc)))
```

```output
4
```

## Optionals and comparison

`Shape?` is an optional whose payload type is `Shape`; it uses the same
narrowing and `else` rules as every optional:

```luce run
union Shape:
    empty
    circle(radius: double)

func pick(want: bool) -> Shape?:
    if want:
        return Shape.circle(radius = 2.0)
    return none

func main():
    let found = pick(true)
    if found == none:
        print("no shape")
    else:
        match found:
            empty:
                print("an empty shape")
            circle(radius):
                print(f"a circle of radius {radius}")
    let sure = pick(false) else Shape.empty
    print(string(sure))
```

```output
a circle of radius 2
empty
```

Unions do not support `==`, ordering, or use as map keys. Match each value
and compare the fields that matter, or keep a separate enum/key for the
identity the program needs.

## Methods

Unions may define ordinary and static methods:

```luce run
union Shape:
    empty
    circle(radius: double)

    func area() -> double:
        match self:
            empty:
                return 0.0
            circle(radius):
                return 3.0 * radius * radius

    static func unit() -> Shape:
        return Shape.circle(radius = 1.0)

func main():
    let s = Shape.unit()
    print(string(s.area()))
```

```output
3
```

Next: [Failure](../failure/).
