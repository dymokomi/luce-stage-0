# std.term

`std.term` is the terminal. It draws a frame into the alternate screen,
reads typed keyboard, mouse, wheel, and resize events as ordinary values,
and carries the one-cell Unicode border geometry terminal programs compose
panes from.

```
import std.term
```

Use this module when an application wants to own cells and events directly.
Use [`termui`](/library/termui/) when stacks, panels, scrolling, event routing,
cursor placement, and the application loop should be handled by a declarative
package.

## Screen geometry

```
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
`term.read()` also presents pending drawing first, so the ordinary loop can
draw and then wait without displaying a stale frame.

Program text passed to `term.write` is sanitized: control bytes cannot inject
their own terminal escape sequences. Styling, movement, alternate-screen
entry, mouse tracking, and restoration remain operations owned by the host.

## Read events

```
term.read() -> term.Event?
```

The result is the next event as a value, or `none` when input has ended —
nothing failed, there is simply nobody left to ask, so an empty input
stream ends a draw loop cleanly. Every event is copied whole before `read`
returns; a held event never changes under a later read.

`Event` is a union of four cases:

| Case | Payload |
|---|---|
| `key(pressed: term.Key)` | one named key |
| `text(typed: str)` | printable text |
| `mouse(pointer: term.Mouse)` | one mouse action |
| `resize` | the terminal changed size; ask `rows()`/`cols()` again |

`Key` names `enter`, `tab`, `backspace`, `delete`, the arrows `up`, `down`,
`left`, `right`, `home`, `end`, `page_up`, `page_down`, `escape`, and
`ctrl_a` through `ctrl_z`. A key the terminal decoded but this vocabulary
does not know arrives as `Key.unknown` rather than being dropped.

`Mouse` is a value describing one action:

| Field or method | Meaning |
|---|---|
| `kind: term.Pointer` | `press`, `release`, `drag`, `move`, or `wheel` |
| `row`, `column` | zero-based cell coordinates |
| `button` | left `0`, middle `1`, right `2` |
| `modifiers` | bit set: shift `1`, alt `2`, control `4` |
| `wheel` | `+1` up, `-1` down; zero for non-wheel actions |
| `has_shift()`, `has_alt()`, `has_control()` | the modifier bits as predicates |

```text
import std.term

func main():
    var running = true
    while running:
        term.clear()
        term.move(0, 0)
        term.style(114, bold = true)
        term.write(term.top_left + " press q to leave")

        let event = term.read()
        if event == none:
            return
        match event:
            text(typed):
                if typed == "q":
                    running = false
            else:
                continue
```

The host enters raw mode lazily when the screen is first used. It restores the
ordinary screen, input mode, cursor, and mouse tracking when the program
returns, traps, raises an uncaught error, or the host tears down the run.
Calling line-oriented `read_line` temporarily restores canonical input; a
later terminal operation enters the screen again.

## Border geometry

Pure Unicode constants, one ordinary terminal cell each — the only part of
the module that needs no host:

| Constant | Glyph |
|---|---|
| `horizontal` / `vertical` | `─` / `│` |
| `top_left` / `top_right` | `┌` / `┐` |
| `bottom_left` / `bottom_right` | `└` / `┘` |
| `shadow` / `shadow_dark` | `░` / `▒` |

`term.junction(top, right, bottom, left)` chooses the correct line glyph
for the sides continuing through one cell. This keeps border composition in
one table instead of making each application overwrite intersections in a
different order.

## Host behavior

The frame and event operations are host-gated. A runtime that does not
provide a terminal traps `host_unavailable`. Redirected output remains
usable: if standard input is not a terminal, raw mode is not attempted, and
end of input answers `none` rather than spinning.

The low-level event stream has no application state, focus model, layout, or
frame scheduling. Those policies belong in the program or in
[`termui`](/library/termui/), whose runtime owns the complete lifecycle.
