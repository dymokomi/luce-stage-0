# Enums

An enum gives names to a finite set of values. The names are qualified by
the enum type (`Method.stored`), so unrelated enums cannot be mixed by
accident. `match` can then require every member to be handled.

```luce run
enum Method:
    stored
    deflated

func main():
    let m = Method.deflated
    print(string(m))
```

```output
deflated
```

## Numeric representation

Members have integer values. With no explicit value they start at zero and
increase; an explicit value sets the next member's value.

```luce run
enum Method:
    stored = 0
    shrunk = 1
    deflated = 8

func main():
    print(f"{Method.stored} is {int(Method.stored)}")
    print(f"{Method.deflated} is {int(Method.deflated)}")
```

```output
stored is 0
deflated is 8
```

`string(member)` returns the name and `int(member)` returns its number.
Neither conversion is implicit. Members are constants and can be used in
defaults and other constant expressions.

## Choosing storage width

The default backing width is `int`. Put a storage type in parentheses when
the enum must fit a narrow array:

```luce run
enum Cell(byte):
    empty
    wall
    door

func main():
    var room = new array(Cell, 3, 3)
    room[1, 1] = Cell.wall
    room[0, 2] = Cell.door
    var walls = 0
    for row in range(0, 3):
        for column in range(0, 3):
            if room[row, column] == Cell.wall:
                walls = walls + 1
    print(f"{walls} wall, and room[0,2] is {room[0, 2]}")
```

```output
1 wall, and room[0,2] is door
```

An explicit member value must fit the chosen width, and values must be
unique:

```luce fail
enum Method(byte):
    stored = 0
    deflated = 300

func main():
    return
```

```output
luce: compile failed
main.luc:3:5: deflated = 300 does not fit byte, which holds 0 to 255; write the enum's width wider — enum Method(long): [luce.sema.enum]
        deflated = 300
        ^~~~~~~~~~~~~~
```

## Matching members

An enum `match` uses the member names as arms. Without `else`, every member
must appear:

```luce run
enum Colour:
    red
    green
    blue

func describe(c: Colour) -> string:
    match c:
        red:
            return "stop"
        green:
            return "go"
        blue:
            return "neither"

func main():
    print(describe(Colour.red))
    print(describe(Colour.blue))
```

```output
stop
neither
```

```luce fail
enum Colour:
    red
    green
    blue

func main():
    let c = Colour.red
    match c:
        red:
            print("stop")
        green:
            print("go")
```

```output
luce: compile failed
main.luc:8:5: this match has no arm for member blue of Colour; write one, or an else for everything the arms above do not name [luce.sema.match]
        match c:
        ^~~~~~~
```

Use `else` for the remaining members. A number from outside the program is
converted with `Enum(value)`, which answers an optional because it may not
name a member:

```luce run
enum Method:
    stored = 0
    deflated = 8

func read(raw: long) -> string:
    let m = Method(raw)
    if m == none:
        return f"method {raw} is one I cannot read"
    return f"method {raw} is {m}"

func main():
    print(read(0))
    print(read(8))
    print(read(14))
```

```output
method 0 is stored
method 8 is deflated
method 14 is one I cannot read
```

Enums support equality, not ordering. Convert to an integer when numeric
ordering is the actual requirement. Enums can be map keys, and iteration
keeps the enum key type:

```luce run
enum Key:
    left
    right
    quit

enum Intent:
    move_left
    move_right
    stop
    nothing

const bindings = {Key.left: Intent.move_left, Key.quit: Intent.stop}

func intent(pressed: Key) -> Intent:
    return bindings.get(pressed) else Intent.nothing

func main():
    print(string(intent(Key.left)))
    print(string(intent(Key.right)))
    for k in bindings:
        print(f"{k} -> {bindings[k]}")
```

```output
move_left
nothing
left -> move_left
quit -> stop
```

## Methods

Like structs, enums may define methods with implied `self`:

```luce run
enum Light:
    red
    green

    func go() -> bool:
        return self == Light.green

    func flip():
        match self:
            red:
                self = Light.green
            green:
                self = Light.red

func main():
    var light = Light.red
    print(string(light.go()))
    light.flip()
    print(f"{light}, and go is {light.go()}")
```

```output
false
green, and go is true
```

An enum is not a bit set and cannot carry payload fields. Use integer bit
operators for flags and [a union](../unions/) when each alternative needs
data. Next: [Lists, maps and arrays](../collections/).
