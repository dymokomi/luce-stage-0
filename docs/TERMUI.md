# termui

`termui` is Luce's declarative terminal-application package. An application
owns its state and describes the screen it wants. The library owns terminal
sizing, the application loop, layout, drawing, input routing, cursor placement,
cell diffing, flushing, resize handling, and shutdown.

The current package is `termui` 0.5.0 in `packages/termui-0.5.0/`. Applications
normally import only its facade:

```text
import termui
```

There is no renderer protocol for an application to coordinate and no public
screen to clear or present. The entry point is three calls:

```text
var app = new termui.Application()
app.set_layout(root)
app.start()
```

## A complete application

The tree is retained: components are constructed once — typically with
the model they observe — composed with `add`, and handed to
`Application.set_layout`. `start()` owns the terminal until input
closes or a routed event answers `quit`.

```text
import termui
from termui import VStack, Label

class Counter: termui.View:
    count: i64

    init():
        self.count = 0

    func draw(surface: termui.Surface, area: termui.Rect) -> termui.Cursor?:
        surface.write(area, 0, 0, "Count: " + str(self.count), termui.Style())
        return none

    func dispatch(event: termui.Event, area: termui.Rect) -> termui.Response:
        match event:
            key(pressed):
                if pressed == termui.Key.enter:
                    self.count += 1
                    return termui.Response.handled
                if pressed == termui.Key.ctrl_q:
                    return termui.Response.quit
            else:
                return termui.Response.ignored
        return termui.Response.ignored

func main():
    var stack = new VStack
    stack.add(new Counter())
    stack.add(new Label("Enter adds one · Ctrl-Q quits"), termui.fixed(1))
    var app = new termui.Application()
    app.set_layout(new termui.Panel("counter", stack))
    app.start()
```

The program contains no loop and rebuilds nothing. `start` draws the
retained tree, reads one event, routes it through the same tree the
person saw, and draws again: components read current state in `draw`
and update it in `dispatch`, and the cell diff keeps an unchanged
frame cheap.

## The public model

The facade exports one application interface, one view interface, the
component classes, layout values, input values, styling values, and four
operations.

| Name | Purpose |
|---|---|
| `Application` | the retained root: `set_layout(child)` and `start()` |
| `View` | the component contract: `draw(surface, area) -> Cursor?` and `dispatch(event, area) -> Response` |
| `Surface` | the cell canvas `draw` receives: `write`, `fill`, `put`, `stroke`, `cell_at`, `snapshot` |
| `Label`, `StyledText` | plain or span-styled text |
| `HStack`, `VStack`, `ZStack` | horizontal, vertical, and overlapping composition |
| `Panel` | titled, junction-aware border around content |
| `Rows` | lazily rendered visible window over indexed lines |
| `Fill`, `Empty` | background content and intentional absence |
| `EventHost`, `CursorHost` | behavior and cursor placement wrapped around content |
| `Constraint` | one-axis sizing: bounds, weight, and an optional preference |
| `Event`, `Key`, `Mouse`, `Pointer` | terminal input, `std.term`'s own types plus `closed` |
| `Response` | `ignored`, `handled`, or `quit` |
| `Style`, `Color`, `Span`, `Line`, `Edges` | presentation values |
| `Rect`, `Cursor` | assigned geometry and cursor requests |
| `route` | the one door a container dispatches a child through |
| `snapshot` | host-free rendering for tests and previews |
| `visible_top` | the exact scroll window `Rows` renders, for callbacks |

Component names are capitalized because they describe UI nodes. Operations and
small helpers remain lowercase.

## Values, identity, and the model

The distinction is deliberate:

- components are classes because they are constructed once and live for
  the run: their fields are the pane-local state a rebuild used to
  destroy;
- the shared model a program hands its components is a class the
  components hold strongly — app to layout to components to model is
  the one ownership line;
- the internal `Surface` and `Screen` are classes because they own
  changing runtime state; and
- `Rect`, `Style`, `Line`, `Constraint`, `Event`, and `Snapshot` are values
  because they describe or observe one frame.

**The model never holds a component strongly.** ARC collects no cycles,
and component → model → component is one. A component that wants to
hear about model changes subscribes with a `[weak self]` closure — the
zeroing capture is the non-owning back edge — and it does so on first
use, never in `init`: a class cannot capture itself before its
initialization finishes.

```text
private func attach():
    if self.subscribed:
        return
    self.subscribed = true
    let watcher: func() = [weak self] func():
        let live = self
        if live != none:
            live.react()
    self.model.subscribe(watcher)
```

The model's side is a `list[(func())?]` of watchers and a `notify()`
its compound mutations call. Watchers update component-internal state;
the frame that follows reads the result.

## Writing a component

A component is any class conforming to `view.View` — the openness 0.4 exists
for. `draw` describes cells through the surface it is given; `dispatch`
answers one event. Both receive the exact rectangle the parent assigned.

```text
import termui

class Meter: termui.View:
    filled: i64

    init(filled: i64):
        self.filled = filled

    func draw(surface: termui.Surface, area: termui.Rect) -> termui.Cursor?:
        for at_column in range(0, min(self.filled, area.columns)):
            surface.write(area, 0, at_column, "#", termui.Style())
        return none

    func dispatch(event: termui.Event, area: termui.Rect) -> termui.Response:
        return termui.Response.ignored
```

**The routing law**: a container never calls `child.dispatch` directly — it
calls `termui.route(child, event, child_area)`. Route owns the pre-checks
every container would otherwise repeat: lifecycle events (`closed`, `resize`)
enter no subtree, and a pointer event enters only a rectangle containing the
pointer. A container that follows the law gets the same routing discipline as
the shipped ones; one that does not is the bug it wrote.

A component that draws borders lays them with `Surface.stroke(area, row,
column, up, right, down, left, style)`. Strokes merge with whatever border is
already in the cell and the junction glyph is chosen from the union, so a
user component's frame meets a `Panel`'s with a clean tee, without either
knowing the other exists.

## Stacks and sizing

`HStack` lays children left to right, `VStack` top to bottom. `ZStack` draws
in list order, so the last child is visually on top. A child enters with
`add(child, size)`; omitting the size means grow, and the facade's
`fixed(cells)`, `grow(weight, minimum)`, `ratio(low, high, percent)`,
and `preferred(low, ideal, high)` spell a size the way the layout
reads: `add(bar, fixed(1))`. A retained
layout reshapes with `resize(index, size)` — a drag hands a pane its
new constraint, and a hidden pane is `fixed(cells = 0)`: zero cells draw
nothing and contain no pointer, so hiding needs no tree surgery.

```text
var across = new termui.HStack(spacing = 1)
across.add(sidebar, termui.ratio(low = 12, high = 28, percent = 25))
across.add(source)
```

A size is a `Constraint` — a value carrying `minimum`, an optional
`maximum`, a `weight` for sharing surplus, and an optional preference
(`ideal` cells, or a `share` of the axis in percent).  Four
constructors spell the common shapes:

| Constructor | Meaning |
|---|---|
| `fixed(cells)` | exactly this many cells (`minimum = maximum`) |
| `grow(weight, minimum)` | keep the minimum, then share surplus by weight |
| `ratio(low, high, percent)` | a clamped percentage of the axis |
| `preferred(low, ideal, high)` | a remembered size within bounds |

The solver is total. It includes spacing in the available axis, never returns a
negative size, and never allocates beyond the axis. When space is short it
compresses `ratio` and `preferred` regions before primary `grow` content; on a
truly tiny terminal optional regions may disappear.

## Text and styles

`new Label(text, style)` is the common one-line component. `new
StyledText(lines)` accepts `list[Line]`. A line contains styled spans:

```text
let warning = termui.Line(spans = [
    termui.Span(text = "warning: ", style = termui.Style(foreground = 3, bold = true)),
    termui.Span(text = "unsaved changes", style = termui.Style(foreground = 7)),
])
let message = new termui.StyledText([warning])
```

The package has no global palette. An application owns its theme as ordinary
`Style` values. Drawing clips to the rectangle assigned by the parent.

## Panels

`new Panel(title, content, style, edges)` draws a border and gives its
interior to the content. `Edges` defaults to all four sides. Adjacent strokes
merge into the correct box-drawing junction; applications describe geometry
and never choose `┼`, `├`, or `┴` themselves.

```text
new termui.Panel(
    "output",
    output,
    style = active_border,
    edges = termui.Edges(bottom = false),
)
```

## Large or scrolling content

`Rows` renders only the indexes visible in its assigned height:

```text
new termui.Rows(total, render, top, anchor, selected, selected_style)
```

`render(index) -> Line` supplies content and is required — a lazy window with
nothing to render was never a real request. `top` is the requested first
index. `anchor` is kept visible; `selected` is highlighted. They are separate
because a source cursor should drive scrolling without highlighting the whole
line. `Rows.visible_top(top, total, anchor, height)` — also reachable as the
facade's `visible_top` — exposes the exact window calculation for pointer and
cursor callbacks.

The application owns `top`, selection, and the underlying data. `Rows` owns no
hidden collection or selection model.

## Events

Wrap behavior around content with `new EventHost(content, respond)`. The
responder receives the event and the exact rectangle assigned to that view:

```text
func respond(event: termui.Event, area: termui.Rect) -> termui.Response
```

Responses mean:

- `ignored`: continue routing;
- `handled`: stop routing; the next frame draws the updated state; and
- `quit`: end the application cleanly.

Routing is deterministic. A host sees an event before its content. Pointer
events enter only rectangles containing the pointer. Stacks visit children in
display order; `ZStack` visits the visually topmost child first. Keyboard and
text events continue until a focused child accepts them. Resize and closed
input remain lifecycle events owned by `run`.

The `Event` union is `closed`, `resize`, `key`, `text`, or `mouse`. `Key`,
`Pointer`, and `Mouse` are `std.term`'s own types, re-exported as aliases,
so termui events and plain terminal events carry the same values; termui
adds only `closed`, which `term.read()` spells as absence. A `Mouse`
value contains its pointer kind, row, column, button, modifiers, and wheel
delta. Unknown keys arrive as `Key.unknown` rather than an invalid enum.

## Cursor

`new CursorHost(content, locate)` attaches a function `func(Rect) ->
Cursor?`. An active view returns its terminal cursor; inactive views return
`none`. The child's request is computed first and the host's `locate`
overrides it when it answers one. The callback sees the same assigned
rectangle as rendering and events, so the application does not duplicate
layout arithmetic.

## Testing without a terminal

`snapshot(view, rows, columns)` renders into an owned, read-only cell snapshot.
It performs no host IO:

```text
let frame = termui.snapshot(root, 12, 60)
assert(frame.line(0) == "┌ counter ─────────────────────────────────────────────────┐")
let cursor = frame.cursor else termui.Cursor()
assert(cursor.row == 1)
```

`Snapshot.cell(row, column)` exposes a cell and its style; `line(row)` returns
the visible characters. A snapshot deep-copies the rendered cells, so later
frames cannot change an earlier assertion.

## The hidden lifecycle

For each event, `start` performs one fixed protocol:

1. read and normalize terminal dimensions;
2. resize and clear the next cell buffer;
3. draw the retained tree through its own `draw`, collecting its cursor;
4. diff against the last committed cells, write changed style runs, move the
   cursor, and flush once;
5. snapshot one host event; and
6. route it through the same tree and rectangles the user saw.

Keeping the visible tree for dispatch prevents pointer events from using newer
geometry than the screen. Keeping the entire protocol private prevents partial
frames, forgotten flushes, stale cursors, and loops that mishandle resize.

## Package boundaries

The implementation has eight modules:

```text
termui.luc      public facade
model.luc       public values
input.luc       event decoding over std.term's vocabulary
layout.luc      total one-axis solver
canvas.luc      cell ownership, clipping, snapshots, and diffing
view.luc        the View contract, route, and snapshot
components.luc  the shipped component classes
runtime.luc     Application and the sole loop
```

These are implementation knowledge boundaries, not eight APIs for an
application to orchestrate. Normal application code imports `termui` only.

The example editor is the end-to-end consumer. It composes retained
`FileList`, `Editor`, `Console`, and `StatusBar` components over one
shared model, with a `Workbench` reshaping the stacks through its
model subscription; its entry point is argument validation followed by
`set_layout` and `start`. Snapshot tests cover its screen, and eight
scripted sessions run the complete hidden loop on both Luce engines
with leak checking.

## Current limits

The package deliberately has no invalidation or damage tracking (every
event redraws the retained tree and the cell diff pays for it), no
result-builder syntax, global environment, global theme, focus
registry, scrollbar, or grapheme/East-Asian-width engine. Applications keep focus and domain policy in
their own state. The `View` interface is the extension point: a new need is a
new conformer in the application first, and a shipped component only when a
real consumer proves the shape.
