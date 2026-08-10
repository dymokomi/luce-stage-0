# std.term

The short terminal module. It exposes the same hosted terminal facade as
`std.os` without requiring a program to reach through the system-facts
namespace.

```luce
import std.term

term.clear()
term.write(term.ui.top_left() + " hello")
term.flush()
let event = term.io.read()
```

`term.io.read()` is one event stream. Keyboard events use names such as
`text`, `enter`, `ctrl_s`, `up` and `escape`. Interactive terminals also
answer `mouse_press`, `mouse_release`, `mouse_drag`, `mouse_move`,
`mouse_wheel` and `resize`. After a read, `term.io.text()` is the printable
text, while `row()`, `column()`, `button()`, `modifiers()` and `value()` are
the zero-based mouse/resize data for that event. Buttons are left `0`, middle
`1` and right `2`; keyboard, resize and wheel events use `-1`. Modifier bits
are shift `1`, alt `2` and ctrl `4`; wheel value is `+1` up or `-1` down.

`term.ui` is pure Unicode geometry. Its junction method receives the four
lines that continue through a cell, so a pane compositor can select `┌`, `┬`,
`┼` or `┘` rather than drawing every intersection as `+`.
