# termui

`termui` is Luce's declarative terminal-application package. An application
owns its state and describes the screen it wants. The library owns terminal
sizing, the application loop, layout, drawing, input routing, cursor placement,
cell diffing, flushing, resize handling, and shutdown.

The current package is `termui` 0.5.0 in `packages/termui-0.5.0/`. The
surface is grouped so an import line says what it brings: the core
module carries `Application`, the `View` contract, `Surface`, and the
value and event vocabulary, while composition, sizing, and the shipped
components live in named submodules.

```text
from termui import Application, View
from termui.layout import VStack, HStack
from termui.constraints import Fixed, Grow
from termui.widgets import Label, Panel, Rows
```

There is no renderer protocol for an application to coordinate and no public
screen to clear or present. The entry point is three calls:

```text
var app = termui.Application()
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
from termui.layout import VStack
from termui.widgets import Label, Panel
from termui.constraints import Fixed

class Counter: termui.View:
    count: i64

    init():
        self.count = 0

    func draw(surface: termui.Surface, area: termui.Rect) -> termui.Cursor?:
        surface.write(area, 0, 0, "Count: " + str(self.count), termui.Style())
        return none

    func dispatch(event: termui.Event, area: termui.Rect) -> termui.Response:
        match event:
            key(press):
                if press.key == termui.Key.enter:
                    self.count += 1
                    return termui.Response.handled
                if press.key == termui.Key.ctrl_q:
                    return termui.Response.quit
            else:
                return termui.Response.ignored
        return termui.Response.ignored

func main():
    var stack = VStack()
    stack.add(Counter())
    stack.add(Label("Enter adds one · Ctrl-Q quits"), Fixed(1))
    var app = termui.Application()
    app.set_layout(Panel("counter", stack))
    app.start()
```

The program contains no loop and rebuilds nothing. `start` draws the
retained tree, reads one event, routes it through the same tree the
person saw, and draws again: components read current state in `draw`
and update it in `dispatch`, and the cell diff keeps an unchanged
frame cheap.

## The public model

Three public submodules group the surface; the core `termui` module
carries everything an ordinary component signature mentions.

| Module | Name | Purpose |
|---|---|---|
| `termui` | `Application` | the retained root: `set_layout(child)`, `set_tick(ms)`, and `start()` |
| `termui` | `View` | the component contract: `draw(surface, area) -> Cursor?` and `dispatch(event, area) -> Response` |
| `termui` | `Surface` | the cell canvas `draw` receives: `write`, `fill`, `put`, `stroke`, `cell_at`, `snapshot` |
| `termui` | `Event`, `Key`, `Mouse`, `Pointer` | terminal input, `std.term`'s own types plus `closed` |
| `termui` | `Response` | `ignored`, `handled`, or `quit` |
| `termui` | `Style`, `Color`, `Span`, `Line`, `Edges` | presentation values |
| `termui` | `Rect`, `Cursor` | assigned geometry and cursor requests |
| `termui` | `route` | the one door a container dispatches a child through |
| `termui` | `snapshot` | host-free rendering for tests and previews |
| `termui.layout` | `HStack`, `VStack`, `ZStack` | horizontal, vertical, and overlapping composition |
| `termui.constraints` | `Constraint` | the one-axis sizing contract: bounds, weight, and an optional preference |
| `termui.constraints` | `Fixed`, `Grow`, `Ratio`, `Preferred` | the shipped sizes |
| `termui.widgets` | `Label`, `StyledText` | plain or span-styled text |
| `termui.widgets` | `Panel` | titled, junction-aware border around content |
| `termui.widgets` | `Rows` | lazily rendered visible window over indexed lines |
| `termui.widgets` | `Fill`, `Empty` | background content and intentional absence |
| `termui.widgets` | `EventHost`, `CursorHost` | behavior and cursor placement wrapped around content |

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

A component is any class conforming to `termui.View` — the openness 0.4 exists
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
`add(child, size)`; omitting the size means grow, and the `Fixed`, `Grow`,
`Ratio`, and `Preferred` classes spell a size the way the layout
reads: `add(bar, Fixed(1))`. A retained
layout reshapes with `resize(index, size)` — a drag hands a pane its
new constraint, and a hidden pane is `Fixed(0)`: zero cells draw
nothing and contain no pointer, so hiding needs no tree surgery.

```text
from termui.layout import HStack
from termui.constraints import Ratio

var across = HStack(spacing = 1)
across.add(sidebar, Ratio(12, 28, 25))
across.add(source)
```

A size is a `Constraint` — an interface with what the solver asks:
`minimum()`, `maximum()`, `weight()`, and `preference(axis)`.  Four
shipped classes conform, and a program's own constraint composes the
same way:

| Class | Meaning |
|---|---|
| `Fixed(cells)` | exactly this many cells |
| `Grow(weight, minimum)` | keep the minimum, then share surplus by weight |
| `Ratio(low, high, percent)` | a clamped percentage of the axis |
| `Preferred(low, ideal, high)` | a remembered size within bounds |

The solver is total. It includes spacing in the available axis, never returns a
negative size, and never allocates beyond the axis. When space is short it
compresses `ratio` and `preferred` regions before primary `grow` content; on a
truly tiny terminal optional regions may disappear.

## Text and styles

`Label(text, style)` is the common one-line component.
`StyledText(lines)` accepts `list[Line]`. A line contains styled spans:

```text
let warning = termui.Line(spans = [
    termui.Span(text = "warning: ", style = termui.Style(foreground = 3, bold = true)),
    termui.Span(text = "unsaved changes", style = termui.Style(foreground = 7)),
])
let message = StyledText([warning])
```

The package has no global palette. An application owns its theme as ordinary
`Style` values. Drawing clips to the rectangle assigned by the parent.

## Panels

`Panel(title, content, style, edges)` draws a border and gives its
interior to the content. `Edges` defaults to all four sides. Adjacent strokes
merge into the correct box-drawing junction; applications describe geometry
and never choose `┼`, `├`, or `┴` themselves.

```text
Panel(
    "output",
    output,
    style = active_border,
    edges = termui.Edges(bottom = false),
)
```

## Large or scrolling content

`Rows` renders only the indexes visible in its assigned height:

```text
Rows(total, render, top, anchor, selected, selected_style)
```

`render(index) -> Line` supplies content and is required — a lazy window with
nothing to render was never a real request. `top` is the requested first
index. `anchor` is kept visible; `selected` is highlighted. They are separate
because a source cursor should drive scrolling without highlighting the whole
line. `Rows.visible_top(top, total, anchor, height)` exposes the exact window
calculation for pointer and cursor callbacks.

The application owns `top`, selection, and the underlying data. `Rows` owns no
hidden collection or selection model.

## Events

Wrap behavior around content with `EventHost(content, respond)`. The
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
input remain lifecycle events owned by `start`.

The `Event` union is `closed`, `resize`, `idle`, `key`, `text`, or
`mouse`. `idle` arrives when a tick was asked for (`set_tick`) and the
wait produced nothing: a component holding work — a language server, an
animation — pumps it in `dispatch`, and everything else ignores it. A
`key` carries a `KeyPress` — the key plus `shift`/`alt`/`control`
booleans for what was held with it. `Key`, `KeyPress`,
`Pointer`, and `Mouse` are `std.term`'s own types, re-exported as aliases,
so termui events and plain terminal events carry the same values; termui
adds only `closed`, which `term.read()` spells as absence. A `Mouse`
value contains its pointer kind, row, column, button, modifiers, and wheel
delta. Unknown keys arrive as `Key.unknown` rather than an invalid enum.

## Cursor

`CursorHost(content, locate)` attaches a function `func(Rect) ->
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

The implementation has nine modules. Four are public — the facade and
the three grouped submodules — and five are implementation:

```text
termui.luc       the core: Application, View, Surface, values, operations
constraints.luc  public: the Constraint contract, shipped sizes, the solver
layout.luc       public: the stack containers
widgets.luc      public: the shipped leaf and wrapper components
model.luc        values, re-exported through the facade
input.luc        event decoding over std.term's vocabulary
canvas.luc       cell ownership, clipping, snapshots, and diffing
view.luc         the View contract, route, and snapshot
runtime.luc      Application and the sole loop
```

Application code imports the four public modules and nothing deeper;
`model`, `input`, `canvas`, `view`, and `runtime` are knowledge
boundaries whose public vocabulary arrives through the facade.

The example editor is the end-to-end consumer. It composes retained
`FileList`, `Editor`, `Console`, and `StatusBar` components (its `ui/`
folder) over one shared model, with a `Workbench` reshaping the stacks
through its model subscription; its entry point is argument validation
followed by `set_layout` and `start`. Snapshot tests cover its screen,
and eight scripted sessions run the complete hidden loop on both Luce
engines with leak checking.

## Current limits

The package deliberately has no invalidation or damage tracking (every
event redraws the retained tree and the cell diff pays for it), no
result-builder syntax, global environment, global theme, focus
registry, scrollbar, or grapheme/East-Asian-width engine. Applications keep focus and domain policy in
their own state. The `View` interface is the extension point: a new need is a
new conformer in the application first, and a shipped component only when a
real consumer proves the shape.
