# Absence

Add `?` to a type when a value may be absent. `T?` has either a `T` or the
value `none`. This is separate from failure (`!`), which is covered in
[Failure](../failure/).

```luce run
func main():
    var user: string? = none
    let limit: long? = 10
    let parsed = parse_int("42")
    let bad = parse_int("hello")
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

An optional can be a local, parameter, return value, or struct field. It is
not a container element or map value, and the language does not nest `?`.

## Narrowing

Testing an optional narrows a local or parameter in the branch where it is
known to be present. No unwrap operator is needed:

```luce run
func describe(value: long?) -> string:
    if value == none:
        return "nothing"
    return f"the number {value * 2}"

func main():
    print(describe(21))
    print(describe(none))
```

```output
the number 42
nothing
```

The narrowing also works through a condition and an early return:

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

Narrowing is deliberately limited to names. A field or element may change
between its test and its use; bind it to a local before testing. A loop or
branch widens a name again when an assignment could invalidate the proof.

## Fallbacks with `else`

`a else b` evaluates `b` only if `a` is `none`. It associates to the right,
so several fallbacks can be chained.

```luce run args=hello
func main(args: list(string)):
    let count = parse_int(args[0]) else 10
    let pair = parse_int("x") else parse_int("41") else 0
    print(f"count {count}, pair {pair}")
```

```output
count 10, pair 41
```

Use `else trap(...)` when absence is a programmer error:

```luce trap
func main():
    let text = "not a number"
    let n = parse_int(text) else trap(f"expected a number, got {text}")
    print(string(n))
```

```output
loom: trap: expected a number, got not a number [explicit_trap]
    at main (main.luc:3:5)
```

Using an optional where a plain value is required is a compile error. The
diagnostic suggests testing or providing a fallback:

```luce fail
func main():
    let n = parse_int("7")
    print(string(n + 1))
```

```output
luce: compile failed
main.luc:3:18: operands of + are long? and long, and there is no conversion between them; test it first (if n != none:) or supply a fallback (n else …) [luce.sema.type]
        print(string(n + 1))
                     ^~~~~
```

## Recursive value structs

An optional field gives a value struct a finite recursive shape:

```luce run
struct Node:
    value: long
    next: Node?

func main():
    let third = Node(value = 3, next = none)
    let second = Node(value = 2, next = third)
    let first = Node(value = 1, next = second)

    var here: Node? = first
    var total: long = 0
    while here != none:
        total += here.value
        here = here.next
    print(f"sum {total}")
```

```output
sum 6
```

An optional carrying an object follows that object's ordinary ownership
rule. `none` owns nothing. A declared `var` without an initializer is a
different feature: it receives the type's zero value.

```luce trap
func main():
    var report: builder
    report.append("x")
```

```output
loom: trap: null object reference [null_object]
    at main (main.luc:3:5)
```

Use `T?` when absence is valid; use an uninitialized `var` only when the
type's zero value is the intended placeholder. Next: [Unions](../unions/).
