# termui

`termui` is Luce's terminal-UI package. It turns application state into a
deterministic cell surface and keeps terminal protocol details at the
`std.term` boundary. The application keeps its state and event policy;
termui handles the mechanics every terminal program otherwise repeats:
frame preparation, clipping, constraint layout, styled text, junction-aware
frames, rendering composition, and presenting only the cells that changed.

The package is a layered kernel, not a framework that takes over `main`.
Each module hides real complexity behind a small interface, is testable
in memory with no terminal, and is used by the example editor. It ships as
`packages/termui-0.2.0/`:

```text
packages/termui-0.2.0/
├── termui.luc     # Color, Style, Rect            — the value vocabulary
├── surface.luc    # Cell, Painted, Surface        — the cell grid + diff
├── text.luc       # Span, Line                    — styled text runs
├── layout.luc     # Length, Row, Column, Handle   — the constraint solver
├── frame.luc      # Frame                         — junction-aware boxes
├── input.luc      # Key, Pointer, Mouse, Event, Events
├── view.luc       # View, Text, Fill              — the read-only view interface
├── rows.luc       # Rows, RowsView                — selection list
├── viewport.luc   # Viewport, ViewportView        — scrollable window
└── renderer.luc   # Renderer                      — the lifecycle coordinator
```

Each module is tested per boundary in memory, and the editor drives the
whole package through a differential transcript that runs on both engines.

## The design discipline

There are no generics yet, so termui does not build OpenTUI's retained
tree of mutable widgets reconciled from a VNode description — that would
be a large abstraction surface with no consumer that needs it. termui
commits to the alternative and applies it uniformly:

> **The app holds the state; a View is a projection of the current state,
> drawn once.** A widget is a *pair*: a small app-held **state struct**
> with the logic (movement, selection, scroll offset) and a **View** built
> from that state each frame. The View draws; it does not reconcile a
> persistent tree.

`Rows`/`RowsView` and `Viewport`/`ViewportView` are that pattern. State
lives in one place, and the render path is a pure function of it, so there
is no retained list or mutable receiver hidden inside a long-lived
interface value.

## The smallest useful program

The application creates one renderer, begins a frame, paints into its
surface, presents the changed cells, places the cursor, and reads the next
event. It decides what the events mean.

```text
import termui
import input
import renderer as renderer
import text
import frame as frame

func main():
    var ui = renderer.Renderer.open()
    var quit = false
    while not quit:
        let area = ui.begin()
        let interior = frame.Frame(title = " hello ").draw(ui.surface, area)
        text.plain("Luce", termui.Style()).draw(ui.surface, interior, 0)
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

`Renderer.open()` reads the current terminal size. `Renderer.of(rows,
columns)` and `begin_at(rows, columns)` are the host-free forms used by
tests and by programs that already have a size. `begin()` resizes when
necessary, clears the next frame, and returns the available `Rect`.

`present()` diffs the next frame against the last presented frame. It
returns a `Painted` value (`cells`, `runs`, `moves`) and does not flush:
put the cursor where the application wants it, then call `flush()`. That
order makes cursor placement part of the same terminal commit and is easy
to assert against a fake host.

## The value vocabulary — `termui.luc`

`Color` names the sixteen terminal colours as an enum; `Style`
(`foreground`, `background`, `bold`) is a value that copies and allocates
nothing — there is no global theme. `Rect` is total arithmetic:
`is_empty`, `split_top`/`split_bottom`/`split_left`/`split_right` clamp a
requested size to the available dimension and return the taken rectangle
plus the remainder, and `inset` shrinks and stops at an empty rectangle. A
small terminal is therefore a normal resize, never a trap.

## Surfaces, cells, and the diff — `surface.luc`

`Surface` holds two grids: `back` is the frame being built, `front` is what
termui last told the terminal to show. `clear`, `put`, `write`, and `fill`
write only the back grid, and `write` treats its row and column as offsets
inside a supplied rectangle, clipped to it and to the screen. `Cell` is a
text unit and a `Style`.

`present()` writes only where the two grids differ, coalescing a horizontal
run of changed cells that share a style into one `term.write` preceded by
one `term.move`. It returns a `Painted` report (`cells`, `runs`, `moves`)
so a test can hold the diff to its promise without a terminal. The first
frame after a resize is unknowable and is painted in full; an unchanged
frame paints zero cells. The type is called Surface because views draw
*into* it — it is the drawable, never the terminal.

## Styled text — `text.luc`

A `Span` is the smallest styled thing (a `text` and a `Style`); a `Line` is
a row of spans drawn left to right. This is what a syntax highlighter
produces — one `Line` per source row, its keywords, strings, and comments
each their own `Span` — and what a label or status bar is. Drawing measures
**display width** (`std.strings.width`), not byte length, so a multi-byte
character takes the one column it occupies and the surface clips an
over-long line rather than trapping. `Line.width()` measures; `text.plain`
spells the one-span common case short. A `Line` is built for a frame and
drawn once; it does not retain the surface.

## Layout — `layout.luc`

The constraint solver divides one axis so the sum never exceeds what is
available and no region is ever negative. Each region states what it wants
as a `Length`:

```text
union Length:
    cells(count: i64)                          # exactly count cells
    grow(weight: i64)                          # share the leftover by weight
    between(low: i64, high: i64, ratio: i64) # ratio% of the axis, clamped [low, high]
```

`between` is what a sidebar or output pane wants: a quarter of the axis,
but never below a minimum nor above a maximum, giving way before a `grow`
sibling starves. Pure ratio and pure min/max are special cases of it, so
the surface stays three members.

`resolve(total, gap, items) -> list[i64]` solves one axis and is total: a
preferred pass fixes `cells` and clamps `between`, then any surplus is
shared among `grow` items and any deficit is taken from flexible space
first — so an oversubscribed axis (a small terminal) shrinks in a
min-respecting order rather than going negative. `Row.solve(area, gap,
items)` walks columns left to right and `Column.solve(...)` walks rows top
to bottom, each answering a `list[Rect]`. A hidden pane is a zero-length
item that yields an empty `Rect`, which draws nothing — never a flag and
never a branch, because every `Rect` operation is total.

`Handle` is the small hit-testable region a caller uses for a draggable
splitter: `hit(row, column)` tests a point and `track(row, column)` maps a
drag to a new size.

## Junction-aware frames — `frame.luc`

A `Frame` draws any subset of its four edges (`top`, `right`, `bottom`,
`left`, each a bool, all true by default) as box-drawing strokes, with an
optional `title` on the top edge and a `Style`. The one idea that makes it
composable: **a stroke laid over a stroke merges**. Where a frame's edge
crosses a rule already on the surface — its own corner, or a neighbouring
pane's border — the two glyphs combine into the correct `┼`/`├`/`┴`/…
through `std.term`'s `term.ui.junction`, rather than one overwriting the
other. So a caller tiles framed panes and never picks a junction glyph; the
geometry it drew decides. `Frame.draw(into, area) -> Rect` draws the
requested edges and the clipped title and answers the **interior**
rectangle. A three-sided pane that shares an edge with its neighbour is
`Frame(bottom = false, ...)`, and the shared corner becomes a `┬`
automatically.

## Input — `input.luc`

`Events.next()` snapshots one host event into the closed `Event` union:

```text
closed
resize
key(pressed: Key)
text(typed: str)
mouse(pointer: Mouse)
```

`Key` is an enum with one member per host name (the navigation names and
the `ctrl_*` set), plus `unknown` for a name a later host learns before the
enum does; the stream's `last_name` preserves the raw spelling for a
program that wants to handle a newer event. `Mouse`/`Pointer` copy the
coordinates, button, modifiers, and wheel value out of the host at event
time, so an event held across a later read still says what it said. termui
ships no keymap: mapping a key to an application command is the
application's business.

## Views — `view.luc`

`View` is a small, read-only interface:

```text
interface View:
    func measure(area: termui.Rect) -> (i64, i64)
    func draw(into: surface.Surface, area: termui.Rect)
```

Under Luce's current value-struct interface rule a view may change the surface
handed to it but cannot hide a mutable value receiver. The app keeps the model
and hands a fresh projection to `draw`. Two plain
concretes ship: `Text` (a block of `text.Line`s, so one line may carry many
styles) and `Fill` (a rectangle of one repeated cell — a selection bar, a
cleared pane). There is no `Panel` or `Split`: their jobs are `frame.Frame`
and `layout` respectively.

## The two widgets — `rows.luc` and `viewport.luc`

Both follow the state/view pattern exactly. `Rows` is the app-owned
selection state (`count`, `top`, `selected`, with `adjust`, `move_by`,
`choose`) — it holds no container, only counters — and `RowsView` is the
read-only projection that draws a `func(i64) -> str` provider,
highlighting the selected row. The provider is a bound method, so the widget
owns its receiver snapshot and retains every reference that snapshot carries. `Rows`
answers a small `RowsEvent` union (`moved`/`chosen`) that the app matches
to decide what "chosen" means.

`Viewport` is the same pattern without a selection: an app-owned scroll
position over `total` lines (`scroll_by`, `to`), and `ViewportView` paints
the visible window `[top, top + rows)` from a provider. This is the
output/log pane an editor scrolls because a person said "down", where
`Rows` scrolls to follow a selection.

## The lifecycle owner — `renderer.luc`

`Renderer` owns a `Surface` and an `Events` and centralizes the
resize → begin → present → cursor → flush choreography:
`open`/`of`/`begin`/`begin_at`/`present`/`cursor`/`flush`/`next`.
`present` returns `Painted` and does not flush, so the app places the
cursor inside the same terminal commit. Applications still own their event
loop and state; this type only removes the repeated terminal choreography.

## State and lifecycle

- The application holds its model, providers, and event loop.
- `Renderer` holds its `Surface` and `Events` and centralizes resize,
  presentation, cursor placement, and flush sequencing.
- Views draw into the surface for one call; they do not retain it.
- A provider reads the application's state through a bound method without
  retaining it: mutate the provider's own container in place, or keep the
  state it reads alive.
- Do not put a mutable application model behind `View` merely to get
  dynamic dispatch. Keep that model in the app and make the view a
  projection of the current state.

Terminal lifecycle sits in one place, layout and painting have explicit
inputs, and the caller can see where mutation and failure occur.

## The editor

The example editor (`examples/editor/`) is the end-to-end consumer: a
modular Luce program whose panes lay out through `layout`, whose borders
are `frame.Frame`s that share edges, whose file list and output pane are
`RowsView` and `ViewportView`, and whose syntax highlighting produces
`text.Line`s. Its differential specification (`specs/editor_spec.zig`)
drives both engines and compares the complete terminal transcript, so a
visual or lifecycle regression cannot hide behind a unit test that only
checks a helper.

## Deliberately deferred

A mutable retained widget tree, focus traversal beyond what the editor
needs, scrollbars, full mouse hit-testing policy, grapheme-aware terminal
width (the width rule is `std.strings`' code-point count, not terminal
cells or East Asian widths), and a global theme. Each needs its own
ownership and testing decision before it belongs in the core package.
