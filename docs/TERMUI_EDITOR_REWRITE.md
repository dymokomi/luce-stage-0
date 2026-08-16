# TERMUI_EDITOR_REWRITE.md — the termui v0.2 and modular-editor design

> **State.** `termui` v0.2 ships as `packages/termui-0.2.0/` (10 modules)
> and the editor is a modular Luce program under `examples/editor/` with
> undo/redo, in-file search, and crash-safe drafts.  Both engines agree
> on it (`specs/editor_spec.zig`).  This document is the design record for
> that work; [TERMUI.md](TERMUI.md) is the package reference.  The
> published site page (`www/luce/content/library/termui.md`) is the
> follow-up piece.

This plan is written against [SOFTWARE_DESIGN.md](SOFTWARE_DESIGN.md)
(deep modules, information hiding, no shallow wrappers, no god objects)
and [UX_UI_DESIGN.md](UX_UI_DESIGN.md) (reversible actions, preserved
work, honest state, recovery). Where the two pull, correctness and
preserved user work win.

## The decisions

1. **termui: clean rewrite from scratch.** A new package,
   `packages/termui-0.2.0/`, designed as one coherent layered kernel.
   The rewrite is not a rejection of what the v0.1 *core* learned — the
   grid/diff, the event union, and the renderer lifecycle were the good
   parts — but a fresh package lets every module boundary be drawn
   correctly at once, with no half-migration, and lets the three
   missing layers (real layout, junction-aware frames, styled text) be
   first-class rather than bolted on.
2. **Editor: modularize *and* add core editing.** Break the 1,156-line
   monolith into cohesive modules and add the capabilities
   UX_UI_DESIGN.md treats as table stakes for an editor: **undo/redo**
   (§32), **in-file search** (§39), and **autosave / crash-safe drafts**
   (§56). No LSP, multiple cursors, or diagnostics integration in this
   pass — those are a named follow-up.
3. **Order of work: plan, then build the settled core.** This document
   first; then the termui foundation — the value vocabulary, the
   surface, and the three new deep modules (`layout`, `text`, `frame`) —
   because they are the settled foundation both halves stand on.

---

## 1. Why rewrite — the diagnosis

termui v0.1 is two things bolted together.

**A deep, correct core** — `Rect` (total layout arithmetic), `Surface`
(back/front cell grids and a run-coalesced diff), `Events` (host key
names collapsed into one `Event` union), `Renderer` (the resize → begin
→ present → cursor → flush choreography, owned once). These hide real
complexity behind small interfaces and are covered by 35 tests. Their
*ideas* carry forward unchanged.

**A shallow widget layer the only real app routes around.** The
evidence is in the editor:

- `Panel` and `Split` are **never instantiated**. The editor's layout
  (sidebar 18–24 cols, output pane 3–8 rows, minimum sizes, "panes give
  way before the text") cannot be said with a single percentage
  `Split`, so the editor hand-rolls `model.Layout` with manual clamps.
- `Border` **cannot be used**: it draws four sides, but the editor's
  panes are three-sided and share edges, so the editor reimplements
  borders in `Draw.pane_frame`/`output_frame` — hand-selecting
  `term.ui.junction` glyphs. That junction-merging is exactly what
  TERMUI.md *deferred*.
- `Rows` is **half-used**: the editor keeps the state value but then
  hand-fills the selection bar and hand-draws the frame around it.
- The output pane is a scrolling viewport the library has no type for,
  so the editor hand-rolls that loop too.

So the widget layer hides almost nothing the real app needed. The three
things every terminal app actually repeats — **constraint layout**,
**frames that share edges**, and **styled text runs** — are the three
things termui v0.1 does not provide. That is the gap the rewrite fills.

On the editor side, the defect is a **god struct**. `State` owns the
text, the open buffers, the file browser, the build output, focus,
cursor, and scroll, with ~30 methods spanning editing, file navigation,
shell execution, mouse handling, focus traversal, and *all* painting.
The pure, testable pieces (`Text`, `Editing`, `Bytes`, `Word`, layout,
keymap) are good but buried in the same file as the effectful god
object. This is the "vague god object + temporal coupling" pattern
SOFTWARE_DESIGN.md §45/§14 warns against.

---

## 2. The design choice that shapes everything

The rewrite keeps a deliberately simple discipline instead of OpenTUI's
central abstraction — a retained tree of mutable `Renderable` widgets,
reconciled from a VNode description. There are **no generics** yet, so a
generic widget tree would be a large abstraction surface with no consumer
that needs it. v0.1 made the same call and it holds.

The rewrite commits to the alternative and makes it uniform:

> **The app holds the state; a View is a projection of the current state,
> drawn once.** A widget is therefore a *pair*: a small app-held **state
> struct** with the logic (movement, selection, scroll offset) and a
> **View** built from that state each frame. The View draws; it does not
> reconcile a persistent tree.

This is the pattern `Rows`/`RowsView` gestured at. The rewrite makes it
*the* pattern, applied consistently (`Rows`, `Viewport`), documented as
the way to build a widget, and free of the special-casing the editor had
to add — state in one place, the render path a pure function of it.

What survives from OpenTUI, restated for Luce: one cell buffer with a
diff (`surface`), shared layout geometry raised to a real constraint
solver (`layout`), structured input (`input`), an explicit lifecycle
owner (`renderer`), styled text runs (`text`), and a deterministic
in-memory renderer for tests (every module). What does not survive: the
mutable widget tree, VNodes, proxies, and any universal writable widget
interface.

---

## 3. termui v0.2 — target architecture

A clean layered kernel. Each module hides real complexity, is testable
in memory with no terminal, and — the acceptance test for the whole
rewrite — **is actually used by the editor**. Modules bottom-up:

```
packages/termui-0.2.0/
├── termui.luc     # Color, Style, Rect            — the value vocabulary
├── surface.luc    # Cell, Painted, Surface        — the cell grid + diff
├── text.luc       # Span, Line                    — styled text runs      [NEW]
├── layout.luc     # Length, Row, Column           — the constraint solver [NEW]
├── frame.luc      # Frame                         — junction-aware boxes  [NEW]
├── input.luc      # Key, Pointer, Mouse, Event, Events
├── view.luc       # View, Text, Fill
├── rows.luc       # Rows, RowsView                — selection list
├── viewport.luc   # Viewport, ViewportView        — scrollable window     [NEW]
└── renderer.luc   # Renderer                      — the lifecycle owner
```

`build.zig`'s `termui_modules` list and `termui_version` are updated to
match, and the entry module stays first in that array.

### 3.1 `termui.luc` — the value vocabulary

`Color` (16 names → `i32`), `Style` (foreground/background/bold, a copied
value that allocates nothing), and `Rect` (total arithmetic: `is_empty`,
`split_top/bottom/left/right`, `inset`). Carried over essentially as-is;
this is settled. `Style` stays deliberately small — no theme, no
underline/reverse until a consumer needs them (SOFTWARE_DESIGN.md §25).

### 3.2 `surface.luc` — the cell grid and its diff

`Cell` (text + style), `Painted` (the `cells`/`runs`/`moves` report a
test asserts against), `Surface` (back grid = next frame, front grid =
what the terminal shows; `clear`/`put`/`write`/`fill`/`present`).
`present` coalesces adjacent changed cells of one style into a run and
moves the cursor only between runs. Renamed **Surface** (from `Screen`):
views draw *into a surface*, and the name matches the vocabulary the
View interface already uses. Behaviour and the diff algorithm are the
proven v0.1 ones.

### 3.3 `text.luc` — styled text runs  **[NEW, central]**

The abstraction the highlighter and every label need and v0.1 lacked.

```
struct Span:
    text: str
    style: Style

struct Line:
    spans: list[Span]          # a program root or app-owned; drawn, not retained
```

`Line.draw(into: Surface, area: Rect, row: i64)` writes spans left to
right, clipped to the rectangle, tracking **display width**
(`strings.width`, the one answer to "how wide does this draw") rather
than byte length. `Line.width()` measures. This deletes every hand
cell-walk: the syntax highlighter returns a `Line`; `Text` (below) is a
`Line` per source row; the status bar is one `Line`.

Note to settle in code: a `Line` built per frame from `Span` values
(which copy) is the simplest correct shape; the editor's highlighter
produces one per visible row and drops it at end of frame.

### 3.4 `layout.luc` — the constraint solver  **[NEW, the biggest win]**

Replaces both the weak `Split` and the editor's hand-clamped
`model.Layout`. The one deep module that earns the "large hidden
implementation behind a small interface" test.

```
union Length:
    cells(count: i64)                           # exactly count cells
    grow(weight: i64)                           # share the leftover by weight
    between(min: i64, max: i64, ratio: i64)     # ratio% of the axis, clamped [min,max]
```

`between` is what the editor's sidebar and output pane want ("a quarter
of the width, but never below 18 or above 24, and give way before the
text starves"). Pure `ratio` and pure `min`/`max` are special cases of
it, so the surface stays three members, not six.

**Solver** — `solve(total: i64, gap: i64, items: list[Length]) ->
list[i64]`, total and never trapping:

1. `usable = max(total - gap * (count - 1), 0)`.
2. Preferred pass: `cells` → its count; `between` →
   `clamp(usable * ratio / 100, min, max)`; `grow` → 0 for now.
3. `claimed = sum(preferred)`, `remaining = usable - claimed`.
4. If `remaining >= 0`: distribute it to `grow` items in proportion to
   weight (integer division, the rounding remainder to the first grow).
   With no `grow`, the leftover is left unclaimed — honest, not
   silently padded.
5. If `remaining < 0` (oversubscribed, i.e. a small terminal): shrink
   flexible space — `grow` items to 0 first, then `between` items toward
   their `min` in proportion to their slack, then, only if still over,
   clamp everything down so the sum never exceeds `usable` and no length
   is negative.

`Row.solve(area, gap, items) -> list[Rect]` walks columns left to right;
`Column.solve(...)` walks rows top to bottom. A hidden pane is a
zero-length item that yields an empty `Rect`, which draws nothing —
never a flag and never a branch, because every `Rect` op is total.

Tested for: totality (no negative length, `sum <= usable` always),
oversubscription (shrink order is min-respecting), `grow` remainder
distribution, gaps, and the exact editor layout.

### 3.5 `frame.luc` — junction-aware boxes  **[NEW, delivers D12]**

The frame primitive the editor hand-rolls. A `Frame` says which of its
four edges to draw and, per edge, whether that edge **continues** into a
neighbour (so the corner becomes a T or a cross via `term.ui.junction`
rather than overwriting a rule).

```
struct Frame:
    title: str = ""
    style: Style = Style()
    top: bool = true
    right: bool = true
    bottom: bool = true
    left: bool = true
    # continuation hints: an edge that meets a sibling's rule
    joins_left: bool = false
    joins_right: bool = false
    joins_bottom: bool = false
    ...
```

`Frame.draw(into: Surface, area: Rect) -> Rect` draws the requested
edges with junction-correct corners and clips a titled top edge, then
answers the **interior** rectangle. A full box is
`Frame()`; the editor's file pane is
`Frame(bottom = false, title = " files ", joins_bottom = true)`; the
output pane is a top-only rule that meets the sidebar's vertical rule at
a `┬`. The compositor stays app-driven (the caller says which edges
join) — no hidden global "resolve all junctions" pass, which would be
information the frame cannot own.

### 3.6 `input.luc` — the event stream

`Key` (enum, one member per host name, `unknown` for the rest),
`Pointer`, `Mouse` (report copied out of the host at event time),
`Event` union (`closed`/`resize`/`key`/`text`/`mouse`), `Events`
(snapshots one host event into a value, `last_name` the escape hatch).
Carried over from v0.1 — it is already good. Room left for shift/alt
modifiers on non-ctrl keys when a consumer needs them.

### 3.7 `view.luc` — the read-only view interface

```
interface View:
    func measure(area: Rect) -> (i64, i64)
    func draw(into: Surface, area: Rect)
```

Concrete value-only views: `Text` (now `Line`-backed, so it is styled
per span, not one style for the block) and `Fill` (a rectangle of one
cell — the selection bar the editor hand-fills). `Panel`/`Split` do
**not** return: their jobs are `frame.Frame` and `layout` respectively,
and keeping dead near-duplicates would be the "clever reuse" smell
(SOFTWARE_DESIGN.md §49).

### 3.8 `rows.luc` and `viewport.luc` — the two widgets, one pattern

Both follow §2's pattern exactly: an app-owned **state** struct with the
logic, and a pure **View** projection.

- `Rows` (selection state: `count`, `top`, `selected`, `move_by`,
  `choose`, `adjust`) + `RowsView` (draws a `func(i64) -> Line`
  provider, highlighting the selected row). The provider stays a bound
  method so the widget reads app data through the receiver
  (docs/BINDING.md).
- `Viewport` (scroll state: `top`, `total`, `height`, `scroll_by`
  clamped) + `ViewportView` (draws a `func(i64) -> Line` provider over
  the visible window). This is the output pane, promoted out of the
  editor.

### 3.9 `renderer.luc` — the lifecycle owner

`Renderer` owns a `Surface` and an `Events`; `open`/`of`/`begin`/
`present`/`cursor`/`flush`/`next`. Present returns `Painted` and does
not flush, so the app places the cursor inside the same terminal commit.
Carried over from v0.1.

---

## 4. Editor v2 — target architecture

The god struct is dissolved into modules by responsibility. Pure modules
(no host, no terminal) are marked — they are driven directly by
`tests/`. `examples/editor/`:

```
document.luc    [pure]  the text buffer: content + cursor + scroll + dirty;
                        editing (insert/erase/newline/indent) and UTF-8/line/
                        column navigation. Folds v0.1's Text + Editing + Buffer.
history.luc     [pure]  undo/redo over a Document: a bounded revision stack.   [NEW]
search.luc      [pure]  in-file find: query, match offsets, next/prev.          [NEW]
highlight.luc   [pure]  Bytes + word tables + Word + the tokenizer, producing a
                        termui.Line of styled spans for one source line.
keymap.luc      [pure]  Intent enum + INTENTS/STEPS tables + intent_of/steps_of.
layout.luc      [pure]  pane rectangles, built on termui.layout (Column/Row/Length).
theme.luc               the Theme struct, the palette constant, Word -> Style.
session.luc             open buffers, active index, remember/restore, draft policy. [NEW behaviour]
browser.luc             file tree: directory listing, entry kinds, walk in/out.
console.luc             build/run: the shell command + output buffer + Viewport.
paint.luc               each pane rendered via termui frames/views/spans.
editor.luc              the app: arg parsing, wiring, the loop, intent dispatch.
```

Each is a real boundary (SOFTWARE_DESIGN.md §11/§13): `document` owns
text arithmetic, `history` owns reversibility, `browser` owns the
filesystem walk, `console` owns shell + output — none reaches into
another's representation. `editor.luc` holds the loop and routes an
`Intent` to the focused component; it is wiring, not logic.

### 4.1 New capability: undo/redo (UX §32)  — `history.luc` [pure]

A `Document` edit is reversible by snapshotting the minimum that
restores a valid prior state: `Revision { content, cursor }`. `History`
is a bounded stack of revisions plus a redo stack.

- `record(before)` pushes the pre-edit revision; consecutive insert
  keystrokes **coalesce** into one revision (so undo removes a word, not
  a letter), while a newline, a delete run, a paste, or a save closes
  the current group.
- `undo` swaps the live document with the top revision and moves it to
  redo; `redo` reverses. Undo restores cursor position too, so the
  change is *visible* (UX §32).
- Bounded depth keeps memory honest for large files; the bound is a
  named constant, not a magic number.

Pure and terminal-free → tested directly: type-then-undo round-trips to
the original bytes and cursor; redo replays; a save boundary is not
crossed by one undo; the bound evicts oldest first.

### 4.2 New capability: in-file search (UX §39)  — `search.luc` [pure]

`Search { query, matches: list[i64], current }`. `find(content,
query)` fills byte offsets via `strings.find`; `next`/`prev` move
`current` and answer the offset the editor moves the cursor to. A new
`Focus.search` puts keystrokes into the query; the status area shows the
query, the match count, and "no matches" as a distinct state (UX §30,
§39). Incremental: the query re-runs as it changes. Pure → tested for
zero/one/many matches, wrap-around, and empty query.

### 4.3 New capability: autosave / crash-safe drafts (UX §56)  — `session.luc`

The obligation UX §56/§62 attaches to "preserve my work": durable,
atomic, recoverable.

- **Atomic draft writes.** After the buffer has been dirty for an idle
  interval (measured with `clock_ms` between events) or every N edits,
  write the content to a sibling draft (`path + ".draft"`) via
  write-temp-then-`file_rename`, so a crash never leaves a torn file.
  A clean `Ctrl-S` deletes the draft.
- **Recovery on open.** If a draft exists and is newer than the file,
  the editor opens the file but surfaces a distinct recovery state
  ("recovered unsaved changes — Ctrl-Z to discard / Ctrl-S to keep"),
  never silently overwriting either version (UX §31, §56).
- The event loop currently blocks in `key_read`; the host presents the
  pending frame before blocking, so autosave is driven off the
  edit/event cadence, not a background timer. If a true idle timer is
  needed, it is a named follow-up, not a fake in the view layer
  (UX §77).

Draft policy lives in `session.luc` beside the buffer list it protects;
the atomic-write mechanism is `std.files`, not re-implemented.

### 4.4 Focus, and the intent router

`Focus` grows to `editor | files | output | search`. `editor.luc`'s
router is a flat dispatch: a global intent (save, quit, build, toggles,
next-pane, find) is handled regardless of focus; otherwise the intent
goes to the focused component's own key handler. This replaces the god
struct's one 100-line `key` method with one small router plus per-module
handlers — each testable where it lives.

---

## 5. Migration sequence

Small, behaviour-preserving steps (SOFTWARE_DESIGN.md §37), each ending
green. The existing **editor differential transcript test** (driven from
`src/apps/loom/shell.zig`, comparing the whole terminal transcript on
both engines) is the safety net kept passing across the whole migration
— it is what catches a visual or lifecycle regression a unit test cannot.

**Phase A — termui core (start now).**
1. Scaffold `packages/termui-0.2.0/` + `luce.yaml`; port `termui.luc`
   (value vocabulary) and `surface.luc` (grid + diff) with their tests.
2. Build `layout.luc` (the constraint solver) with its totality /
   oversubscription / grow / editor-layout tests.
3. Build `text.luc` (Span/Line) with clipping + width tests.
4. Build `frame.luc` (junction-aware) with box + shared-edge tests.
5. Port `input.luc`, `view.luc`, `rows.luc`, `renderer.luc`; add
   `viewport.luc`. Wire `build.zig` (`termui_modules`, `termui_version`).
   Package tests green.

**Phase B — editor pure core.**
6. `document.luc` (fold Text/Editing/Buffer), `keymap.luc`,
   `highlight.luc`, `layout.luc` — the pure modules, ported with their
   tests, each proven before the app uses it.
7. `history.luc` and `search.luc` — the new pure capabilities, with
   tests, before any UI.

**Phase C — editor shell.**
8. `theme.luc`, `browser.luc`, `console.luc`, `session.luc`,
   `paint.luc`, then `editor.luc` wiring on termui v0.2. Undo/search/
   autosave wired in. Keep the differential transcript passing (extend
   it to cover undo/search/recovery).
9. Flip `examples/editor/luce.yaml` to `termui: 0.2.0`; update the
   `build.zig` editor wiring for the new file set.

**Phase D — retire v0.1.**
10. Delete `packages/termui-0.1.0/` and `examples/editor/editor*.luc`
    (old files) once the new tree is green. Rewrite `docs/TERMUI.md` to
    describe v0.2. Update `www/luce` termui page if it renders samples.

No phase leaves two conventions for one concept live longer than the
phase that replaces it (UX §8, SOFTWARE_DESIGN.md §58).

---

## 6. Test strategy

- **termui**, per module, in memory (no terminal): layout solver
  (totality, oversubscription, grow, gaps, editor layout); text
  (clipping, display width vs byte length); frame (full box, three-sided,
  shared-edge junctions); surface (diff runs, resize-stale full paint);
  rows/viewport (scroll/selection windowing); renderer (lifecycle).
- **editor**, per pure module under `tests/`: document (edit round-trips,
  UTF-8 boundaries, indent-on-block), history (undo/redo invariants,
  coalescing, save boundary, bound), search (match sets, wrap, empty),
  highlight (word classification against the compiler's own tables),
  keymap, layout.
- **end-to-end**: the differential transcript test on both engines,
  extended to cover the three new capabilities and the recovery state.

Every claim about observable behaviour that can be a program runs on
both engines and is compared (the repo's differential rule).

---

## 7. Risks and open questions

- **Layout solver semantics** are the highest-risk design call; the
  spec in §3.4 is validated by implementing it against the exact editor
  layout as a test first. If `between`'s three fields prove awkward in
  use, revisit before frame/editor depend on it.
- **Undo granularity** (coalescing rule) is a UX judgement; the
  first-cut rule (§4.1) is "coalesce runs of plain insert, break on
  newline/delete/save" and is cheap to tune because `history` is pure.
- **Autosave idle timing** without a real background timer is bounded by
  the event cadence; if that proves too coarse for "preserve my work",
  a host idle/timeout on `key_read` is the honest fix, scoped as a
  follow-up rather than simulated.
- **Naming churn** (`Screen`→`Surface`, module renames) is a one-time
  cost paid because the package is a clean rewrite; it must not leak a
  half-renamed vocabulary (SOFTWARE_DESIGN.md §62).
- **Deferred, named, not faked:** grapheme-aware width, a full theme
  system, mouse hit-testing policy beyond the editor's needs, LSP /
  diagnostics / multiple cursors. Each gets its own ownership and test
  decision when a consumer needs it.
