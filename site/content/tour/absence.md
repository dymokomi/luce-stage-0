# Absence

A trailing `?` makes a type nullable. `Int?` is an `Int` that may not
be there, and `none` is the value that is not there.

`?` means nullable and **only** nullable. Failure is `!` and is never
spelled with a `?` — that is [the next chapter](../failure/).

```luce run
func main():
    var user: String? = none
    let limit: Int? = 10              # an Int? that is there
    let parsed = parse_int("42")      # Int?
    let bad = parse_int("hello")      # also Int?, and it is none
    print(f"user absent: {user == none}")
    print(f"parsed absent: {parsed == none}, bad absent: {bad == none}")
    user = "ada"
    print(f"user now: {user}, limit {limit}")
```

```output
user absent: true
parsed absent: false, bad absent: true
user now: ada, limit 10
```

A `T?` may be a local, a parameter, a return type, or a struct field.
It may not be a container element or a map value, and there is no
`T??` — one `?` is all there is.

## Narrowing is the feature

After a test, the name *is* its payload. There is no unwrapping
operator and no second spelling to learn.

```luce run
func describe(value: Int?) -> String:
    if value == none:
        return "nothing"
    return f"the number {value * 2}"   # value is Int here, not Int?

func main():
    print(describe(21))
    print(describe(none))
```

```output
the number 42
nothing
```

Five shapes narrow, and they are the ones real code writes:

```luce run
func main():
    let x = parse_int("7")

    if x != none:
        print(f"then arm: {x + 1}")

    if x != none and x > 3:
        print(f"the rest of the condition: {x}")

    if x == none:
        print("guard")
        return
    print(f"below an early-exit guard: {x * 10}")
```

```output
then arm: 8
the rest of the condition: 7
below an early-exit guard: 70
```

Narrowing applies to **locals and parameters only** — never to fields
or elements, which could change between the test and the use. Bind one
to a name and test that. It also stops at anything that could undo it:
a loop body that assigns the name re-enters with whatever it left, so
the name widens for the whole loop, and an `if` keeps only what both
arms agree on.

## else supplies a fallback

`a else b` evaluates `b` only when `a` is absent. It is the
null-coalescing operator, and it costs no new token: Python needs `??`
because `or` is broken there by truthiness, and Luce has neither
truthiness nor a ternary.

```luce run args=hello
func main():
    let count = parse_int(arg(0)) else 10
    let pair = parse_int("x") else parse_int("41") else 0
    print(f"count {count}, pair {pair}")
```

```output
count 10, pair 41
```

`else` binds looser than `+` and tighter than the comparisons, so
`x else 0 > 5` compares the fallback and `x else n + 1` falls back to
the sum. It associates to the right, so `a else b else c` is a real
chain.

`x else trap("…")` is the assert-unwrap, and it is greppable — which
is why there is no force-unwrap sigil in the language at all.

```luce trap
func main():
    let text = "not a number"
    let n = parse_int(text) else trap(f"expected a number, got {text}")
    print(String(n))
```

```output
loom: trap: expected a number, got not a number [explicit_trap]
    at main (main.luc:3:5)
```

## Using a T? where a T belongs

The compiler refuses it, and the message names the two ways out on the
name in front of you.

```luce fail
func main():
    let n = parse_int("7")
    print(String(n + 1))
```

```output
luce: compile failed
main.luc:3:18: operands of + are Int? and Int, and there is no conversion between them; test it first (if n != none:) or supply a fallback (n else …) [luce.sema.type]
        print(String(n + 1))
                     ^~~~~
```

So is a test or a fallback that can never fire: once a name is known
to hold a value, saying so again is dead code rather than caution.

## Recursive value structs

A struct field typed `Struct?` is how a value struct holds one of
itself. The recursion stops at absence rather than at a layout, so a
linked list of value structs needs no new machinery and no reference
counting.

```luce run
struct Node:
    value: Int
    next: Node?

func main():
    let third = Node(value = 3, next = none)
    let second = Node(value = 2, next = third)
    let first = Node(value = 1, next = second)

    var here: Node? = first
    var total = 0
    while here != none:
        total += here.value
        here = here.next
    print(f"sum {total}")
```

```output
sum 6
```

## Absence owns nothing

An optional inherits every ownership rule unchanged: a `List(Int)?`
holding an object owns it exactly as a `List(Int)` would, and holding
`none` owns nothing. `give`, `copy` and `free` demand a value that is
there, and so demand narrowing first.

## Declared now, filled later

There is a second, older shape that looks similar and is not. `var
name: Type` with no value declares the binding and its scope, and the
slot holds the type's **zero value** — 0, 0.0, `false`, `""`, a zeroed
struct, or for an object type the null object. Using an unfilled
object slot traps `null_object`.

```luce trap
func main():
    var report: Builder
    report.append("x")
```

```output
loom: trap: null object reference [null_object]
    at main (main.luc:3:5)
```

That is zero-initialization, not nullability. A slot that may
genuinely hold nothing is a `T?` and says so.
