# Control flow

Luce uses indentation for blocks. A block follows `:` and is indented by
four spaces. Conditions are `bool`; numbers and strings are not implicitly
truthy.

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
optional operator described in [Absence](../absence/).

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

Do not change the size of, or free, the collection being iterated. See
[Lists, maps and arrays](../collections/) for the collection operations.

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

Leaving a scope also releases the objects owned by that scope. A function
can return from inside a loop; there is no `defer` construct.

## Recursion

Functions can call themselves. A recursion limit turns runaway recursion
into a reported trap instead of an uncontrolled native-stack failure.

```luce run
func factorial(n: long) -> long:
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

Next: [Functions and structs](../functions/).
