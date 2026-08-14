# std.term

`std.term` is the small terminal facade. It re-exports the hosted terminal
value from `std.os` without making an application reach through the larger
system-facts namespace.

```text
import std.term
```

## Screen output

| Signature | Purpose |
|---|---|
| `term.rows() -> long`, `term.cols() -> long` | current terminal dimensions |
| `term.clear()` | clear the screen |
| `term.move(row: long, column: long)` | move the cursor |
| `term.style(foreground: long, background: long = -1, bold: bool = false)` | set terminal style |
| `term.write(text: string)` | write text |
| `term.flush()` | flush buffered output |

`term.ui` provides the Unicode geometry methods `horizontal`, `vertical`,
`top_left`, `top_right`, `bottom_left`, `bottom_right`, `junction`,
`shadow`, and `shadow_dark`. `junction(top, right, bottom, left)` selects a
glyph from the four sides that continue through a cell.

## Input events

`term.io.read()` returns the next event name or `none` at end of input.
`term.io.text()` returns printable text for a text event. `row()`,
`column()`, `button()`, `modifiers()`, and `value()` expose the numeric data
attached to the event most recently read. Coordinates are zero based;
buttons are left `0`, middle `1`, right `2`; modifier bits are shift `1`, alt
`2`, ctrl `4`; and wheel values are `+1` up or `-1` down.

Keyboard names include `text`, `enter`, `ctrl_s`, `up`, and `escape`.
Interactive terminals can also report `mouse_press`, `mouse_release`,
`mouse_drag`, `mouse_move`, `mouse_wheel`, and `resize`.

```text
import std.term

term.clear()
term.write(term.ui.top_left() + " hello")
term.flush()
let event = term.io.read()
```

The terminal is host-gated. Loom owns raw mode and escape-sequence handling;
these functions are the program-facing drawing and event boundary.
