# Hello and arguments

The smallest useful program: `main`, `print`, and a string.

```luce run
func main():
    print("hello, loom")
```

```output
hello, loom
```

`arg_count()` and `arg(i)` reach the command line. `arg(i)` outside
the range traps, and the count is right there to check against.

```luce run args=fig pear plum
func main():
    if arg_count() == 0:
        print("usage: greet NAME [NAME ...]")
        return
    for index in range(0, arg_count()):
        print(f"{index + 1}. hello, {arg(index)}")
```

```output
1. hello, fig
2. hello, pear
3. hello, plum
```

Arguments arrive as `String`s. Turning one into a number is
`parse_int`, which answers an `Int?` because the text may not be a
number at all — `else` supplies the fallback.

```luce run args=4
func main():
    let times = parse_int(arg(0)) else 1
    for i in range(0, times):
        print(f"line {i}")
```

```output
line 0
line 1
line 2
line 3
```
