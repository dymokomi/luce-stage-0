# Declarative termui and editor rewrite

> **State.** This is the implementation plan for `termui` v0.3 and the
> editor that proves it. Until the work is complete, [TERMUI.md](TERMUI.md)
> remains the current package reference and
> [TERMUI_EDITOR_REWRITE.md](TERMUI_EDITOR_REWRITE.md) remains the record of
> v0.2.

This design follows [SOFTWARE_DESIGN.md](SOFTWARE_DESIGN.md): terminal
protocol, frame buffering, layout traversal, event routing and lifecycle
ordering belong behind one small interface. An application owns its model and
commands. It does not coordinate the terminal.

The useful lesson from SwiftUI is the model, not its syntax machinery:

- application state is the source of truth;
- `body` is a lightweight description rebuilt from that state;
- rows, columns and frames form a hierarchy that mirrors the result;
- modifiers wrap a view with behavior; and
- the framework owns drawing, updates and the application lifecycle.

Luce does not copy Swift's associated types, generics, result builders,
property wrappers, environment objects or scene system. Adding imitations of
those without the language support would move framework complexity into every
call site. Luce uses one closed `View` value, ordinary lists, bound class
methods and one `Application` interface instead.

## The problem

`termui` v0.2 hides terminal escape sequences and cell diffing, but its public
surface still makes every application perform this protocol:

```text
open renderer
while not finished
    read terminal dimensions
    clear and lay out a frame
    draw each region in the correct order
    present changed cells
    place the cursor
    flush
    read and decode an event
    update application state
```

That is temporal coupling. A caller must know which operations exist, their
order and which pieces of state survive between them. The editor consequently
has an imperative `paint` module, a duplicate pane-geometry module and its own
loop. `Renderer` is a shallow lifecycle helper because it exposes almost the
whole lifecycle it claims to own.

The replacement boundary is:

```text
class Editor: termui.Application
    func body() -> termui.View

func main(args: list[str])
    termui.run(Editor(args))
```

`run` is the only terminal lifecycle operation an application calls.

## Public model

### Application

`Application` has one requirement:

```text
interface Application:
    func body() -> View
```

An application is normally a class. Its identity owns mutable state, while
each `body` answer is an ephemeral value. `termui.run` retains the application
for the run. A view may carry bound application methods; those retain the same
identity until that frame is released.

`body` must be cheap and effect-free. File IO, saving, compilation and other
domain effects happen in event callbacks, not while describing a frame.

### View

`View` is a recursive tagged union owned by termui. A closed value is the
right representation because termui owns the complete set of traversal rules
and must exhaustively define drawing, cursor discovery and event routing for
each variant.

The public facade contains only components required by the editor:

```text
Empty()
Label(text, style)
StyledText(lines)
Rows(total, top, anchor, selected, render, selected_style)
Fill(glyph, style)
HStack(items, spacing)
VStack(items, spacing)
ZStack(children)
Panel(title, content, style, edges)
```

`HStack` and `VStack` receive `Item { size, content }`, pairing geometry with
its child so mismatched length and child lists are impossible. A view produces
that pair with `.sized(length)`. `Rows` is the
general visible-window primitive for source, file and output rows. A provider
answers one styled `Line`; the view owns clipping, selection fill and visible
range traversal. Its optional `anchor` is kept visible independently from its
optional highlighted `selected` row, so a text cursor can drive scrolling
without painting a whole source line.

Applications compose reusable views with ordinary functions returning
`View`. A new framework variant is added only when it needs a new traversal
rule. There is no public mutable widget base class and no retained widget
tree.

Mutable runtime owners are classes: `Surface` owns the changing front/back
cell grids, `Stream` owns input iteration, and applications are expected to be
classes whose callbacks share one identity. Descriptions and observations stay
values: `View`, `Rect`, `Style`, `Line`, `Length`, `Event` and `Snapshot` can be
built, passed and discarded without hidden lifecycle.

### Layout

One `Length` describes one axis:

```text
fixed(cells)
grow(weight, minimum)
ratio(low, high, percent)
preferred(low, ideal, high)
```

`fixed` is a status row or gutter. `grow` is primary content. `ratio` is an
automatic pane size. `preferred` is a person-resized pane. The solver first
honors ideals, gives surplus to grows, then compresses optional pane space
before primary content. Every result is non-negative and the total, including
spacing, never exceeds the available axis.

This is mechanism rather than editor policy. The editor chooses its minimum,
ideal and maximum values in `body`; termui owns the one correct solver.

### Modifiers

Methods on `View` return a wrapping `View`:

```text
content.sized(length)
content.on_event(callback)
content.cursor(callback)
```

They do not mutate `content`. Modifier order is structural and visible in the
tree. The event modifier receives the rectangle that was assigned to the
wrapped view, so an application never recomputes framework layout merely to
interpret a pointer.

### Events and responses

Raw host names become the existing closed `Event` union. An event callback
answers:

```text
ignored
handled
quit
```

`ignored` continues traversal. `handled` stops propagation and rebuilds the
next body. `quit` stops cleanly after releasing the current tree and terminal
state.

Routing is deterministic:

1. A modifier sees an event before its wrapped content. This lets a root
   handler own global commands.
2. Pointer events enter only rectangles containing the pointer.
3. Stacks visit children in display order; `ZStack` visits the
   visually topmost child first.
4. Keyboard and text events continue until the active child accepts them.
5. `closed` and `resize` are lifecycle events owned by `run`, not application
   commands.

Applications express focus as ordinary state. A pane callback returns
`ignored` when its pane is not focused. No hidden focus registry duplicates
the application's truth.

### Cursor

A cursor modifier answers `Cursor?` from its assigned rectangle. The active
pane answers a position and inactive panes answer `none`. The render traversal
chooses the first active cursor in tree order. If no view requests one,
termui uses a safe origin.

### Snapshot

`snapshot(view, rows, columns)` renders entirely in memory and answers a
read-only snapshot of cells and the chosen cursor. It performs no host IO.
Package and application tests assert declarative output through this seam
instead of reaching into the back buffer or manually running renderer phases.

## Hidden lifecycle

One loop in termui owns this invariant:

1. Read the current terminal size and resize the double buffer if necessary.
2. Clear the next frame.
3. Ask `application.body()` for one tree.
4. Lay out and draw that tree, discovering its cursor.
5. Diff against the last committed frame, write only changed runs, place the
   cursor and flush once.
6. Read and snapshot one input event.
7. Dispatch the event through the *same tree and rectangles that were
   visible*.
8. Release the tree, then rebuild from updated application state.

Using the visible tree for dispatch prevents a pointer from being interpreted
against geometry that has not been drawn. Rebuilding only after dispatch
prevents stale callbacks and makes every frame a function of current state.

The double buffer, terminal style protocol, input name table, junction
merging and resize invalidation remain implementation details. A caller
cannot put them in the wrong order because it cannot call them.

## Ownership and failure

- The application class owns durable domain and presentation state.
- A `View` owns its child lists, lines and bound callbacks for one frame.
- Bound callbacks retain their class receiver. The application does not store
  the view, so no cycle is formed.
- The terminal buffer owns its cells for the run and is released on every
  exit path.
- An exhausted input stream ends the run. Resize rebuilds. Ordinary callbacks
  cannot raise because function values do not carry fallibility.
- ARC leak checks cover snapshots, repeated body rebuilds, handled events and
  quit.

## Package structure

`termui` v0.3 replaces v0.2 atomically:

```text
termui.luc       public facade
model.luc        colors, styles, geometry, text, cursor and response values
input.luc        host event vocabulary and snapshot decoding
layout.luc       total one-axis solver
canvas.luc       cell buffer, clipping, diff and snapshots
view.luc         recursive view value, render and event traversal
runtime.luc      Application and the sole terminal loop
```

These are knowledge boundaries, not execution phases. The facade aliases the
public vocabulary so an application normally writes only `import termui`.
The implementation modules may be tested directly but are not separate
frameworks for callers to orchestrate.

## Editor migration

The editor becomes two layers:

- existing document, history, search, browser, console and session modules
  continue to own domain behavior; and
- one application class owns editor state, returns the view tree, supplies
  styled line providers and routes view-scoped events.

The imperative `editor/layout.luc`, `editor/paint.luc` and hand-written loop
disappear. Pane geometry is declared by `HStack` and `VStack` items. File, source,
output and status regions each receive their own event and cursor modifiers.
Global shortcuts live on the root modifier. Pointer drags are captured by the
application class after a divider press and handled at the root until release.

The editor's `main` validates arguments, constructs the application through a
custom initializer and calls `termui.run`.

## Acceptance

The rewrite is complete only when all of these are true:

- a smallest useful app contains no loop, renderer, surface, flush or input
  read;
- package tests cover empty and tiny layouts, compression order, nested
  composition, modifier order, pointer bounds, `ZStack` order, cursor choice,
  styled lines, panel junctions, snapshots and repeated ARC cleanup;
- the editor's pure domain tests remain independent of a terminal;
- editor snapshot tests prove its principal pane combinations and focus
  cursors;
- the differential editor scripts pass on the compiled engine and oracle,
  with zero leaked objects;
- the standalone editor and library artifact compile;
- repository and online package documentation describe only v0.3; and
- `zig build test`, the installed product build and the documentation-site
  gate finish cleanly.
