# Arrays and grids

An `Array` has a fixed shape, decided at `new` from runtime values,
and its elements start at the type's zero — 0, 0.0, `false`, `""`, a
zeroed struct, or the null object.

```luce run
func main():
    var row = new Array(Int, 5)
    for i in range(0, 5):
        row[i] = i * i
    print(f"{len(row)} elements, last {row[4]}")

    var flags = new Array(Bool, 3)
    print(f"zero value is {flags[0]}")
```

```output
5 elements, last 16
zero value is false
```

Up to four dimensions. In a type annotation the shape is spelled with
`_`, and `dim(axis)` gives any of the sizes.

```luce run
func sum(grid: Array(Int, _, _)) -> Int:
    var total = 0
    for row in range(0, grid.dim(0)):
        for column in range(0, grid.dim(1)):
            total += grid[row, column]
    return total

func main():
    var grid = new Array(Int, 4, 4)
    for row in range(0, 4):
        for column in range(0, 4):
            grid[row, column] = row * column
    print(f"{grid.dim(0)}x{grid.dim(1)}, corner {grid[3, 3]}, total {sum(grid)}")
```

```output
4x4, corner 9, total 36
```

A rank-1 array shares `sort`, `reverse`, `find`, `contains` and
`fill`.

```luce run
func main():
    var values = new Array(Float, 6)
    values.fill(1.5)
    values[0] = 9.5
    values[5] = 0.5
    values.sort()
    print(f"{values[0]} .. {values[5]}, contains 1.5: {values.contains(1.5)}")
```

```output
0.5 .. 9.5, contains 1.5: true
```

`fill` on an array of *objects* is a compile error outright: one value
cannot own every slot. Store into each slot instead.

## Numeric vectors

`Array(Float, _)` is the numeric vector type the standard library's
whole-array operations work over. Reductions accumulate left to right,
so they are bit-reproducible.

```luce run
import std.math
import std.strings

func main():
    var xs = new Array(Float, 5)
    for i in range(0, 5):
        xs[i] = Float(i) + 1.0

    print(f"sum {math.sum(xs)}")
    print(f"mean {math.mean(xs) else 0.0}")
    print(f"min {math.vmin(xs) else 0.0}, max {math.vmax(xs) else 0.0}")
    print(strings.format_float(math.stddev(xs) else 0.0, 4))

    var ys = new Array(Float, 5)
    math.fill(ys, 2.0)
    print(f"dot {math.dot(xs, ys)}")
    math.axpy(ys, 3.0, xs)          # ys[i] += 3.0 * xs[i]
    print(f"ys[4] {ys[4]}")
```

```output
sum 15
mean 3
min 1, max 5
1.4142
dot 30
ys[4] 17
```

The five reductions over an array — `mean`, `vmin`, `vmax`,
`variance`, `stddev` — answer `Float?`, because an empty array has no
mean and that is absence rather than failure.
