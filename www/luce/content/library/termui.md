# termui

`termui` is a small terminal-UI package. It turns application state into a
deterministic grid of styled cells and keeps terminal protocol details at the
`std.term` boundary. Your program owns its state and event policy; `termui`
owns frame preparation, clipping, layout rectangles, rendering composition and
presenting changed cells.

This is a package, not a second standard-library namespace. In a checkout its
source lives under `packages/termui-0.1.0/`. The package manifest and import
layout are ordinary Luce files, so you can study or copy the pattern in the
[organization guide](/guide/organization/).

## The public pieces

| Module | What it provides |
| --- | --- |
| `termui` | `Color`, `Style`, and total `Rect` layout arithmetic |
| `screen` | `Cell`, `Screen`, and the `Painted` presentation summary |
| `events` | `Key`, `Mouse`, and the closed `Event` input union |
| `border` | a clipped border and its interior rectangle |
| `rows` | a selection model and a read-only `RowsView` |
| `view` | the `View` interface, `Text`, `Panel`, and `Split` |
| `renderer` | terminal size, frame lifecycle, events, cursor and flush |

The package is intentionally small. It does not own your main loop, model,
keymap, focus policy, or theme.

## The frame lifecycle

Create one `Renderer`, begin a frame, draw views into its surface, present the
changed cells, place the cursor, flush, and then read the next event. The
application decides when to stop and what an event means.

```text
var ui = renderer.Renderer.open()
var quit = false
while not quit:
    let area = ui.begin()
    let title: views.View = views.Panel(
        title = "hello",
        child = views.Text(content = "Luce"),
    )
    title.draw(ui.surface, area)
    ui.present()
    ui.cursor(0, 0)
    ui.flush()
    match ui.next():
        closed:
            quit = true
        key(pressed):
            if pressed == events.Key.ctrl_q:
                quit = true
        else:
            continue
```

`Renderer.open()` reads the terminal size. `Renderer.of(rows, columns)` and
`begin_at(rows, columns)` are host-free constructors for tests and fixed-size
programs. `begin()` resizes when needed, clears the next frame, and returns
the available `Rect`.

`present()` compares the next (`back`) grid with the last presented (`front`)
grid and returns `Painted(cells, runs, moves)`. It does not flush. Keeping
cursor placement and flush separate makes the commit order explicit and lets
tests assert the output without a terminal.

## Values, surfaces, and clipping

`Style` and `Rect` are plain values. `Rect.split_top`, `split_bottom`,
`split_left`, `split_right`, and `inset` clamp their inputs. A small terminal
therefore produces an empty rectangle rather than a trap.

`Screen` is an in-memory surface. `clear`, `put`, `write`, and `fill` change
only the back grid. `write` treats its row and column as offsets inside the
provided rectangle and clips both to that rectangle and to the screen. `Cell`
stores a text unit and a `Style`; `present()` groups adjacent changed cells
with the same style into runs.

The current width rule follows `std.strings`: text is walked as UTF-8
characters. Grapheme clusters and the full East Asian width table are not yet
implemented, so an editor that needs exact cursor columns should keep editing
offsets separate from display drawing.

## Views and interfaces

`View` is deliberately read-only and small:

```text
interface View:
    func measure(area: termui.Rect) -> (long, long)
    func draw(into: screen.Screen, area: termui.Rect)
```

A view receives the surface for one draw call; it does not retain the surface,
terminal, event stream, or application model. `Text` draws newline-separated
lines. `Panel` draws a clipped border and delegates to an optional child.
`Split` composes two views horizontally or vertically with a percentage and a
gap. These values can be mixed in `list(View)`, `map(string, View)`, arrays,
and fields because interfaces are nominal and heterogeneous.

`Rows` is different: it is a stateful selection model that the application
updates in response to events. `RowsView` is a read-only snapshot for drawing.
Build the adapter from the current `render`, `count`, `top`, and `selected`
values; it never moves the selection while painting.

See the [interface guide](/guide/interfaces/) and the exact [interface
rules](/reference/types/#interface) for conformance and ownership.

## Input

`Events.next()` snapshots one host event into this closed union:

```text
closed
resize
key(pressed: Key)
text(typed: string)
mouse(pointer: Mouse)
```

Mouse coordinates, buttons, modifiers, wheel direction, and text are copied
into the event value. An unknown key is `Key.unknown`; `Events.last_name`
keeps its raw name for applications that need to support a newer host event.
The package does not impose a keymap. Mapping keys to commands belongs to the
application.

## Ownership and boundaries

- The application owns its model, providers, and event loop.
- `Renderer` owns its `Screen` and `Events` fields.
- Views borrow the surface for one draw call and do not retain it.
- A provider such as `Rows.render` borrows the application's owner. Keep that
  owner alive while the provider is stored, or make an explicit `copy`.
- Do not hide a mutable application model behind `View` just to obtain dynamic
  dispatch; project the current state into value-only views.

This shape keeps terminal lifecycle in one owner and makes layout and drawing
inputs visible. It follows the same information-hiding goal as the language's
interfaces: the abstraction removes repeated mechanics without taking over
decisions that belong to the application.

## What is intentionally not here

The current package does not provide a mutable retained widget tree, focus
traversal, scrollbars, mouse hit-testing policy, grapheme-aware width, or a
global theme. Each would need its own ownership and testing decision. The
package tests cover layout totality, clipping and diffing, input snapshots,
borders, rows, interface composition, and renderer lifecycle; the editor is
the end-to-end consumer.
