# Control flow

Blocks are introduced by `:` and marked by four spaces of indentation.
Conditions are `Bool` and nothing else: there is no truthiness, so an
`Int` or a `String` cannot stand in for one.

## if, elif, else

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

There is no ternary operator and no `switch`. What replaces the
ternary for the one case that really wanted it is `else`, the
null-coalescing operator — see [absence](../absence/).

## while

```luce run
func main():
    var remaining = 27
    var steps = 0
    while remaining != 1:
        if remaining % 2 == 0:
            remaining = remaining / 2
        else:
            remaining = 3 * remaining + 1
        steps += 1
    print(f"27 reaches 1 in {steps} steps")
```

```output
27 reaches 1 in 111 steps
```

## for

`for` walks a range of integers, or a collection.

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

The two-name form binds a *position* and then a *payload*: for a list
or a rank-1 array that is the index and the element, and for a map it
is the key and the value. There is no separate `enumerate`.

Do not grow, shrink or free a collection while you are iterating it.
Bounds stay checked on every step, but which elements you visit is
your problem.

## break and continue

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

Both of them, and `return`, free whatever the scopes they leave still
own. There are no single-exit contortions in Luce and no `defer` —
[memory](../ownership/) explains why neither is needed.

## Recursion, and what happens when it runs away

Functions may call themselves. Call depth is a *policy* limit rather
than a native stack accident, so runaway recursion is a trap with a
message and a call stack — never a segmentation fault.

```luce run
func factorial(n: Int) -> Int:
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
