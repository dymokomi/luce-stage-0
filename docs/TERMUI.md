# termui

> **Superseded (2026-08-14).**  This describes termui **v0.1**, whose
> module set (`screen`, `events`, `border`, and the `Panel`/`Split`
> views) was retired.  The shipping package is **v0.2**
> (`packages/termui-0.2.0/`): the proven core kept its shape but `Screen`
> became `Surface` and `events` became `input`, and the shallow view
> layer was replaced by three deep modules v0.1 lacked — `layout` (a
> constraint solver), `text` (styled spans), and `frame` (junction-aware
> boxes whose strokes merge) — plus a `viewport` widget.  The reasoning
> and the module-by-module design are in
> [TERMUI_EDITOR_REWRITE.md](TERMUI_EDITOR_REWRITE.md).  This file is
> kept as the v0.1 record.

`termui` is Luce's terminal-UI package. It turns application state into a
deterministic cell surface and keeps terminal protocol details at the
`std.term` boundary. The application still owns its state and event policy;
termui owns the mechanics that every terminal program otherwise repeats:
frame preparation, clipping, layout rectangles, rendering composition, and
presenting a changed frame. The shipped package and editor are covered by 35
package tests plus the editor's differential transcript tests.

The package is deliberately a deep module, not a framework that takes over
`main`. Its public surface is small enough to learn in one sitting:

```text
packages/termui-0.1.0/
├── termui.luc       # Color, Style, Rect
├── screen.luc       # Cell, Screen, Painted
├── events.luc       # Event, Key, Mouse, Events
├── border.luc       # Border
├── rows.luc         # Rows and the read-only RowsView adapter
├── view.luc         # View, Text, Panel, Split
└── renderer.luc     # Renderer
```

## The smallest useful program

The application creates one renderer, begins a frame, paints views into its
surface, presents the changed cells, places the cursor, and reads the next
event. It decides what the events mean.

```text
import termui
import termui.events
import termui.screen as screen
import termui.renderer as renderer
import termui.view as views

func main():
    var ui = renderer.Renderer.open()
    var quit = false
    while not quit:
        let area = ui.begin()
        let title: views.View = views.Panel(
            title = "hello",
            child = views.Text(content = "Luce", style = termui.Style()),
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

`Renderer.open()` reads the current terminal size. `Renderer.of(rows,
columns)` and `begin_at(rows, columns)` are the host-free forms used by tests
and by programs that already have a size. `begin()` resizes when necessary,
clears the next frame, and returns the available `Rect`.

`present()` diffs the next frame against the last presented frame. It returns a
`Painted` value (`cells`, `runs`, and `moves`) and does not flush: put the
cursor where the application wants it, then call `flush()`. That order makes
cursor placement part of the same terminal commit and is easy to assert in a
fake host.

## Views and interfaces

`View` is a small, read-only interface:

```text
interface View:
    func measure(area: termui.Rect) -> (long, long)
    func draw(into: screen.Screen, area: termui.Rect)
```

The receiver is read-only. A view changes only the `Screen` value supplied by
the caller. This is intentional: Luce interfaces borrow carrying receivers,
so a retained tree of mutable widgets would make ownership and replacement
surprising. Keep state in the application and pass a drawing surface into a
view. Value-only views can be heterogeneous:

```text
var children = new list(views.View)
children.append(views.Text(content = "files"))
children.append(views.Panel(title = "output", child = views.Text(content = "ready")))
```

`Text` draws newline-separated lines and measures the largest line. `Panel`
draws a clipped border and delegates to an optional child. `Split` composes
two views horizontally or vertically; its `ratio` is the first child's
percentage and its `gap` is blank space between them. All dimensions are
clamped, so a resize produces empty rectangles rather than a trap.

`Rows` remains the stateful selection model: the application moves it in
response to an event. `RowsView` is its read-only `View` adapter. Construct the
adapter from the current `render`, `count`, `top`, and `selected` values when
painting; it never changes the `Rows` value while drawing.

This split between state and rendering is the important interface pattern in
termui. It supports heterogeneous composition without hiding an owning list
or a mutable receiver inside a long-lived interface value.

## Surfaces, cells, and clipping

`Screen` is an in-memory surface. Its `back` grid is the frame being built and
its `front` grid is what termui last told the terminal to show. `clear`, `put`,
`write`, and `fill` write only the back grid. `write` treats its row and column
as offsets inside the supplied rectangle and clips both to that rectangle and
the screen.

`Cell` stores a text unit and a `Style`. `Style` is a value: foreground,
background, and bold are chosen by the application. termui has no global theme.
`Screen.present()` groups adjacent changed cells with the same style into
runs. The first frame after `resize` is stale and is painted in full; an
unchanged frame paints zero cells.

The current text-width rule is the one in `std.strings`: it walks UTF-8
characters. It does not yet implement terminal grapheme clusters or a full
East Asian width table. Code that needs precise cursor columns should keep its
editing offsets separate from display drawing, as the editor does.

## Layout

`Rect` is total arithmetic. `split_top`, `split_bottom`, `split_left`, and
`split_right` clamp their requested size to the available dimension and return
the taken rectangle plus the remainder. `inset` shrinks both dimensions and
stops at an empty rectangle. A small terminal is therefore a normal resize,
not an exceptional path.

`Split` builds on those operations instead of introducing a hidden layout
solver. This is the first useful subset of the flex-style layout that inspired
OpenTUI: fixed rectangles, a percentage split, and a gap. A later layout
module can add grow/fixed constraints without changing the surface or view
contract.

## Events

`Events.next()` snapshots one host event into the closed `Event` union:

```text
closed
resize
key(pressed: Key)
text(typed: string)
mouse(pointer: Mouse)
```

Mouse coordinates, buttons, modifiers, wheel direction, and text are copied
into the event value. A key name not yet in `Key` becomes `Key.unknown`; the
stream's `last_name` preserves its raw spelling for applications that need to
handle a newer host event. termui does not ship a keymap: mapping keys to an
editor command or an application's intent belongs to that application.

## Ownership and lifecycle

- The application owns its model, providers, and event loop.
- `Renderer` owns its `Screen` and `Events` fields and centralizes resize,
  presentation, cursor placement, and flush sequencing.
- Views borrow the surface for one draw call; they do not retain it.
- A provider such as `Rows.render` borrows the application's owner. Mutate the
  provider's existing container in place or keep its owner alive; replacing an
  owning field while a bound provider is retained is rejected by design in
  the language's ownership model.
- Do not put a carrying mutable application model behind `View` merely to get
  dynamic dispatch. Keep that model in the app and make the view a value-only
  projection of the current state.

These rules avoid the shallow-wrapper and temporal-coupling problems described
in `docs/SOFTWARE_DESIGN.md`: terminal lifecycle is in one owner, layout and
painting have explicit inputs, and the caller can see where mutation and
failure occur.

## Why this shape

OpenTUI's useful ideas are the ones that survive Luce's type and ownership
model: one renderer owning terminal state, a retained surface made of cells,
structured input, shared layout geometry, explicit destruction/cleanup, and a
deterministic in-memory renderer for tests. Luce intentionally does not copy
OpenTUI's TypeScript VNodes, proxy-based constructs, or a universal mutable
widget interface. Those would be a large abstraction surface without Luce's
generics, inheritance, or writable interface receivers.

The comparison used OpenTUI's [renderer and lifecycle
documentation](https://opentui.com/docs/core-concepts/renderer/), its
[renderables and layout model](https://opentui.com/docs/core-concepts/layout/),
and its [deterministic testing guidance](https://opentui.com/docs/core-concepts/testing/),
alongside the [Zig renderer](https://raw.githubusercontent.com/anomalyco/opentui/main/packages/core/src/zig/renderer.zig)
and [cell buffer](https://raw.githubusercontent.com/anomalyco/opentui/main/packages/core/src/zig/buffer.zig).

The result is a compositional kernel. Applications can build their own state
machines and policies, while `Text`, `Panel`, `Split`, and `RowsView` remove
the repeated drawing code. A future retained tree, focus manager, scrollable
viewport, or richer layout engine can be added as another deep module without
making `Renderer` own application state.

## Tests and the editor

The package tests are grouped by boundary:

- layout totality (`layout_test.luc`);
- cell clipping and diffing (`screen_test.luc`);
- input snapshots (`events_test.luc`);
- borders and rows (`border_test.luc`, `rows_test.luc`);
- view/interface composition (`view_test.luc`); and
- renderer lifecycle (`renderer_test.luc`).

The editor is the end-to-end consumer. Its loop now uses `Renderer`; its file
listing and status bar paint through `View` values, while syntax highlighting,
editing state, key policy, and pane-specific layout remain editor-owned. The
editor differential specification drives both the interpreter and compiled
paths and compares the complete terminal transcript, so a visual or lifecycle
regression cannot hide behind a unit test that only checks a helper.

Deferred deliberately: a mutable retained widget tree, focus traversal,
scrollbars, mouse hit-testing policy, grapheme-aware terminal width, and a
global theme. Each needs its own ownership and testing decision before it
belongs in the core package.
