# Functions

Functions name reusable work and make its boundary explicit. A declaration
states the accepted types, whether arguments have defaults, the result shape,
and whether the operation can fail. The body then uses ordinary statements to
produce that contract.

## Declaring and calling a function

Parameters have names and types. A single result follows `->`; a function that
only performs work omits the arrow:

```luce run
func gcd(a: i64, b: i64) -> i64:
    var left = a
    var right = b
    while right != 0:
        let next = left % right
        left = right
        right = next
    return left

func announce(label: str, value: i64):
    print(f"{label}: {value}")

func main():
    announce("gcd", gcd(1071, 462))
```

```output
gcd: 21
```

Every reachable path through a value-returning function must return a value of
the declared type. A no-result function may use bare `return` to leave early.
Code after an unconditional return is diagnosed as unreachable.

## Positional and named arguments

Arguments are positional by default. A caller can name them when the names
make the call clearer or when it wants to reorder them:

```luce run
func describe(name: str, count: i64, active: bool) -> str:
    return f"{name}: {count}, active={active}"

func main():
    print(describe("jobs", 3, true))
    print(describe(active = false, name = "workers", count = 2))
```

```output
jobs: 3, active=true
workers: 2, active=false
```

Once a call starts using named arguments, later arguments are named too. A
name must exist exactly once. The compiler reports missing, duplicated,
unknown, and misplaced arguments at the call rather than letting a shifted
position change the program silently.

Parameter names are part of the callable source contract for direct calls and
interface conformance. They are not part of a stored function type; calls
through a function value are positional.

## Default arguments

Trailing parameters may have compile-time defaults:

```luce run
func repeat_line(text: str, count: i64 = 1, prefix: str = ""):
    for index in range(0, count):
        print(prefix + text + " " + str(index + 1))

func main():
    repeat_line("ready")
    repeat_line("go", prefix = "> ", count = 2)
```

```output
ready 1
> go 1
> go 2
```

A required parameter cannot follow a defaulted one. Defaults are checked and
folded at the declaration, so they cannot depend on runtime state or a previous
argument. The caller either supplies an argument or receives the declared
value; there is no hidden overload selection.

Use a default when one value is an honest general policy. Use a separately
named function when two choices represent different operations rather than
one operation with a common setting.

## Passing values and references

Parameter passing follows the type’s ordinary memory behavior:

- numbers, text, structures, enumerations, and unions copy;
- classes and built-in containers retain and share their object; and
- a copied structure retains any reference fields it contains.

A parameter binding is local to the call. Reassigning it does not rebind the
caller’s name. Mutating a shared class or container is visible through other
aliases because they still name the same object. A writing structure method is
the separate receiver rule described in [Methods](/guide/methods/).

There is no call-site borrow, move, clone, or ownership annotation. The
concrete parameter type already determines whether the boundary copies a value
or shares a reference.

## Returning one value

`return expression` evaluates the answer before leaving the function. ARC
retains any reference needed by the caller, then releases locals and
temporaries abandoned by the return path.

Returning a structure copies its value. Returning a class, list, map, array,
file, task, or closure gives the caller another strong reference to the same
object or environment. A local reference therefore remains alive when the
returned value still owns it.

## Returning several values

A function may declare a return shape with two or more types. The caller
receives the results with a destructuring declaration or assignment:

```luce run
func bounds(values: list[i64]) -> (i64, i64):
    var low = values[0]
    var high = values[0]
    for value in values:
        if value < low:
            low = value
        if value > high:
            high = value
    return low, high

func main():
    let low, high = bounds([7, 2, 9, 4])
    print(f"{low} {high}")
```

```output
2 9
```

This is a call/receive shape, not a tuple value. It cannot be stored in one
variable, nested as a container element, or used as a general product type.
Each returned component is prepared before any destination is replaced, so a
parallel assignment does not expose a half-updated result.

Use a structure when several values form one concept that should be named,
stored, passed onward, or extended later. Use multiple returns for a local
operation whose answers are naturally received together.

## Fallible functions

Append `!` to the result when a correct call may fail and carries a reason. A
no-value fallible function writes bare `-> !`:

```luce run
func parse_port(text: str) -> i64!:
    let port = parse_i64(text) else error("not a number")
    if port < 1 or port > 65535:
        error("port out of range")
    return port

func main() -> !:
    print(str(try parse_port("8080")))
    print(str(parse_port("bad") catch -1))
```

```output
8080
-1
```

`try` passes the error out of the current fallible function. `catch` handles
one call with a fallback value or block. A caller cannot ignore a fallible
result, and a nonfallible function cannot use `try` without declaring its own
effect.

Failure is directional in function compatibility: a nonfallible implementation
can satisfy a fallible interface requirement because it never produces the
extra outcome. A fallible implementation cannot be used where the caller was
promised no error.

## Functions as values

A function declaration can land in a `func(...) -> ...` value and be passed to
another function:

```luce run
func twice(value: i64) -> i64:
    return value * 2

func apply(operation: func(i64) -> i64, value: i64) -> i64:
    return operation(value)

func main():
    let chosen: func(i64) -> i64 = twice
    print(str(apply(chosen, 21)))
    print(str(apply((value) -> value + 1, 41)))
```

```output
42
42
```

The function type contains explicit parameter types, result shape, and
fallibility. It does not contain parameter names. The expression lambda uses
the landing type for its parameter and result types.

Function values can also carry local state. [Closures](/guide/closures/)
introduces block bodies, shared mutable captures, snapshot/weak capture lists,
storage, cycles, and worker restrictions. [Methods](/guide/methods/) explains
how reading an instance method binds its receiver into the same function-value
representation.

## Recursion and call depth

A function may call itself directly or through other functions. Each active
call has its own parameters and locals. The runtime enforces a call-depth
budget, so unbounded recursion traps with a source trace rather than consuming
the host stack without limit.

Use recursion when the data or algorithm is naturally recursive and its depth
is controlled. Use a loop or explicit worklist for large linear input or a
graph whose depth is not trustworthy. Tail calls are not a separate language
guarantee.

## Entry functions

An executable enters through exactly one supported `main` shape:

```text
func main():
func main() -> !:
func main(args: list[str]):
func main(args: list[str]) -> !:
```

Use the argument form when the program reads command-line words. Use the
fallible form when an unhandled recoverable error should become the program’s
error report. A library artifact still carries its compiled entry contract for
the host; ordinary imported modules do not run top-level statements.

The exact call grammar, evaluation rules, and multi-value forms are in
[Expressions: Calls](/guide/reference/expressions/#calls) and [Statements and
Declarations: func](/guide/reference/statements/#func). Continue with
[Closures](/guide/closures/).
