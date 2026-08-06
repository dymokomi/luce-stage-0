# Expressions

## Precedence

Loosest to tightest:

| Level | Operators | Associativity |
|---|---|---|
| 1 | `or` | left |
| 2 | `and` | left |
| 3 | `==` `!=` `<` `<=` `>` `>=` | **non-associative** |
| 4 | `else`, `catch` | **right** |
| 5 | `+` `-` | left |
| 6 | `*` `/` `%` | left |
| 7 | prefix `not` `-` `give` `copy` | right |
| 8 | postfix `.field` `[index]` `(call)` | left |

So `x else 0 > 5` compares the fallback, `x else n + 1` falls back to
the sum, and `a else b else c` is a real chain.

## The two shapes the parser refuses

Both are legal in a language Luce reads like and mean something
different here. Rather than pick a winner the parser refuses them and
names both readings. Both are fixed by one pair of parentheses.

### `not` in front of a comparison

`not` is a prefix operator, so it binds *tighter* than `==` — the C,
Zig and Rust reading. Python's `not` binds *looser*, so a Python
reader reads `not a == b` as `not (a == b)` and gets the opposite
answer whenever both operands are `bool`.

```luce fail
func main():
    let a = true
    let b = false
    print(string(not a == b))
```

```output
luce: compile failed
main.luc:4:18: 'not' binds tighter than '==': write '(not a) == …' for this reading, or 'not (a == …)' for Python's [luce.parse.precedence]
        print(string(not a == b))
                     ^~~
```

### Chained comparison

`a < b < c` is one comparison in Python and two in C. Luce has
neither: the comparisons are non-associative.

```luce fail
func main():
    print(string(1 < 2 < 3))
```

```output
luce: compile failed
main.luc:2:24: chained comparison: write '1 < 2 and 2 < 3' [luce.parse.chain]
        print(string(1 < 2 < 3))
                           ^
```

This costs nothing — `(a < b) < c` was always a type error one stage
later — and comparing two `bool`s with `(a < b) == (c < d)` is still
legal, because the parentheses start a new chain.

## Arithmetic

`+ - * / // %` on `long` and on `double`. `+` also concatenates
`string`s. Mixing an `long` and a `double` widens the `long`.

`//` is **floor division** and `%` is the modulus that pairs with it:
they floor together, so `%` takes the sign of the divisor and
`b * (a // b) + (a % b) == a` holds for every pair.

| `a` | `b` | `a // b` | `a % b` |
|---:|---:|---:|---:|
| 7 | 3 | 2 | 1 |
| −7 | 3 | −3 | 2 |
| 7 | −3 | −3 | −2 |
| −7 | −3 | 2 | −1 |

`long` arithmetic is checked: overflow, and `//` or `%` by zero, are
traps in every build mode. `double` arithmetic is IEEE and does not
trap.

## Comparison

`== != < <= > >=` order `long`, `double` and `string`. `==` and `!=`
also apply to `bool` and to objects, where they compare identity.

## Logic

`and`, `or`, `not` take `bool` and only `bool`, and `and`/`or`
short-circuit. There is no truthiness: no other type is a condition.

## Operators Luce does not have

The table above is the whole set. The operators other languages have
are answered by name, with the Luce spelling in the sentence rather
than a complaint about the second character:

| Written | Luce |
|---|---|
| `x++`, `x--` | `x += 1`, `x -= 1` |
| `&&`, `\|\|` | `and`, `or` |
| `!x` | `not x` |
| `===`, `!==` | `==`, `!=` — which already compare by value |
| `<>` | `!=` |
| `**` | `math.pow(x, y)`, or `math.ipow(x, y)` for `long` |
| `<<`, `>>`, `&`, `\|`, `^`, `~` | nothing: there are no bitwise operators |

```luce fail
func main():
    var i = 0
    i++
```

```output
luce: compile failed
main.luc:3:6: there is no '++' operator: write 'x += 1' to increment [luce.parse.expression]
        i++
         ^~
```

Two of these are also legal expressions when they are spaced or
followed by an operand, and there the existing reading wins: `a - -b`
is a subtraction of a negation, `--a` is a double negation, and
`a < > b` is not a `<>`.

## Calls

Positional arguments fill parameters left to right, and a call site
may **name** any argument: `size(3, height = 4)`. The first named
argument ends the positional run — everything after it must be named —
and named arguments may be written in any order. Names are never
required. Arguments are evaluated in the order they are *written* and
bound to the slots they *name*; the two differ only when a call
reorders. A parameter may declare a trailing **default**, a
compile-time constant filled in wherever a call omits the argument.
There are no variadics. Functions are not values — a name in call
position denotes a function, statically.

```luce run
func grown(base: long, step: long = 5, twice: bool = false) -> long:
    var total = base + step
    if twice:
        total = total * 2
    return total

func main():
    print(string(grown(1)))
    print(string(grown(1, twice = true)))
    print(string(grown(step = 0, base = 2)))
```

```output
6
12
2
```

A positional argument may not follow a named one:

```luce fail
func size(width: long, height: long) -> long:
    return width * height

func main():
    let a = size(width = 1, 2)
```

```output
luce: compile failed
main.luc:5:29: a positional argument cannot follow a named one; write height = … [luce.sema.call]
        let a = size(width = 1, 2)
                                ^
```

Forms:

```
name(args)                  a function in this file
module.name(args)           a function in an imported module
Struct.name(args)           a function in a struct's namespace
module.Struct.name(args)    both
receiver.method(args)       sugar; see below
```

## Calls that answer more than one value

A call whose signature is a [return shape](../types/#return-shapes)
may stand in exactly two places:

```
let low, high = minmax(xs)      # the right of a destructuring bind
rng.next()                      # a statement, all values discarded
```

Everywhere else is `luce.sema.call`, including `return minmax(xs)`
from a function with the same shape. Go allows that pass-through and
pays for it with a rule saying a multi-valued call used as arguments
must be the only arguments; refusing it is what leaves this rule with
no exceptions. Bind the values, then return them.

`catch` supplies one value and so cannot supply a shape: a fallible
multi-return is propagated with `try`, or discarded as a statement.

## Method sugar

`receiver.method(args)` is resolved by the receiver's type into a
plain function with the receiver first. It is sugar, not dispatch.

That is true of a **user** method too: `p.length()` *means*
`Point.length(p)`, resolved at compile time, and `Point.length(p)`
stays callable. A function declared inside a struct is a method
exactly when its first parameter is `self`
([statements](../statements/#methods)).

A namespaced `Struct.func` or `module.func` call shares the syntax and
wins when the head names a declaration. The two are worth telling
apart out loud, because a struct in Luce is used for both:

> `Struct.func(x)` is a **namespace** call — the struct is a folder
> and `x` is an ordinary first argument. `x.foo()` is a **method**
> call — the struct is a type and `x` is its receiver. The only thing
> that distinguishes them is whether the declaration's first parameter
> is the word `self`.

Methods on a `string` other than `byte_at` and `find_byte` route to the
`strings` standard module: `s.split(",")` *is* `strings.split(s, ",")`
and needs `import std.strings` in scope, or it is a `luce.sema.import`
diagnostic naming the missing import.

Because a method is a function, its arguments are judged like a
function's, and the two ways to get them wrong are two diagnostics.
Too many or too few is a count, `luce.sema.method`, naming the method
and both counts:

```luce fail
func main():
    var xs = new list(long)
    xs.append(1, 2)
```

```output
luce: compile failed
main.luc:3:5: append takes 1 argument, got 2 [luce.sema.method]
        xs.append(1, 2)
        ^~~~~~~~~~~~~~~
```

A wrong type is `luce.sema.type`, naming the position, the type the
method takes and the type it was handed — underlined at the argument
rather than at the call:

```luce fail
func main():
    var xs = new list(long)
    xs.append("hello")
```

```output
luce: compile failed
main.luc:3:15: argument 1 of append is long, got string [luce.sema.type]
        xs.append("hello")
                  ^~~~~~~
```

A method the receiver does not have names the receiver, and suggests
a spelling when one is close enough:

```luce fail
func main():
    var xs = new list(long)
    let found = xs.has(1)
```

```output
luce: compile failed
main.luc:3:17: list has no method has (has append insert remove pop sort reverse find contains clear; join lives in strings) [luce.sema.method]
        let found = xs.has(1)
                    ^~~~~~~~~
```

## Indexing and slicing

| Form | Meaning |
|---|---|
| `xs[i]` | list or rank-1 array element; bounds-checked |
| `grid[r, c]` | multi-dimensional array element |
| `m[k]` | map get; a missing key traps |
| `xs[a:b]` | a **new list**, owned by the receiver; deep when elements are objects |
| `s[a:b]` | a `string` slice; still a value; checks UTF-8 boundaries |

Open slice ends default to `0` and to the length.

## Construction

```
[1, 2, 3]                  a list literal; element type inferred
[]                         empty; needs an annotated binding
new list(T)
new map(K, V)
new array(T, size, ...)
new builder()
Struct(field = expr, ...)  every field, by name
```

## Ownership operators

`give x` transfers ownership and poisons `x` to the end of its scope.
`copy x` deep-copies. Both apply only to objects and to
object-carrying structs; using one on a value is a compile error.

A verb in a pure borrow position — a builtin argument, a
non-adopting method argument, an operator operand — is refused: a
`give` must always have an owner to receive it.

## Narrowing

After a test on a `T?`, the name *is* its payload within the region
the test dominates. Five shapes narrow:

```
if x != none:      ...    the then arm
if x == none:      ...    the else arm
if x == none: return      an early exit narrows everything below it
if x != none and x > 3:   the rest of the condition
while x != none:   ...    the loop body
```

An assignment of a plain value narrows too.

Narrowing applies to **locals and parameters only**, never to fields
or elements, which can change between the test and the use. It stops
at anything that could undo it: a loop body that assigns the name
re-enters with whatever it left, so the name widens for the whole
loop, and an `if` keeps only what both arms agree on.

A test or a fallback that can never fire is a `luce.sema.absent`
diagnostic: once a name is known to hold a value, saying so again is
dead code, not caution.

## `else` — the null-coalescing operator

`a else b` yields `a`'s payload when it is present and `b` otherwise,
evaluating `b` only when needed. It associates to the right.

`trap("…")` and `error("…")` never return, so they may stand as the
right operand: `x else trap("…")` is the assert-unwrap, and it is why
there is no force-unwrap sigil.

## `try` and `catch`

`try CALL` propagates a failure to the caller, releasing what this
frame owns. It requires the enclosing function to declare `!`.

`catch` has three spellings:

```
EXPR catch FALLBACK        an expression; both sides must agree on ownership
CALL catch:                a handler block, guarding exactly one call
    ...
CALL catch NAME:           the same block, with the error's message bound
    ...
```

The block form attaches to a call written as a statement and to a
plain assignment, and to nothing else. `NAME` is an immutable `string`
scoped to the handler; the expression form takes no binding.

A fallible call whose outcome is neither tried nor caught is
`luce.sema.fallible`.
