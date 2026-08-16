# std.term

`std.term` is the low-level terminal facade. It draws a frame into the
alternate screen and reads decoded keyboard, mouse, wheel, and resize events.
It is the shorter spelling of the same terminal value available as
`std.os.term`.

```text
import std.term
```

Use this module when an application wants to own cells and events directly.
Use [`termui`](/library/termui/) when stacks, panels, scrolling, event routing,
cursor placement, and the application loop should be handled by a declarative
package.

## Screen geometry

```text
term.rows() -> i64
term.cols() -> i64
```

The dimensions are terminal cells, not bytes or Unicode scalars. Ask again
after a `resize` event. Rows and columns use zero-based coordinates when
passed to `move`.

## Draw and present

| Signature | Purpose |
|---|---|
| `term.clear()` | reset style, clear the alternate screen, and move home |
| `term.move(row: i64, column: i64)` | place the cursor at a zero-based cell |
| `term.style(foreground: i64, background: i64 = -1, bold: bool = false)` | reset style, then select 256-color foreground/background and bold |
| `term.write(text: str)` | append sanitized text to the pending frame |
| `term.flush()` | present the pending frame and make the cursor visible |

Foreground and background values from 0 through 255 select the terminal's
256-color palette. A negative value uses the terminal default; an out-of-range
positive value is ignored. `move` clamps each coordinate to the supported
terminal escape range.

Drawing calls buffer output. `flush` writes one completed frame. A blocking
`term.io.read()` also presents pending drawing first, so the ordinary loop can
draw and then wait without displaying a stale frame.

Program text passed to `term.write` is sanitized: control bytes cannot inject
their own terminal escape sequences. Styling, movement, alternate-screen
entry, mouse tracking, and restoration remain operations owned by the host.

## Border geometry

`term.ui` provides one-cell Unicode drawing pieces:

| Method | Glyph |
|---|---|
| `horizontal()` / `vertical()` | `─` / `│` |
| `top_left()` / `top_right()` | `┌` / `┐` |
| `bottom_left()` / `bottom_right()` | `└` / `┘` |
| `shadow()` / `shadow_dark()` | `░` / `▒` |

`term.ui.junction(top, right, bottom, left)` chooses the correct line glyph
for the sides continuing through one cell. This keeps border composition in
one table instead of making each application overwrite intersections in a
different order.

## Read events

```text
term.io.read() -> str?
```

The result is the next stable event name, or `none` when input has ended. A
text event carries printable text in `term.io.text()`. Numeric accessors
describe the event most recently returned by `read()`:

| Accessor | Meaning |
|---|---|
| `row()`, `column()` | zero-based mouse coordinates; zero for keyboard events |
| `button()` | left `0`, middle `1`, right `2`; wheel uses `-1` |
| `modifiers()` | bit set: shift `1`, alt `2`, control `4` |
| `value()` | wheel `+1` up, `-1` down; otherwise zero |

Keyboard names include `text`, `enter`, `tab`, `backspace`, `delete`, arrow
keys, Home, End, Page Up, Page Down, Escape, and `ctrl_a` through `ctrl_z`.
Pointer and terminal names are `mouse_press`, `mouse_release`, `mouse_drag`,
`mouse_move`, `mouse_wheel`, and `resize`.

```text
import std.term

func main():
    var running = true
    while running:
        term.clear()
        term.move(0, 0)
        term.style(114, bold = true)
        term.write(term.ui.top_left() + " press q to leave")

        let event = term.io.read()
        if event == none:
            return
        if event == "text" and term.io.text() == "q":
            running = false
```

The host enters raw mode lazily when the screen is first used. It restores the
ordinary screen, input mode, cursor, and mouse tracking when the program
returns, traps, raises an uncaught error, or the host tears down the run.
Calling line-oriented `read_line` temporarily restores canonical input; a
later terminal operation enters the screen again.

## Host behavior

These methods are host-gated. A runtime that does not provide a terminal
traps `host_unavailable`. Redirected output remains usable: if standard input
is not a terminal, raw mode is not attempted, and end of input answers
`none` rather than spinning.

The low-level event stream has no application state, focus model, layout, or
frame scheduling. Those policies belong in the program or in
[`termui`](/library/termui/), whose runtime owns the complete lifecycle.
