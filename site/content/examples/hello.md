# Hello and arguments

The smallest useful program: `main`, `print`, and a string.

```luce run
func main():
    print("hello, loom")
```

```output
hello, loom
```

The command line reaches a program as `main`'s parameter. Declare it
and it is an ordinary `list(string)`; leave it out and the program
says nothing about arguments it never reads.

```luce run args=fig pear plum
func main(args: list(string)):
    if len(args) == 0:
        print("usage: greet NAME [NAME ...]")
        return
    var index = 0
    for name in args:
        index = index + 1
        print(f"{index}. hello, {name}")
```

```output
1. hello, fig
2. hello, pear
3. hello, plum
```

Arguments arrive as `string`s. Turning one into a number is
`parse_int`, which answers an `long?` because the text may not be a
number at all — `else` supplies the fallback.

```luce run args=4
func main(args: list(string)):
    let times = parse_int(args[0]) else 1
    for i in range(0, times):
        print(f"line {i}")
```

```output
line 0
line 1
line 2
line 3
```
