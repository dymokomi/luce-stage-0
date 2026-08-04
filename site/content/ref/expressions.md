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
answer whenever both operands are `Bool`.

```luce fail
func main():
    let a = true
    let b = false
    print(str(not a == b))
```

```output
luce: compile failed
main.luc:4:15: 'not' binds tighter than '==': write '(not a) == …' for this reading, or 'not (a == …)' for Python's [luce.parse.precedence]
        print(str(not a == b))
                  ^~~
```

### Chained comparison

`a < b < c` is one comparison in Python and two in C. Luce has
neither: the comparisons are non-associative.

```luce fail
func main():
    print(str(1 < 2 < 3))
```

```output
luce: compile failed
main.luc:2:21: chained comparison: write '1 < 2 and 2 < 3' [luce.parse.chain]
        print(str(1 < 2 < 3))
                        ^
```

This costs nothing — `(a < b) < c` was always a type error one stage
later — and comparing two `Bool`s with `(a < b) == (c < d)` is still
legal, because the parentheses start a new chain.

## Arithmetic

`+ - * / %` on `Int` and on `Float`. `+` also concatenates `String`s.
Mixing `Int` and `Float` is a compile error.

`Int` arithmetic is checked: overflow, and division or remainder by
zero, are traps in every build mode. `Float` arithmetic is IEEE and
does not trap.

## Comparison

`== != < <= > >=` order `Int`, `Float` and `String`. `==` and `!=`
also apply to `Bool` and to objects, where they compare identity.

## Logic

`and`, `or`, `not` take `Bool` and only `Bool`, and `and`/`or`
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
| `**` | `math.pow(x, y)`, or `math.ipow(x, y)` for `Int` |
| `<<`, `>>`, `&`, `\|`, `^`, `~` | nothing: there are no bitwise operators |
| `//` | `/`; `//` starts nothing, and a comment is `#` |

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

Arguments are positional and are evaluated left to right. There are no
default values, no named arguments, and no variadics. Functions are
not values — a name in call position denotes a function, statically.

Forms:

```
name(args)                  a function in this file
module.name(args)           a function in an imported module
Struct.name(args)           a function in a struct's namespace
module.Struct.name(args)    both
receiver.method(args)       sugar; see below
```

## Method sugar

`receiver.method(args)` is resolved by the receiver's type into a
plain function with the receiver first. It is sugar, not dispatch.

A namespaced `Struct.func` or `module.func` call shares the syntax and
wins when the head names a declaration.

String methods other than `byte_at` and `find_byte` route to the
`strings` standard module: `s.split(",")` *is* `strings.split(s, ",")`
and needs `import std.strings` in scope, or it is a `luce.sema.import`
diagnostic naming the missing import.

Because a method is a function, its arguments are judged like a
function's, and the two ways to get them wrong are two diagnostics.
Too many or too few is a count, `luce.sema.method`, naming the method
and both counts:

```luce fail
func main():
    var xs = new List(Int)
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
    var xs = new List(Int)
    xs.append("hello")
```

```output
luce: compile failed
main.luc:3:15: argument 1 of append is Int, got String [luce.sema.type]
        xs.append("hello")
                  ^~~~~~~
```

A method the receiver does not have names the receiver, and suggests
a spelling when one is close enough:

```luce fail
func main():
    var xs = new List(Int)
    let found = xs.has(1)
```

```output
luce: compile failed
main.luc:3:17: List has no method has (has append insert remove pop sort reverse find contains clear; join lives in strings) [luce.sema.method]
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
| `s[a:b]` | a `String` slice; still a value; checks UTF-8 boundaries |

Open slice ends default to `0` and to the length.

## Construction

```
[1, 2, 3]                  a List literal; element type inferred
[]                         empty; needs an annotated binding
new List(T)
new Map(K, V)
new Array(T, size, ...)
new Builder()
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

`catch` has two forms:

```
EXPR catch FALLBACK        an expression; both sides must agree on ownership
CALL catch:                a handler block, guarding exactly one call
    ...
```

The block form attaches to a call written as a statement and to a
plain assignment, and to nothing else.

A fallible call whose outcome is neither tried nor caught is
`luce.sema.fallible`.
