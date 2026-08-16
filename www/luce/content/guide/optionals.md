# Optionals

`T?` is a `T` that may not be there, and `none` is the value that is
not. It is the answer whenever "there is nothing here" is the whole
story, with no reason worth carrying.

```luce run
func main():
    print(f"{parse_i64("42") else -1}")
    print(f"{parse_i64("nonsense") else -1}")
    print(f"{parse_f64("2.5") else 0.0}")
```

```output
42
-1
2.5
```

## Narrowing

After a test the name *is* its payload. There is no unwrap operator.

```luce run
func classify(text: str) -> str:
    let n = parse_i64(text)
    if n == none:
        return f"{text} is not a number"
    if n < 0:
        return f"{text} is negative"
    return f"{text} doubles to {n * 2}"

func main():
    print(classify("21"))
    print(classify("-3"))
    print(classify("x"))
```

```output
21 doubles to 42
-3 is negative
x is not a number
```

An early-exit guard narrows everything below it, which is the shape
most real code takes.

```luce run args=17
func main(args: list[str]):
    let raw = args[0]
    let n = parse_i64(raw)
    if n == none:
        print(f"not a number: {raw}")
        return
    print(f"{n} squared is {n * n}")     # n is i64 from here down
```

```output
17 squared is 289
```

## else, chained

`else` associates to the right, so a chain of fallbacks reads left to
right and stops at the first one that is there.

```luce run
func main():
    let first = parse_i64("x") else parse_i64("y") else parse_i64("3") else 0
    print(str(first))

    let n = parse_i64("10")
    print(str(n else 0 > 5))     # else binds tighter than comparison
    print(str((n else 0) + 1))
```

```output
3
true
11
```

## Optionals as parameters and fields

```luce run
struct Setting:
    name: str
    limit: i64?

func describe(setting: Setting) -> str:
    let limit = setting.limit
    if limit == none:
        return f"{setting.name}: unlimited"
    return f"{setting.name}: {limit}"

func main():
    print(describe(Setting(name = "retries", limit = 3)))
    print(describe(Setting(name = "size", limit = none)))
```

```output
retries: 3
size: unlimited
```

Narrowing works on locals and parameters, never on a field or an
element — those could change between the test and the use. Bind the
field to a name and test that, which is what `describe` does above.

## The assert-unwrap

There is no force-unwrap sigil. `x else trap("…")` says the same thing
and is greppable.

```luce trap
func main():
    let config = "port=notanumber"
    let port = parse_i64(config[5:len(config)]) else trap("bad port in config")
    print(str(port))
```

```output
loom: trap: bad port in config [explicit_trap]
    at main (main.luc:3:5)
```
