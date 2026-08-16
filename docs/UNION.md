# Unions

A `union` is a tagged sum type: a value of a union type is exactly one of
the type's members, and the language always knows which. Each member may
carry named payload fields of its own. A union is a value type — it copies
when assigned or passed — and `match` is the only way to read one, so
asking a union for the wrong member's payload is unrepresentable rather
than checked.

```luce
union Shape:
    empty
    circle(radius: f64)
    rect(width: f64, height: f64)

func area(s: Shape) -> f64:
    match s:
        empty:
            return 0.0
        circle(radius):
            return 3.0 * radius * radius
        rect(width, height):
            return width * height

func main():
    assert(area(Shape.circle(radius = 2.0)) == 12.0)
    assert(area(Shape.rect(width = 3.0, height = 4.0)) == 12.0)
```

## Declaring a union

A declaration mirrors `struct` and `enum`: `union` and a TitleCase type
name, then one snake_case member per indented line. A member carries a
parenthesized field list — `circle(radius: f64)` — or nothing at all,
in which case it is written bare.

Payload fields are named, always. A positional payload such as
`circle(f64, f64)` is refused: a payload field list is a struct's
field list, and it names its fields the way a struct does, with defaults
available through the same checker:

```luce
union Shape:
    empty
    rect(width: f64, height: f64 = 2.0)

func area(s: Shape) -> f64:
    match s:
        empty:
            return 0.0
        rect(width, height):
            return width * height

func main():
    assert(area(Shape.rect(width = 3.0)) == 6.0)
    assert(area(Shape.rect(width = 3.0, height = 5.0)) == 15.0)
```

**At least one member must carry a payload.** A union of only bare members
is an enum — cheaper in every way, with a backing width, `i32(m)` and
`Method(n)` — and writing one is refused by a sentence naming `enum`.

A union member is not a number and not a type: there is no `= value`, no
backing width, no `Shape(n)`, and `let c: Shape.circle` is refused because
a member is a value of the union, not a type of its own.

## Constructing a value

A value is a namespaced call with named arguments. A payload-less member is
written with no parentheses, because parentheses mean a payload:

```luce
union Json:
    null
    number(value: f64)
    array(items: list[Json])

func main():
    let a = Json.null
    let b = Json.number(value = 3.0)
    let c = Json.array(items = [b])
    assert(str(a) == "null")
```

Writing `Json.number` bare where a payload is expected is a construction
error naming the fields it wants, never a function value.

## match is the only door

There is no field access on a union value, no tag test, and no way to name
a payload outside a `match` arm. An arm names a member; a payload arm lists
the fields it wants to bind, each by the field's own name:

```luce
union Reading:
    missing
    scalar(value: f64)
    labeled(value: str)

func describe(r: Reading) -> str:
    match r:
        missing:
            return "missing"
        scalar(value):
            return str(value)
        labeled(value):
            return value

func main():
    assert(describe(Reading.scalar(value = 1.5)) == "1.5")
    assert(describe(Reading.labeled(value = "seen")) == "seen")
```

An arm may name its member bare and bind nothing — the arm that only cares
which member it is:

```luce
union Shape:
    empty
    circle(radius: f64)

func kind(s: Shape) -> i64:
    match s:
        empty:
            return 0
        circle:
            return 1

func main():
    assert(kind(Shape.empty) == 0)
    assert(kind(Shape.circle(radius = 9.0)) == 1)
```

A partial field list is refused, naming the missing fields the way struct
construction does. Exhaustiveness works exactly as it does for enums
(`docs/ENUMS.md`): without an `else`, every member must appear, so a member
added later turns every `match` that missed it into a compile error; an
`else` stands for the members the arms did not name; a duplicate arm and an
`else` that covers nothing are refused. An arm binding is an ordinary name
in the arm's scope, like `catch NAME:`, and obeys the no-shadowing rule.

The scrutinee may be any expression of union type. A temporary — the result
of a call, for instance — lives to the end of the statement, and the
`match` *is* the statement, so an arm's binding is valid for the whole arm.

## Payload bindings and memory

Nothing about the memory model (`docs/MEMORY.md`) is special for unions. A
union is a value type: it copies when assigned or passed, a payload field
that is a **value type** copies with it, and a payload field that is a
**reference type** — a container such as `list` or `map` — is
shared like any reference. Common paths retain it while the union is held;
full last-release coverage remains the gate in `docs/MEMORY.md`. There are no ownership verbs, because a value
type never had any.

A payload binding names the payload. For a **value** payload the binding is
an ordinary copy; for a **reference** payload the binding is another
reference to the same object, so reading or mutating through it is seen by
whoever else holds it:

```luce
union Json:
    null
    array(items: list[i64])

func main():
    let doc = Json.array(items = [1, 2])
    match doc:
        null:
            assert(false)
        array(items):
            items.append(3)      # items is doc's own list
    match doc:
        null:
            assert(false)
        array(items):
            assert(len(items) == 3)
```

Construction stores the payload the same way: a value payload is copied in,
a reference payload is shared into the value. Storing a union in a list or a
field copies the union value; a reference payload inside it is retained, so
the object it names stays alive for as long as any copy does.

## Recursion, finiteness, and the terminator

A union may name itself indirectly through a reference-typed container,
which is how a recursive shape like a JSON tree is written. The recursion
travels through the container's single reference, so the type is finite by
construction and completed ARC frees the tree at its last reference — no boxing
keyword, no arena, no tracing collector:

```luce
union Json:
    null
    number(value: f64)
    array(items: list[Json])
    object(fields: map[str, Json])

func total(j: Json) -> f64:
    match j:
        null:
            return 0.0
        number(value):
            return value
        array(items):
            var sum: f64 = 0.0
            for item in items:
                sum = sum + total(item)
            return sum
        object(fields):
            var sum: f64 = 0.0
            for key in fields.keys():
                let item = fields.get(key)
                if item != none:
                    sum = sum + total(item)
            return sum

func main():
    var items = new list[Json]
    items.append(Json.number(value = 1.5))
    items.append(Json.number(value = 2.5))
    let doc = Json.array(items = items)
    assert(total(doc) == 4.0)
```

**Direct self-containment is infinite and is refused.** A member that
unconditionally contains the union — `cons(head: i64, tail: Chain)` — is
refused by the same strongly-connected-component walk that refuses a struct
containing itself, and the diagnostic names the two fixes: a `?` or a
container. `tail: Chain?` stops the recursion at absence rather than at a
layout, and `Shape?` is a writable type. (`Shape??` is not representable.)

## The zero value

A union's zero is its first declared member, with every payload field at
its own zero. A late `var`, an `array[Shape, _]` cell, and a `list[Shape]`
element all start there, whether the first member is bare or payload-
carrying:

```luce
union Shape:
    empty
    circle(radius: f64)

union Reading:
    sample(value: f64, count: i64)
    missing

func main():
    var s: Shape
    match s:
        empty:
            assert(true)
        circle:
            assert(false)
    var r: Reading
    match r:
        sample(value, count):
            assert(value == 0.0)
            assert(count == 0)
        missing:
            assert(false)
```

No ordering constraint comes with this: the only recursion a declaration
can carry goes through a `?` (whose zero is `none`) or a container (whose
zero is the null reference), and neither recurses, so the zero of the first
member always terminates.

## str(u)

`str(u)` answers the member's name — never the payload. Formatting a
payload is a separate concern and is not what `str` does here:

```luce
union Json:
    null
    boolean(value: bool)
    number(value: f64)
    text(value: str)

func main():
    assert(str(Json.null) == "null")
    assert(str(Json.boolean(value = true)) == "boolean")
    assert(str(Json.number(value = 3.0)) == "number")
    assert(str(Json.text(value = "words")) == "text")
```

## Equality is not available

`==` on a union is refused, by a sentence naming `match`: a union's shape
differs per member, so comparing two union values would be comparing two
different shapes, and what a program means by "equal" is a member-by-member
question that `match` asks precisely.

The refusal is transitive. A struct's `==` is field-by-field `==`, so a
struct holding a union cannot be compared either, and neither can
`xs.find(v)` or `xs.contains(v)` on a `list` of unions, which are `==` under
another spelling. What a program writes instead is a `match` on each side
and `==` on what the arms carry — often by keeping an `enum` beside the
union that identifies the member and searching that:

```luce
enum Kind:
    circle
    square

union Shape:
    circle(radius: f64)
    square(side: f64)

func kindOf(s: Shape) -> Kind:
    match s:
        circle(radius):
            return Kind.circle
        square(side):
            return Kind.square

func main():
    var shapes = new list[Shape]
    shapes.append(Shape.circle(radius = 1.0))
    shapes.append(Shape.square(side = 2.0))
    var kinds = new list[Kind]
    for s in shapes:
        kinds.append(kindOf(s))
    assert(kinds.contains(Kind.square))
    assert((kinds.find(Kind.circle) else -1) == 0)
```

## Methods and static functions

A union takes the methods and namespace functions a struct or enum takes
(`docs/SELF.md`): a plain member function is a method with an implied
`self`, a `static func` is a namespace function with none, and whether a
method writes its receiver is inferred. A method may mutate a receiver
holding a union exactly as it mutates any other value field.

## Containers, fields, and keys

`list[Json]`, `map[str, Json]`, `array[Shape, _]` and a struct field all
hold unions by construction, at the boxed cell a struct value uses. A
payload field may be a function value, stored as `(func(...) -> R)?`:

```luce
union Job:
    empty
    action(run: (func(i64) -> i64)?, label: str)

func twice(n: i64) -> i64:
    return n * 2

func apply(job: Job, n: i64) -> i64:
    match job:
        empty:
            return -1
        action(run, label):
            let chosen = run else twice
            return chosen(n)

func main():
    let job = Job.action(run = twice, label = "double")
    assert(apply(job, 20) == 40)
```

A union may **not** be a map *key* — keys are `i64`, `str`, or an
`enum` — and a struct field may be a union.

## Representation

Inside the compiler the word for a union is `variant`. A union value is a
struct-shaped run whose slot 0 is the member index and whose remaining
slots hold the payload fields; every run of one union type is padded to one
static length — one plus the widest member's field count — so a value's
shape can be re-derived from its static type alone, and a shorter member
pads its tail with slots that hold and release nothing. Reading a member's
tag or a payload field is an inline load; `match` costs one load and the
same compare-and-branch tree an enum's does.

The runtime (`libluce_rt`) learns nothing about unions: the same call that
builds a struct run builds a union's, the same walk that copies a struct
copies a union — value payloads by their bytes, reference payloads by
retaining them — and the completed release walk frees a union while releasing
whatever references its live member holds. Both engines — the
compiled path and the interpreter oracle — run the same MIR and are
compared on prints, traps, traces, and the leak census, so a missed release
or a double free of a payload shows up as a number in the spec suite rather
than in a program.
</content>
