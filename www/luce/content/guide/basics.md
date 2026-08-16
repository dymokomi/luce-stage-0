# The Basics

Start with a complete program. Every executable has a function named
`main`; its indented body is the work the program performs.

```luce run
func main():
    print("hello, Luce")
```

```output
hello, Luce
```

Save that program as `hello.luc`, then build and run it:

```text
$ luce build hello.luc
$ ./hello
hello, Luce
```

The compiler names the executable after the source file. The
[Command-Line Tools](/guide/command-line/) chapter covers other artifact
types and build modes after you have something worth building.

## Command-line arguments

Declare a `list(string)` parameter on `main` when a program needs its
arguments. Leave the parameter out when it does not.

```luce run args=fig pear plum
func main(args: list[str]):
    if len(args) == 0:
        print("usage: greet NAME [NAME ...]")
        return
    var index = 0
    for name in args:
        index += 1
        print(f"{index}. hello, {name}")
```

```output
1. hello, fig
2. hello, pear
3. hello, plum
```

Arguments are strings. `parse_int` returns a `long?` because some text
is not an integer; `else` supplies a value when it is absent:

```luce run args=4
func main(args: list[str]):
    let times = parse_int(args[0]) else 1
    for i in range(0, times):
        print(f"line {i}")
```

```output
line 0
line 1
line 2
line 3
```

## Values and types

Every expression has one statically known type. You can annotate a value
or let its context infer the type. An unannotated integer literal defaults
to `int`; an unannotated fractional literal defaults to `float`.

```luce run
func main():
    let count = 7                 # i32
    let ratio: f64 = 0.5
    let ready = true              # bool
    let name = "Luce"             # str
    print(f"{count} {ratio} {ready} {name}")
```

```output
7 0.5 true Luce
```

## Naming a type

Use `alias` when a domain name makes an existing type easier to understand:

```luce run
alias UserId = i64
alias UserNames = map[UserId, str]

func display_name(names: UserNames, id: UserId) -> str:
    return names.get(id) else "unknown"

func main():
    var names: UserNames = new UserNames
    names[UserId(42)] = "Mina"
    print(display_name(names, 42))
```

```output
Mina
```

An alias is another spelling, not another type. `UserId` and `long` are
interchangeable, so use a `struct` when two values must not mix or when the
value needs fields and methods. Aliases may also name functions, optionals,
containers, structures, interfaces, enums and unions. They can refer forward
and form chains; cycles are rejected.

The target decides construction. An alias of a structure can construct it, an
enum or union alias can reach its members, and an owning-container alias
follows `new` as above. [Type aliases](/guide/reference/types/#type-aliases)
has the exact visibility, module, and diagnostic rules.

## Scalar types

| Type | Meaning |
|---|---|
| `bool` | `true` or `false`; only a `bool` can be a condition. |
| `byte` | Unsigned 8-bit storage. |
| `short` | Signed 16-bit storage. |
| `int` | Checked signed 32-bit integer. |
| `long` | Checked signed 64-bit integer. |
| `half` | IEEE binary16 storage. |
| `float` | IEEE binary32. |
| `double` | IEEE binary64. |
| `string` | Immutable UTF-8 text. |

Enums, structs and functions are values too. A function value has a type
such as `func(long) -> long` and is covered in [Functions](/guide/functions/).

Literals may be decimal, hexadecimal (`0xFF`) or binary (`0b1010`), with
underscores between digits. A fraction or exponent makes a floating-point
literal. Octal and hexadecimal floating-point literals are not accepted.

## Storage types

`byte`, `short` and `half` describe storage, not arithmetic. Operations
widen them to `int` or `float` first. Integer arithmetic is checked, so a
value does not wrap merely because it was stored in a narrow type.

```luce run
func main():
    var full: u8 = 255
    print(str(full + 1))
    print(str(full * full))
```

```output
256
65025
```

Narrow arrays are useful when storage size matters:

```luce run
func main():
    var pixels = new array[u8](4)
    pixels[0] = 255
    pixels[1] = 128
    print(str(pixels[0] + pixels[1]))
```

```output
383
```

Storing a value outside the destination range traps. Use an explicit
conversion, such as `byte(x % 256)`, when wrapping is intended.

## Numeric widening

The integer ladder is `byte` → `short` → `int` → `long`. The floating
ladder is `half` → `float` → `double`. Widening is implicit in the forward
direction. A value is never narrowed implicitly. When an integer and a
floating value meet, the common type is `double`.

```luce run
func main():
    let steps = 7
    let seconds = 2.5
    print(str(steps * seconds))
    let elapsed: f64 = steps
    print(str(elapsed))
    print(str(i64(seconds)))
```

```output
17.5
7
3
```

Comparisons across numeric types preserve the exact values being compared:

```luce run
func main():
    let after: i64 = 9007199254740993
    let rounded: f64 = 9007199254740992.0
    print(str(1 < 1.5))
    print(str(after == rounded))
```

```output
true
false
```

## Bindings

`let` prevents reassignment of a name. `var` permits it. Neither keyword
changes whether a referenced object is mutable.

```luce fail
func main():
    let limit = 10
    limit = 11
    print(str(limit))
```

```output
luce: compile failed
main.luc:3:5: limit is let-bound; use var for reassignment [luce.sema.let]
        limit = 11
        ^~~~~
```

Multiple mutable names can receive a function's multiple return values:

```luce run
func step(value: i64, at: i64) -> (i64, i64):
    return value + at, at + 1

func main():
    var value: i64 = 0
    var at: i64 = 0
    while at < 5:
        value, at = step(value, at)
    print(f"{value} {at}")
```

```output
10 5
```

There is no shadowing. Compound assignment evaluates its target once;
`counts[key] += 1` is the map-counting form.

Continue with [Basic Operators](/guide/operators/), or use
[Types](/guide/reference/types/) when you need the exact type rules.
