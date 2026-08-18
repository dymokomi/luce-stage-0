# termui

`termui` builds terminal applications from declarative views. Your application
owns its state and says what should be visible. The package owns the terminal
loop, layout, drawing, input routing, cursor, resize handling, and efficient
screen updates.

You import one module, hand `Application` a retained layout, and call
`start`. Application code never opens a renderer, clears a surface,
flushes a frame, or writes its own loop.

## Start an application

Add `termui` to the project's `luce.yaml`:

```yaml
name: counter
version: 0.1.0
packages:
  termui: 0.5.0
```

Then build the screen once. Components are classes: `new` builds one,
`add` composes children into a stack, and the tree is retained — each
component keeps its own state for the life of the run.

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
    var stack = VStack()
    stack.add(Counter())
    stack.add(Label("Enter adds one · Ctrl-Q quits"), termui.Fixed(1))
    var app = termui.Application()
    app.set_layout(termui.Panel("counter", stack))
    app.start()
```

Build the file normally. The executable enters the terminal application when
it starts and returns when input closes or a routed event answers `quit`.

## How to think about it

A shared model class is the source of truth: construct components with
it (`Editor(model)`), and each component draws its pane from the
model in `draw` and mutates it in `dispatch`. After every event the
runtime redraws the retained tree; the cell diff keeps an unchanged
frame cheap.

This gives each kind of thing the right representation:

- components are classes constructed once, whose fields hold pane-local
  state a rebuild used to destroy;
- the model is a class the components hold strongly — app to layout to
  components to model is the one ownership line;
- geometry, styles, lines, constraints, events, and snapshots are values.

**The model never holds a component strongly** — ARC collects no
cycles, and component → model → component is one. A component that
wants to react to model changes subscribes with a `[weak self]`
closure, on first use rather than in `init` (a class cannot capture
itself before initialization finishes):

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

## Components

The shipped components are classes conforming to `termui.View`:

| Component | Use it for |
|---|---|
| `Label(text, style)` | one line of text |
| `StyledText(lines)` | one or more lines made from styled spans |
| `HStack(spacing)` then `add` | children from left to right |
| `VStack(spacing)` then `add` | children from top to bottom |
| `ZStack()` then `add` | overlapping children; the last is on top |
| `Panel(title, content, style, edges)` | titled, junction-aware border |
| `Rows(total, render, top, anchor, selected, selected_style)` | a visible window over indexed content |
| `Fill(glyph, style)` | fill an assigned rectangle |
| `Empty()` | intentionally draw nothing |
| `EventHost(content, respond)` | behavior wrapped around content |
| `CursorHost(content, locate)` | cursor placement wrapped around content |

The uppercase names are UI components. Lowercase names are operations or
small helpers.

## Compose a screen

Stacks receive children through `add(child, size)`; omitting the size
means grow, which is what the main content of a screen usually wants,
and the `Fixed`, `Grow`, `Ratio`, and `Preferred` classes spell a
size the way the layout reads: `add(bar, Fixed(1))`. A retained layout reshapes with `resize(index, size)`; a hidden
pane is `fixed(cells = 0)` — zero cells draw nothing and contain no
pointer:

```text
var across = termui.HStack(spacing = 1)
across.add(
    termui.Panel("files", file_rows),
    termui.Ratio(12, 28, 25),
)
across.add(source_rows)
```

`HStack` divides columns. `VStack` divides rows. `ZStack` gives every child the
same rectangle and paints them in order, which is useful for a background plus
foreground content.

### Constraint

A size is a `Constraint` — an interface with what the solver asks:
`minimum()`, `maximum()`, `weight()`, and `preference(axis)`. Four
shipped classes conform, and a program's own constraint composes the
same way:

| Class | Behavior |
|---|---|
| `Fixed(cells)` | exactly that many cells |
| `Grow(weight, minimum)` | keeps its minimum and shares remaining space |
| `Ratio(low, high, percent)` | takes a clamped percentage of the axis |
| `Preferred(low, ideal, high)` | uses a remembered size within limits |

The solver is total: spacing is included, no result is negative, and allocated
sizes never exceed the available axis. Optional `ratio` and `preferred` panes
compress before primary `grow` content. If a terminal becomes extremely small,
optional panes can disappear rather than trapping or creating invalid geometry.

`preferred` is useful after a person drags a divider. Keep the chosen size in
the application, then use it as the next body's `ideal`.

## Labels, lines, and styles

`Style` has `foreground`, `background`, and `bold`. `Color` names the sixteen
terminal colors, while numeric color indexes can be used directly. The package
has no global theme; keep a palette with the application.

For syntax highlighting or mixed styles, construct a `Line` from `Span`
values and pass lines to `StyledText` or return them from `Rows`:

```text
let warning = termui.Line(spans = [
    termui.Span(
        text = "warning: ",
        style = termui.Style(foreground = 3, bold = true),
    ),
    termui.Span(
        text = "unsaved changes",
        style = termui.Style(foreground = 7),
    ),
])

let message = termui.StyledText([warning])
```

`plain(text, style)` constructs a one-span `Line`. Drawing clips content to the
rectangle assigned by the parent.

## Panels

`Panel` draws its requested edges, then lays its content into the remaining
interior. All four edges are present by default:

```text
termui.Panel(
    "output",
    output,
    style = active_border,
    edges = termui.Edges(bottom = false),
)
```

Where panel strokes meet, the package merges them into the correct
`┼`/`├`/`┴`/… glyph. Your application describes neighboring panels; it never
chooses junction characters.

## Long lists and documents

`Rows` calls a provider only for visible indexes:

```text
termui.Rows(
    total,
    self.line_at,
    top = top,
    anchor = anchor,
    selected = selected,
    selected_style = selected_style,
)
```

The provider signature is `func(i64) -> Line` and it is required.

- `total` is the number of available rows.
- `top` is the requested first visible index.
- `anchor` is kept inside the visible window.
- `selected` receives `selected_style` across its entire row.

Anchor and selection are separate on purpose. A file browser often uses the
same index for both. A text editor uses the cursor line as its anchor and
`none` as its selection, so scrolling follows the cursor without painting a
selection bar.

The application owns the collection, top index, and selection. `Rows` stores
no duplicate model. `visible_top(top, total, anchor, height)` exposes the exact
window calculation when an event or cursor callback needs to map screen rows
back to indexes.

## Handle events

Wrap content in an `EventHost`:

```text
func respond(event: termui.Event, area: termui.Rect) -> termui.Response
```

The responder receives the exact `Rect` assigned to the wrapped view. That is
the rectangle to use for pointer hit testing; do not reproduce stack layout in
the application.

`Response` has three values:

| Response | Effect |
|---|---|
| `ignored` | continue routing through the tree |
| `handled` | stop routing; the next frame draws the updated state |
| `quit` | release the current tree and leave the application |

A host receives an event before its content, so a root host can own global
shortcuts. Pointer events enter only views whose rectangle contains the
pointer. Stacks visit children in display order. `ZStack` checks the visually
topmost child first. Keyboard and text events continue until the focused
child accepts them.

`Event` is a closed union:

```text
closed
resize
key(pressed: Key)
text(typed: str)
mouse(pointer: Mouse)
```

`Key`, `Pointer`, and `Mouse` are [`std.term`](/library/term/)'s own types,
re-exported as aliases, so termui events and plain terminal events carry the
same values; termui adds only `closed`, which `term.read()` spells as
absence. `Mouse` carries `kind`, `row`, `column`, `button`, `modifiers`, and
`wheel`. `Pointer` is `press`, `release`, `drag`, `move`, or `wheel`.
`Mouse.has_shift`, `has_alt`, and `has_control` inspect modifiers. An
unrecognized host key is `Key.unknown`.

`closed` and `resize` are owned by the application runtime. They are present in
the event vocabulary but are not dispatched as ordinary commands.

## Place the terminal cursor

Wrap content in a `CursorHost`:

```text
func cursor(area: termui.Rect) -> termui.Cursor?
```

Return a cursor for the active view and `none` for inactive views. The child's
request is computed first and the host's `locate` overrides it when it answers
one. The callback receives the same assigned rectangle as drawing and events.
If no view requests a cursor, the runtime uses a safe origin.

## Write your own component

A component is any class conforming to `termui.View`: `draw` describes cells
through the `Surface` it is given, `dispatch` answers one event, and both
receive the exact rectangle the parent assigned.

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

A `Meter` participates in stacks, panels, snapshots, and routing exactly like
a shipped component. Two rules keep a custom component honest:

- **the routing law** — a container never calls `child.dispatch` directly; it
  calls `termui.route(child, event, child_area)`, which screens lifecycle
  events and contains pointer events once, for every container; and
- borders are laid with `Surface.stroke(area, row, column, up, right, down,
  left, style)`, which merges with whatever border is already in the cell —
  so a custom frame meets a `Panel` with a clean junction.

## Test a view without a terminal

`snapshot(view, rows, columns)` renders entirely in memory:

```text
let frame = termui.snapshot(root, 12, 60)
assert(frame.line(0).contains("counter"))

let first = frame.cell(0, 0)
assert(first.text == "┌")
```

`Snapshot.line(row)` returns visible characters. `cell(row, column)` returns
the character and style. `cursor` records the chosen `Cursor?`. The snapshot
owns a deep copy of its cells, so rendering another frame cannot change it.

Snapshots are the preferred test seam. They prove the same layout and draw
traversal as the live runtime without terminal IO or lifecycle choreography.

## What `start` owns

Every iteration follows one invariant:

1. read terminal dimensions and resize the cell buffers;
2. clear the next frame;
3. draw the retained tree through its own `draw` while discovering the cursor;
4. write only cells that differ from the last frame, place the cursor, and
   flush once;
5. snapshot one terminal event; and
6. route it through the same tree and rectangles that were visible.

Using the visible tree for input prevents a pointer from being interpreted
against geometry the person has not seen. Hiding the entire sequence prevents
partial frames, stale cursors, forgotten flushes, and resize-order bugs.

## Public names

The `termui` facade exports:

- components: `Empty`, `Label`, `StyledText`, `Rows`, `Fill`, `HStack`,
  `VStack`, `ZStack`, `Panel`, `EventHost`, `CursorHost`;
- the contract: `View`, `Surface`, `route`;
- layout: the `Constraint` interface and its `Fixed`, `Grow`, `Ratio`, `Preferred` classes; `Rect`, `Edges`;
- text and styling: `Color`, `Style`, `Span`, `Line`, `plain`;
- input and response: `Key`, `Pointer`, `Mouse`, `Event`, `Response`;
- application: `Application` (`set_layout`, `start`), `Cursor`; and
- testing: `Snapshot`, `snapshot`, `visible_top`.

Application code should import `termui`, not its implementation modules. The
package source is split into model, input, layout, canvas, view, components,
and runtime boundaries so each piece can hide its complexity and be tested
independently.

## Current limits

The package does not include invalidation or damage tracking (every
event redraws the retained tree; the cell diff keeps that cheap),
result-builder syntax, a global environment or theme, a focus registry,
scrollbars, or a full grapheme/East-Asian-width engine. Applications keep focus and domain policy in
their own model. The `View` interface is the extension point for anything
else. The shipped editor is the larger reference application: it uses panels,
all three stacks, lazy rows, styled source, pointer routing, resizable panes,
cursors, and the hidden loop.
