# Optionals

`T?` is a `T` that may not be there, and `none` is the value that is
not. It is the answer whenever "there is nothing here" is the whole
story, with no reason worth carrying.

## Creating an optional

A function declares an optional result by adding `?` to its value type. A
present value converts to that optional automatically; `none` supplies the
absent case.

```luce run
func first_even(values: list[i64]) -> i64?:
    for value in values:
        if value % 2 == 0:
            return value
    return none

func main():
    let found: i64? = first_even([3, 7, 12, 15])
    print(str(found else -1))
```

```output
12
```

`none` alone does not tell the compiler which `T` is absent, so a binding,
field, parameter, or result supplies the type. Luce has one optional layer:
`T??` is refused. This keeps every narrowing operation about one question—
present or absent—rather than an arbitrary stack of wrappers.

```luce run
func main():
    print(f"{parse_i64("42") else -1}")
    print(f"{parse_i64("nonsense") else -1}")
    print(f"{parse_f64("2.5") else 0.0}")
```

```output
42
-1
2.5
```

## Narrowing

After a test the name *is* its payload. There is no unwrap operator.

```luce run
func classify(text: str) -> str:
    let n = parse_i64(text)
    if n == none:
        return f"{text} is not a number"
    if n < 0:
        return f"{text} is negative"
    return f"{text} doubles to {n * 2}"

func main():
    print(classify("21"))
    print(classify("-3"))
    print(classify("x"))
```

```output
21 doubles to 42
-3 is negative
x is not a number
```

An early-exit guard narrows everything below it, which is the shape
most real code takes.

```luce run args=17
func main(args: list[str]):
    let raw = args[0]
    let n = parse_i64(raw)
    if n == none:
        print(f"not a number: {raw}")
        return
    print(f"{n} squared is {n * n}")     # n is i64 from here down
```

```output
17 squared is 289
```

Both `value != none` and `value == none` participate in narrowing. The
compiler follows the branch that proves presence; it does not treat an
arbitrary helper returning `bool` as proof. Narrowing is local control-flow
knowledge, not a runtime cast.

## else, chained

`else` associates to the right, so a chain of fallbacks reads left to
right and stops at the first one that is there.

```luce run
func main():
    let first = parse_i64("x") else parse_i64("y") else parse_i64("3") else 0
    print(str(first))

    let n = parse_i64("10")
    print(str(n else 0 > 5))     # else binds tighter than comparison
    print(str((n else 0) + 1))
```

```output
3
true
11
```

The fallback must be the payload type, another compatible optional, or an
expression such as `trap(...)` that does not return. It is evaluated only
when the left side is absent. Parenthesize a longer fallback when that makes
the intended grouping easier to see.

## Optionals as parameters and fields

```luce run
struct Setting:
    name: str
    limit: i64?

func describe(setting: Setting) -> str:
    let limit = setting.limit
    if limit == none:
        return f"{setting.name}: unlimited"
    return f"{setting.name}: {limit}"

func main():
    print(describe(Setting(name = "retries", limit = 3)))
    print(describe(Setting(name = "size", limit = none)))
```

```output
retries: 3
size: unlimited
```

Narrowing works on locals and parameters, never on a field or an
element — those could change between the test and the use. Bind the
field to a name and test that, which is what `describe` does above.

An optional class field does not keep a separate object model: when present,
it is an ordinary strong class reference unless the field is also declared
`weak`. A weak class or container field is necessarily optional because its
target may reach its last strong release at any time. Reading the weak place
produces an owned optional snapshot that is safe to narrow.

## Optional functions and containers

Parentheses distinguish an optional answer from an optional callable:

```text
func(str) -> i64?       # the function is present; its result may be absent
(func(str) -> i64)?     # the function value itself may be absent
```

Ordinary optional scalar or object elements are not stored directly in
lists, maps, or arrays. A map lookup already answers `V?`, and a nested
optional would be required to distinguish “missing key” from “present key
whose value is absent.” Model a meaningful third state with a union, or put
the optional in a small structure whose surrounding value gives it context.
Optional function values are the deliberate storage exception for fields and
sequence slots because function values have no zero value of their own; the
[function-value reference](/guide/reference/types/#function) gives the exact
slot rules.

## The assert-unwrap

There is no force-unwrap sigil. `x else trap("…")` says the same thing
and is greppable.

```luce trap
func main():
    let config = "port=notanumber"
    let port = parse_i64(config[5:len(config)]) else trap("bad port in config")
    print(str(port))
```

```output
loom: trap: bad port in config [explicit_trap]
    at main (main.luc:3:5)
```

Use this only for an invariant that really makes absence a programmer error.
If the caller can recover, return the optional, use a fallback, or convert the
case into a fallible error with a useful message.

## Choosing between optional, union, and error

Choose the type from the question the caller must answer:

| Situation | Result |
|---|---|
| a search may find no match | `T?` |
| several successful shapes carry different data | a `union` |
| a valid request may fail and the reason matters | `T!` |
| the program violated a checked precondition | trap |

For example, `parse_i64` uses absence because invalid text has no integer
answer. Opening a file is fallible because permission, path, and host failures
need a reason. A network state such as `idle`, `loading`, `ready(data)`, or
`failed(reason)` is usually a union because every alternative is meaningful
state, not merely a missing value.

The [Types reference](/guide/reference/types/#optionals-t) states the exact
storage and function-type grammar. Continue with [Unions](/guide/unions/).
