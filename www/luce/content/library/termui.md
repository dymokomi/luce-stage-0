# termui

`termui` is a small terminal-UI package. It turns application state into a
deterministic grid of styled cells and keeps terminal protocol details at the
`std.term` boundary. Your program keeps its state and event policy; `termui`
handles frame preparation, clipping, constraint layout, styled text, box drawing,
rendering composition and presenting changed cells.

This is a package, not a second standard-library namespace. In a checkout its
source lives under `packages/termui-0.2.0/`. The package manifest and import
layout are ordinary Luce files, so you can study or copy the pattern in the
[Packages and Projects](/guide/packages/).

## The public pieces

| Module | What it provides |
| --- | --- |
| `termui` | `Color`, `Style`, and total `Rect` layout arithmetic |
| `surface` | `Cell`, `Surface`, and the `Painted` presentation summary |
| `text` | `Span` and `Line`: styled runs measured by display width |
| `layout` | a constraint solver — `Length` (`cells`/`grow`/`between`), `Row`/`Column`, and a draggable `Handle` |
| `frame` | box drawing whose edges merge into the correct junctions |
| `input` | `Key`, `Mouse`, and the closed `Event` input union |
| `view` | the `View` interface, `Text`, and `Fill` |
| `rows` | a selection model and a read-only `RowsView` |
| `viewport` | a scroll model and a read-only `ViewportView` |
| `renderer` | terminal size, frame lifecycle, events, cursor and flush |

The package is intentionally small. It does not own your main loop, model,
keymap, focus policy, or theme.

## The frame lifecycle

Create one `Renderer`, begin a frame, draw into its surface, present the
changed cells, place the cursor, flush, and then read the next event. The
application decides when to stop and what an event means.

```text
import termui
import termui.input as input
import termui.frame as frame
import termui.text as text
import termui.renderer as renderer

func main():
    var ui = renderer.Renderer.open()
    var quit = false
    while not quit:
        let area = ui.begin()
        let inside = frame.Frame(title = "hello").draw(ui.surface, area)
        text.plain("Luce", termui.Style()).draw(ui.surface, inside, 0)
        ui.present()
        ui.cursor(0, 0)
        ui.flush()
        match ui.next():
            closed:
                quit = true
            key(pressed):
                if pressed == input.Key.ctrl_q:
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

`Surface` is an in-memory grid. `clear`, `put`, `write`, and `fill` change
only the back grid. `write` treats its row and column as offsets inside the
provided rectangle and clips both to that rectangle and to the surface. `Cell`
stores a text unit and a `Style`; `present()` groups adjacent changed cells
with the same style into runs, so an unchanged frame writes nothing and a
one-character edit writes one run.

The width rule follows `std.strings`: text is walked as UTF-8 characters.
Grapheme clusters and the full East Asian width table are not yet implemented,
so an editor that needs exact cursor columns should keep editing offsets
separate from display drawing.

## Styled text

`text.Span` is a run of characters with a `Style`; `text.Line` is a row of
spans, drawn once and measured by **display width** rather than byte length.
A syntax highlighter produces one `Line` per source row — its keywords,
strings and comments each their own `Span` — and a label or status bar is one
`Line`. `text.plain(str, Style)` builds the common single-span line.

```text
var spans = new list[text.Span]
spans.append(text.Span(text = "let ", style = keyword))
spans.append(text.Span(text = "x", style = plain))
let line = text.Line(spans = spans)
line.draw(surface, area, row)
```

## Layout

`layout` turns a list of constraints into rectangles, so a resize is ordinary
arithmetic rather than a special case. Each region is a `Length`:

| `Length` | Meaning |
| --- | --- |
| `cells(count)` | exactly `count` cells |
| `grow(weight)` | share the leftover space in proportion to `weight` |
| `between(low, high, ratio)` | `ratio` percent of the axis, clamped to `[low, high]` |

`Row.solve(area, gap, items)` divides columns left to right; `Column.solve`
divides rows top to bottom. The solver is total: the sizes never exceed the
axis and never go negative, and an oversubscribed axis shrinks the flexible
regions toward their floors in order. A hidden region is a zero-length item,
which yields an empty rectangle and draws nothing.

```text
var columns = new list[layout.Length]
columns.append(layout.Length.between(low = 18, high = 24, ratio = 25))
columns.append(layout.Length.grow(weight = 1))
let panes = layout.Row.solve(area, 0, columns)
```

## Frames that share their edges

`frame.Frame` draws any subset of its four edges as box-drawing strokes. Where
a frame's edge crosses a rule already on the surface — its own corner, or a
neighbouring pane's border — the two glyphs **merge** into the correct
`┼`/`├`/`┴`/… instead of one overwriting the other. So an application tiles
framed panes and never chooses a junction glyph: the geometry it drew decides.
`draw` returns the interior rectangle.

```text
let inside = frame.Frame(title = "files", bottom = false).draw(surface, area)
```

## Resizable dividers

`layout.Handle` is the geometry of a draggable boundary between two
panes — the rule an application lets a person drag with the mouse to
resize. It carries an `axis` (a vertical rule you drag left and right is
a width; a horizontal rule you drag up and down is a height), the `line`
the rule sits on, and the span it covers. Two methods are the whole of
it: `hit(row, column)` answers whether a mouse cell is on the divider,
and `track(row, column)` answers the position a drag to that cell
implies.

```text
let divider = layout.Handle(
    axis = layout.Axis.horizontal,
    line = panes.split_column(),
    from = 0,
    to = panes.status.row,
)
if divider.hit(mouse.row, mouse.column):
    files_width = divider.track(mouse.row, mouse.column)
```

The sizes, and the policy that clamps them so a pane cannot starve its
neighbour, stay with the application: it holds the width and height as
state, a press begins a drag, a drag updates the size, and the next
frame lays out and draws with it. Because the frame rules re-form their
junctions wherever they land, a resize needs no drawing changes at all —
only new sizes flowing through the same layout, frame and present path.

## Views and interfaces

`View` is deliberately read-only and small:

```text
interface View:
    func measure(area: termui.Rect) -> (i64, i64)
    func draw(into: surface.Surface, area: termui.Rect)
```

A view receives the surface for one draw call; it does not retain the surface,
terminal, event stream, or application model. `Text` draws a block of styled
`Line`s; `Fill` paints a rectangle of one repeated cell. These values can be
mixed in `list[View]`, `map[str, View]`, arrays, and fields because
interfaces are nominal and heterogeneous.

`Rows` and `Viewport` follow one pattern: the **state** value lives with the
application, which moves it in response to events, and a read-only **view**
(`RowsView`, `ViewportView`) is built from the current state each frame to
paint. `Rows` tracks a selection and a window; `Viewport` tracks a scroll
position. Neither stores the application's data — a provider function answers
what each row says — so the application keeps its list and the widget reads it.

See the [interface guide](/guide/interfaces/) and the exact [interface
rules](/guide/reference/types/#interface) for conformance and lifetime rules.

## Input

`Events.next()` snapshots one host event into this closed union:

```text
closed
resize
key(pressed: Key)
text(typed: str)
mouse(pointer: Mouse)
```

Mouse coordinates, buttons, modifiers, wheel direction, and text are copied
into the event value. An unknown key is `Key.unknown`; `Events.last_name`
keeps its raw name for applications that need to support a newer host event.
The package does not impose a keymap. Mapping keys to commands belongs to the
application.

## Lifetime boundaries

- The application keeps its model, providers, and event loop alive.
- A `Renderer` keeps its `Surface` and `Events` fields.
- A view receives the surface only for its `draw` call and must not store it.
- A provider such as a `RowsView.render` bound function owns a snapshot of its
  value receiver and retains any reference fields in that snapshot. It may be
  stored independently of the concrete provider binding.
- Do not hide a mutable application model behind `View` just to obtain dynamic
  dispatch; project the current state into value-only views.

This shape keeps terminal lifecycle in one owner and makes layout and drawing
inputs visible. It follows the same information-hiding goal as the language's
interfaces: the abstraction removes repeated mechanics without taking over
decisions that belong to the application.

## What is intentionally not here

The current package does not provide a mutable retained widget tree, focus
traversal, scrollbars, mouse hit-testing policy, grapheme-aware width, or a
global theme. Each would need its own lifetime and testing decision. The
package tests cover layout totality, the constraint solver, styled-text
clipping, frame junctions, cell diffing, input snapshots, selection and scroll
windowing, and renderer lifecycle; the editor is the end-to-end consumer.
