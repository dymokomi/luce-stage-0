# Control Flow

Luce uses indentation for blocks. A block follows `:` and is indented by
four spaces. Conditions are `bool`; numbers and strings are not implicitly
truthy.

A block whose body is a single statement may be written on one line, after
the `:`, with no indentation:

```luce module file=classify.luc
func classify(n: i64) -> str:
    if n == 0: return "zero"
    elif n < 10: return "small"
    else: return "big"
```

This is the same block, one statement long — every construct that opens a
block (`if`/`elif`/`else`, `while`, `for`, `match` arms, and function,
`init`, `deinit`, and `catch` bodies) accepts the one-line form. There is
no statement separator, so an inline block holds exactly one statement.

Control flow is statement-oriented: `if`, `while`, and `for` choose which
statements run rather than producing a value, so to choose an answer you
return from each branch or assign a previously declared `var`. `match` is the
exception — it also has an expression form that yields a value directly (see
[Enumerations](/guide/enums/)).

## Branching

Use `if`, any number of `elif` branches, and an optional `else`:

```luce run
func main():
    for step in range(0, 6):
        if step % 3 == 0:
            print(f"{step}: fizz")
        elif step % 2 == 0:
            print(f"{step}: even")
        else:
            print(f"{step}: odd")
```

```output
0: fizz
1: odd
2: even
3: fizz
4: even
5: odd
```

Luce has no ternary or `switch` expression. For a fallback value, use the
optional operator described in [Absence](/guide/optionals/).

Every arm opens its own lexical scope. A name declared inside an arm ends at
that arm; an assignment to an existing outer `var` remains visible after the
conditional. If every arm returns, the compiler knows execution does not
continue below the statement.

## `while`

`while` repeats while its condition is true:

```luce run
func main():
    var remaining = 27
    var steps = 0
    while remaining != 1:
        if remaining % 2 == 0:
            remaining = remaining // 2
        else:
            remaining = 3 * remaining + 1
        steps += 1
    print(f"27 reaches 1 in {steps} steps")
```

```output
27 reaches 1 in 111 steps
```

The condition is checked before every iteration, so a false initial condition
runs the body zero times. Luce has no `do`/`while`; put the first operation
before the loop when it must happen once.

## `for`

`for` iterates a range or a collection. With one binding it yields each
element. With two bindings it yields an index and element for a list or
array, and a key and value for a map.

```luce run
func main():
    for i in range(0, 3):
        print(f"range {i}")

    let words = ["fig", "pear", "plum"]
    for word in words:
        print(f"word {word}")

    for index, word in words:
        print(f"{index} is {word}")
```

```output
range 0
range 1
range 2
word fig
word pear
word plum
0 is fig
1 is pear
2 is plum
```

`range(low, high)` produces `i64` values starting at `low` and excluding
`high`. It is increasing and has no step argument. A one-name map loop yields
keys in insertion order; a two-name map loop yields key and value. List and
array order is index order.

Do not change the size of a collection while iterating it. Replacing an
existing element is allowed when the collection place is writable; appending,
removing, or otherwise changing its extent is refused or traps at the
operation that violates the iteration contract. See [Collection
Types](/guide/collections/) for the collection operations.

## Matching closed alternatives

`match` handles every member of an enum or union. Without `else`, it must be
exhaustive. This is useful when adding a new member should make every decision
site visible to the compiler.

```luce run
union Result:
    idle
    value(number: i64)
    failed(message: str)

func describe(result: Result) -> str:
    match result:
        idle:
            return "idle"
        value(number):
            return f"value {number}"
        failed(message):
            return f"failed: {message}"

func main():
    print(describe(Result.value(number = 7)))
```

```output
value 7
```

An enum arm names only its member. A union arm may bind all payload fields by
their declared names, as above, or bind none by writing `value:`. The bindings
exist only inside that arm. An `else` arm is useful when the remaining members
genuinely share one policy; omit it when each member deserves an explicit
decision. [Enumerations](/guide/enums/) and [Unions](/guide/unions/) explain
the two data models.

## `break` and `continue`

`continue` starts the next iteration. `break` leaves the loop:

```luce run
func main():
    var first_big = -1
    for value in [3, 9, 4, 20, 5]:
        if value < 10:
            continue
        first_big = value
        break
    print(f"first value over ten: {first_big}")
```

```output
first value over ten: 20
```

Leaving a scope also releases the references held by that scope. A function
can return from inside a loop; there is no `defer` construct.

`break` and `continue` apply to the innermost loop. They cannot carry a value.
A statement after an unconditional `break`, `continue`, `return`, `trap`, or
`error` in the same block is rejected as unreachable, which usually exposes
an accidental ordering mistake rather than code worth keeping.

## `pass`

`pass` does nothing. A block cannot be empty, so `pass` is how a branch
or a match arm says "handle this case by doing nothing" without a busy
placeholder:

```luce run
enum Signal:
    go
    stop
    wait

func main():
    var log = ""
    for s in [Signal.go, Signal.stop, Signal.wait, Signal.go]:
        match s:
            go:
                log = log + "g"
            stop:
                log = log + "s"
            wait:
                pass
    print(log)
```

```output
gsg
```

Control falls through `pass` to whatever follows it.

## Recursion

Functions can call themselves. A recursion limit turns runaway recursion
into a reported trap instead of an uncontrolled native-stack failure.

```luce run
func factorial(n: i64) -> i64:
    if n <= 1:
        return 1
    return n * factorial(n - 1)

func main():
    for n in range(1, 8):
        print(f"{n}! = {factorial(n)}")
```

```output
1! = 1
2! = 2
3! = 6
4! = 24
5! = 120
6! = 720
7! = 5040
```

Recursion is ordinary function calling: parameters use the same value-copy or
reference-sharing rules, and each call owns its local references until it
returns. Prefer a loop for simple accumulation; use recursion when the data or
algorithm is naturally recursive and the depth is understood.

The exact statement grammar, scope rules, and unreachable-code checks are in
[Statements and Declarations](/guide/reference/statements/). Continue with
[Functions](/guide/functions/).
