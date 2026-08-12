# Unions

An [enum](../enums/) names the values in a set. Some values need more
than a name: a shape is *a circle with a radius* or *a rectangle with
a width and a height*, and a JSON value is one of six things, two of
which contain more JSON. A `union` declares that set — one of these,
and the language always knows which — and `match` is how you take one
apart.

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

Members are **namespaced always**, like an enum's, and a payload's
fields are **named, always**. Construction is the member's name with
named arguments — the same shape struct construction has, defaults
included — and a bare member like `Shape.empty` takes no parentheses,
because parentheses mean a payload.

At least one member must carry a payload. A union of bare names *is*
an enum — cheaper in every way, with a backing width and `Method(n)` —
and writing one as a union is refused by a sentence that says so.

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

## match is the only door

There is no field access on a union value and no tag test operator:
the only way to reach a payload is a `match` arm that proved which
member it is. That is why reading the wrong member's payload is not a
runtime error in Luce — it is nothing at all. No program can write it.

An arm names its member bare and, when it wants the payload, lists the
member's fields. Each field binds a local **by its own name** in the
arm's scope. List all of them or none — `circle:` is legal and binds
nothing, for the arm that only cares which member it is — but a
partial list is refused, naming what is missing.

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

Everything you know about `match` from enums carries over unchanged:
without an `else` every member must have an arm, so the day somebody
adds a member, every match that did not name it stops compiling and
the compiler says where.

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

## What a binding is

A payload field of a value type — a number, a string, a `bool` —
binds as an ordinary copy. A payload field that is an *object* binds
as an **alias** of what the value owns, exactly like `let y = x` in
the [memory chapter](../ownership/): reading and mutating through it
touch the one object, and keeping it somewhere needs `copy`.

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

Ownership itself arrives with no new rule. A union that *could* carry
an object counts as carrying one — the compiler does not know which
member a value holds — so keeping one somewhere takes `give` or
`copy`, whichever member it happens to be. The verbs mean exactly
what they mean for a struct that carries a list; there is nothing new
to learn, which was the point.

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

`free(u)` is refused, as it is for a struct: a union releases
whatever its live member owns when its scope ends, and the specs
prove the release with a leak census rather than a verb.

## The zero

Every type in Luce has a zero, because `var s: Shape` declares now and
fills later, and `new array(Shape, 3)` fills three cells with
something. A union's zero is its **first declared member**, with
every payload field at its own zero — the same rule an enum has, one
level up.

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

## Recursion goes through containers

A member may not contain its own union directly — that value would be
infinite, for the same reason a struct cannot contain itself — and
the refusal names the fix.

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

A `list` or a `map`, though, is one reference however much it holds —
so the recursive type every language wants, the JSON tree, is written
with the containers carrying the recursion. Building it, walking it
and freeing it are the ownership rules you already have.

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

The `give` on the last construction is the ordinary rule for storing
a named object into something; written inline —
`Json.array(items = new list(Json))` — a fresh container is silent.

## Absence, names, and no ==

`Shape?` works everywhere `T?` works, which is also what ends a
recursion without a container: [absence](../absence/) is the
terminator.

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

That last line used `string(u)`: it answers the member's **name**,
exactly as `string(m)` does for an enum, and an f-string hole follows.
The payload is never formatted — printing a whole `Json` tree is a
job for a function you write, like `total` above.

What a union does not have is `==`. Two values could hold different
members, or the same member with different payloads, and a single
`bool` would flatten a question the language wants you to ask
properly:

```luce fail
union Shape:
    empty
    circle(radius: double)

func main():
    let a = Shape.empty
    let b = Shape.empty
    assert(a == b)
```

```output
luce: compile failed
main.luc:8:12: two Shape values are not compared with ==; match on each and compare what the arms carry [UNION.md D16] [luce.sema.union]
        assert(a == b)
               ^~~~~~
```

**The refusal follows the union wherever a comparison reaches it.** A
struct's `==` is field-by-field `==`, so a struct holding a `Shape` is
not compared either, and neither is `xs.find(v)` or `xs.contains(v)`
over a list or an array of them — a search is `==` under another
spelling. Each says the same thing and offers the same two moves:
`match` on the member and compare what the arms carry, or keep what
identifies the member beside it — a name, an enum — and compare that.

A union may not be a map *key* either — keys are `long`, `string` and
enums, and a union has no key form: keep it in the value and key by
what identifies it.

## Methods

A union takes the methods and static namespace functions a
[struct](../functions/) takes, under the same rules: a plain member
function has implied `self`, a namespace member says `static func`.

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

## What a union is not

It is not an unchecked overlay: there is no way to read a value as a
member it does not hold, in any build mode. It is not a replacement
for `T?`, which stays its own mechanism — `Shape?` above is an
optional *of* a union, not a union wearing a costume. And a member is
not a type: you cannot declare a `let c: Shape.circle`, because a
value of that type could only ever be one thing, and `match` already
says which arm you are in.
