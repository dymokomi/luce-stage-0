# Types

Luce is statically typed with inference. Every expression has exactly
one type, known at compile time. There is exactly **one implicit
conversion**: an `Int` widens to a `Float` wherever a `Float` is
required. Nothing narrows, and nothing else converts.

An annotation is optional wherever the initializer decides the type,
and required where nothing does — an empty list literal, a `var` with
no value.

## Values and objects

The line between them decides everything about memory.

**Values** copy on assignment and on call, and nobody frees them:
`Bool`, `Int`, `Float`, `String`, and `struct`s. A value
never takes an ownership word.

**Heap objects** are referenced, created with `new` or a literal, and
freed by scope ownership: `List(T)`, `Map(K, V)`, `Array(T, ...)`,
`Builder`. Copying a struct that contains a list copies the
*reference* — both structs see the same list.

## Scalars

| Type | Definition |
|---|---|
| `Bool` | `true` or `false`. The only type a condition may have. |
| `Int` | Signed 64-bit, two's complement, **checked**: overflow traps. |
| `Float` | IEEE 754 binary64. Does not trap. |
| `String` | Immutable UTF-8. A value. |

`/` is real division and always answers a `Float`. `//` is floor
division and `%` the modulus that pairs with it — both answer an `Int`
for `Int` operands, both floor, so `%` takes the sign of the divisor,
and both trap on a zero divisor. `/` does not trap: `1 / 0` is `inf`.

Mixing the two promotes: `Int op Float` widens the `Int` and answers a
`Float`, for `+ - * / %`. Comparison across the line does **not**
widen — it is exact, so `9007199254740993 == 9007199254740992.0` is
`false`, which widening would get wrong.

## Conversions

`Int(x)` and `Float(x)` are the numeric conversions written out, and
`Float(i)` is only ever needed where there is no operator to hang the
widening on. `Int(f)` truncates toward zero and traps if the value is
outside the `Int` range.

## struct

A named product of fields. Fields are annotated; construction names
every field; assignment copies.

```luce run
struct Point:
    x: Float
    y: Float

func main():
    let p = Point(x = 1.5, y = 2.5)
    var q = p                       # a copy
    q.x = 9.0
    print(f"{p.x} {q.x}")
```

```output
1.5 9
```

A struct may declare functions in its own namespace. They are plain
functions reached as `Struct.name(...)` — no receiver, no dispatch, no
inheritance.

A struct type is **object-carrying** if it transitively contains a
field of object type. Object-carrying structs follow the object
ownership rules when they are *kept*; plain-value structs never do.

Struct definitions may not be cyclic through plain fields. Recursion
goes through an optional field:

```luce run
struct Node:
    value: Int
    next: Node?

func main():
    let tail = Node(value = 2, next = none)
    let head = Node(value = 1, next = tail)
    let second = head.next            # bind the field, then test the name
    if second != none:
        print(f"{head.value} then {second.value}")
```

```output
1 then 2
```

Narrowing applies to locals and parameters, never to a field — which
could change between the test and the use — so the field is bound to a
name first.

The cycle rule is one scale of a single rule: **a struct's
unconditional size must be finite, and small.** A plain field's
payload is part of what the struct is, so it is counted through — a
struct of two struct fields doubles per level — and past 4096 values
the declaration is refused, just as an infinite one is. An optional
field counts as one whatever it holds, because its payload starts
absent and arrives only when a program builds one. So `?` answers both
refusals, and so does a container: a `List`, `Map` or `Array` is one
reference however much it holds.

## List(T)

A growable sequence. Created with a literal or `new List(T)`. An empty
literal requires an annotated binding.

`T` may be any value type or any object type. When `T` is an object
type the list **owns** its elements.

## Map(K, V)

An insertion-ordered dictionary. `K` is `Int` or `String`; `V` is any
type other than an optional. Index get, index set, `has` and `get`
are O(1): the entries stay a dense array in arrival order with a hash
index over it. Iteration is in insertion order.

## Array(T, ...)

Fixed shape, one to four dimensions, sizes given as runtime values at
`new`. Elements begin at the type's zero value: `0`, `0.0`, `false`,
`""`, a field-by-field zeroed struct, or — for object element types —
the null object, which traps on use until something is stored.

In a type annotation the shape is spelled with `_` for each axis:
`Array(Int, _, _)`.

`Array(Float, _)` is the numeric vector type `std.math`'s whole-array
operations take.

## Builder

Accumulates text. `String(builder)` hands back the `String`.

## Optionals: `T?`

A trailing `?` makes a type nullable. `none` is the absent value, and
it is legal only where a `T?` is expected — a plain type can never
hold it.

`T?` may be:

- a local variable
- a parameter
- a return type
- a struct field

`T?` may **not** be a container element type or a map value type, and
there is no `T??` — one `?` is all there is.

Absence owns nothing: a `List(T)?` holding an object owns it exactly
as a `List(T)` would, and holding `none` owns nothing.

Narrowing is described in [expressions](../expressions/#narrowing).

## Fallibility: `-> T!`

A trailing `!` on a **return type** says the function may raise an
error. `-> !` means it returns nothing or an error.

**`T!` is not a type.** Fallibility is an attribute of the function.
There is no `T!` to declare a variable of, to use as a container
element, or to write in a struct field, and `return x` in a `-> T!`
function returns `x` with nothing wrapped around it.

```luce fail
struct Holder:
    value: Int!

func main():
    print("unreachable")
```

```output
luce: compile failed
main.luc:2:15: expected end of line after the field, found '!' [luce.parse.expected]
        value: Int!
                  ^
```

## Zero values and late initialization

`var name: Type` with no initializer declares the binding, its type
and its scope. The slot holds the type's zero value until it is
assigned. For an object type that is the null object, and using it
traps `null_object`.

`let` always requires an initializer: a name that can never be
reassigned and holds nothing is a contradiction.

This is zero-initialization, not nullability. A slot that may
genuinely hold nothing is a `T?` and says so.

## Identity

`==` and `!=` on objects compare identity — whether two names denote
the same object — never contents.
