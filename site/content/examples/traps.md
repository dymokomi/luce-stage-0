# Traps

A trap is a **bug**: deterministic, with a stable code, and it ends
the program. Debug builds report `file:line:column` and the call
trace, out of the machine code you ship.

```luce trap
func depth_three(values: List(Int)) -> Int:
    return values[10]

func depth_two(values: List(Int)) -> Int:
    return depth_three(values)

func depth_one(values: List(Int)) -> Int:
    return depth_two(values)

func main():
    var values = [1, 2, 3]
    print("before")
    print(str(depth_one(values)))
```

```output
before
loom: trap: index out of bounds [index_bounds]
    at depth_three (main.luc:2:5)
    at depth_two (main.luc:5:5)
    at depth_one (main.luc:8:5)
    at main (main.luc:13:5)
```

## Arithmetic

`Int` is checked. Overflow and division by zero are traps in every
build mode — there is no `--release` that turns them off.

```luce trap
func main():
    let a = 4611686018427387904
    print("doubling")
    print(str(a * 2))
```

```output
doubling
loom: trap: integer overflow [integer_overflow]
    at main (main.luc:4:5)
```

```luce trap
func ratio(a: Int, b: Int) -> Int:
    return a / b

func main():
    print(str(ratio(10, 2)))
    print(str(ratio(10, 0)))
```

```output
5
loom: trap: division by zero [divide_by_zero]
    at ratio (main.luc:2:5)
    at main (main.luc:6:5)
```

## Bounds and keys

```luce trap
func main():
    var xs: List(Int) = []
    print("popping an empty list")
    print(str(xs.pop()))
```

```output
popping an empty list
loom: trap: pop from an empty list [empty_collection]
    at main (main.luc:4:5)
```

```luce trap
func main():
    var m = new Map(String, Int)
    m["a"] = 1
    print(str(m["b"]))
```

```output
loom: trap: key not found in map [key_missing]
    at main (main.luc:4:5)
```

## Text

Slicing a `String` checks UTF-8 boundaries, so a character cannot be
cut in half.

```luce trap
func main():
    let text = "naïve"
    print(f"{len(text)} bytes")
    print(text[0:3])
```

```output
6 bytes
loom: trap: string slice splits a UTF-8 sequence [string_boundary]
    at main (main.luc:4:5)
```

## Your own

`assert(condition)` and `trap(message)` are builtins. `trap` never
returns, so it may stand where a value belongs — which is what makes
`x else trap("…")` the assert-unwrap.

```luce trap
func main():
    let expected = 3
    let actual = 4
    print("checking")
    assert(expected == actual)
```

```output
checking
loom: trap: assertion failed [assertion_failed]
    at main (main.luc:5:5)
```

## Runaway recursion

Call depth is a *policy* limit rather than a native stack accident:
compiled code carries its remaining depth as a hidden argument and
refuses the call that would exhaust it. Runaway recursion is a trap
with a message and a stack, never a segmentation fault. The trace
keeps the innermost frames and counts the rest.

```luce trap
func forever(n: Int) -> Int:
    return forever(n + 1)

func main():
    print(str(forever(0)))
```

```output
loom: trap: call depth exceeded [call_depth_exceeded]
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    at forever (main.luc:2:5)
    ... 116 more frames
```
