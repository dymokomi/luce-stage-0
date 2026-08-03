# Loops and ranges

`range(low, high)` counts up, excluding the high end.

```luce run
func main():
    for i in range(0, 5):
        print(str(i))
```

```output
0
1
2
3
4
```

`for x in collection` walks a list, a rank-1 array, or a map's keys.
The two-name form binds a position and then a payload — the index and
the element for a sequence, the key and the value for a map.

```luce run
func main():
    let colours = ["red", "green", "blue"]
    for colour in colours:
        print(colour)
    for index, colour in colours:
        print(f"{index}: {colour}")

    var counts = new Map(String, Int)
    counts["a"] = 1
    counts["b"] = 2
    for key in counts:
        print(f"key {key}")
    for key, value in counts:
        print(f"{key} = {value}")
```

```output
red
green
blue
0: red
1: green
2: blue
key a
key b
a = 1
b = 2
```

`while` takes a `Bool`, and `break` and `continue` do what you expect.
Both of them free whatever the scopes they leave still own.

```luce run
func main():
    var n = 1
    var seen = 0
    while true:
        n *= 3
        if n % 2 == 0:
            continue
        seen += 1
        if seen == 5:
            break
    print(f"stopped at {n} after {seen} odd values")
```

```output
stopped at 243 after 5 odd values
```

Nested loops are ordinary loops. There are no labelled breaks; a flag
or an early `return` covers it.

```luce run
func find(grid: Array(Int, _, _), wanted: Int) -> Int:
    for row in range(0, grid.dim(0)):
        for column in range(0, grid.dim(1)):
            if grid[row, column] == wanted:
                return row * 100 + column
    return -1

func main():
    var grid = new Array(Int, 3, 3)
    for row in range(0, 3):
        for column in range(0, 3):
            grid[row, column] = row * 3 + column
    print(str(find(grid, 5)))
    print(str(find(grid, 99)))
```

```output
102
-1
```
