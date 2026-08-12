# termui: the terminal UI package (design)

**Status: DESIGN.** Nothing below is built. This memo designs
`termui`, the package PACKAGES.md names as the flagship — the retained
terminal UI that was deliberately kept out of `std` and returns as a
package — and the editor's migration onto it, which makes `loom
edit`'s editor the first dependency-carrying program.

It is written last on purpose. Every decision below spends something
the language did not have three weeks ago: tagged unions carry the
events (`docs/UNION.md`), storable function values carry the
providers (`docs/BINDING.md` D7), bound methods make a provider that
reads app state (D1/D4), `luce test` runs the package's own tests
(`docs/TESTING.md`), and the package machinery loads it at all
(`docs/PACKAGES.md`). termui is where those stop being features and
become a program.

Every fenced block below is ```` ```text ````, for the reason
`docs/FILESYSTEM.md` gives: a design memo's examples are the design's
and not the build's, and none of these fragments — signatures without
bodies, structs naming types from other modules — is a program. What
*was* checked against the installed toolchain is checked, and said so:
the four probes under "Findings from designing it" are real compiles
of real files, and one of them found a blocker.

---

## The evidence

`examples/editor/editor.luc` is 1,263 lines. **373 of them — 30% —
are terminal plumbing**, and none of it is about editing text:

| what | lines |
|---|---|
| `Draw` (clipping, gutters, borders, styled runs) | 137 |
| `frame()` (the whole layout, by hand) | 92 |
| `output_frame()` | 34 |
| `status()` | 22 |
| `adjust()` (scroll clamping) | 11 |
| `Intent.of` (a 50-line if-chain over key *names*) | 50 |
| the main loop's event dispatch | 27 |

Three panes each clamp their own scroll, each clip their own text to
their own width, and each draw their own border; the key names arrive
as strings and are compared one at a time; and every frame begins with
`term.clear()` and repaints all 1,920 cells of an 80×24 terminal
because there is nothing that knows which of them changed. That is
the duplication SOFTWARE_DESIGN.md §69 asks a new abstraction to
justify itself against, and it is the only justification offered here:
**termui exists because the editor wrote it three times.**

## What holds

- **The host keeps every escape byte.** `Host.terminal` is a vtable
  (`rows/cols/clear/move/style/write/flush/key`), `term_write` text is
  sanitized, and a Luce program cannot emit a control sequence. termui
  changes none of that: it computes *what* should be on the screen and
  says so through `std.term`, exactly as the editor does today.
- **Scope ownership, unchanged.** No new rule, no new verb, no
  exception. §"Ownership" below is a consequence, not a design.
- **No generics, no dynamic dispatch, no inheritance, no closures over
  the environment.** Every decision below is shaped by those four
  refusals, and D7 and D9 exist *because* of them rather than in spite
  of them.

---

## Decisions

| | decision |
|---|---|
| **D1** | **The app owns the loop.** termui supplies a screen, a layout vocabulary, an event stream and a few widgets; it never takes control and there is no `run()` that calls back. |
| **D2** | **The screen is a double-buffered cell grid, diffed in Luce.** `present()` emits only the cells that changed, coalescing adjacent equal-styled cells into one write. |
| **D3** | **`Style`, `Color` and `Rect` are values.** No theme registry, no palette owned by the library. |
| **D4** | **Layout is total pure functions on rectangles** — four splits and an inset — not a solver. |
| **D5** | **Input is one union**, `Event`, with a `Key` *enum* rather than a key name. |
| **D6** | **An event is a value with its data copied in**, closing the host's mutable-event-data hazard. |
| **D7** | **There is no widget tree and no `Widget` union.** The app's own struct is the tree. |
| **D8** | **A widget that shows data it does not own takes a reading provider**, `(func(long) -> string)?`. |
| **D9** | **Every widget answers its own event union**; the app translates to its own intent. |
| **D10** | **There is no keymap in termui**, and that is a decision, not a gap. |
| **D11** | **Unicode belongs to `std.strings`**, which gains a character vocabulary and loses two byte-counting bugs. |
| **D12** | **v0.1 is five modules**, and the editor is the acceptance test. |

### D1. The app owns the loop

Elm's shape without Elm's runtime. The app writes:

```text
while not app.quit:
    app.draw()
    match ui.next():
        closed:
            break
        resize:
            app.screen.resize(term.rows(), term.cols())
        key(pressed):
            app.key(pressed)
        text(typed):
            app.insert(typed)
        mouse(pointer):
            app.point(pointer)
```

An inverted loop — `termui.run(app)` — cannot be written honestly
here. It would have to call back into the app, and a callback that
*changes* app state is exactly what BINDING D9 refuses: a writing
method does not bind, because a bound writer is an inout closure whose
store-back discipline has not been designed. So an inverted loop would
have to invent a message queue and a state-threading protocol to give
back what the app's own `while` already has. The app's loop needs
neither, and every line of it is visible in the app's own file.

This is also what keeps termui from being a ceiling. A program that
wants an event termui does not model reads `term.io` itself on the
same loop; nothing is hidden behind a framework that owns `main`.

### D2. The screen is a diffed cell grid

```text
struct Cell:
    text: string = " "
    style: Style = Style()

struct Screen:
    rows: long
    columns: long
    back: array(Cell, _, _)      # what the next frame should be
    front: array(Cell, _, _)     # what the terminal is showing
```

`clear()` fills `back` with blanks, `put`/`write` fill cells, and
`present()` walks the two grids, writes only where they differ, copies
`back` over `front`, and flushes. A `Cell` is a plain value struct, so
the comparison is `back[r, c] != front[r, c]` — the language's own
struct equality, not a hand-written field-by-field test.

Measured on a working miniature (`Screen.of(4, 10)`): the first
`present()` writes 40 cells, the second writes **0**, and clearing and
writing two characters elsewhere writes 7 — the five cells vacated
plus the two filled. The editor today writes 1,920 cells for the
second frame and for every frame after it.

**One output optimisation, stated here so nobody adds a second.**
`present()` coalesces a horizontal run of changed cells that share a
style into a single `term.write`, and emits `term.move` only when the
next run does not continue where the last one ended. That is the whole
of it: no damage rectangles, no scroll-region tricks, no cursor-motion
cost model. A terminal has a couple of thousand cells and the diff
already removed the only order of magnitude that mattered.

**Resize replaces both grids and forces a full repaint.** A `dirty`
flag makes the next `present()` unconditional, because the terminal's
contents after a resize are not knowable.

### D3. Style, Color and Rect are values

```text
struct Style:
    foreground: long = 7
    background: long = -1
    bold: bool = false
```

`Color` is an enum of the sixteen named colors for readability
(`int(Color.blue)` is the number the host wants); the field stays a
`long` because 256-color terminals are the reason `term_style` takes
one.

**termui ships no theme.** A theme is a struct of `Style`s that the
app declares as a `const`, exactly as the editor's `theme` is today.
A library that owns the palette owns the app's identity, and the
editor's syntax colors are the editor's.

### D4. Layout is four splits and an inset

```text
struct Rect:
    row: long
    column: long
    rows: long
    columns: long

    func split_top(height: long) -> (Rect, Rect)
    func split_bottom(height: long) -> (Rect, Rect)
    func split_left(width: long) -> (Rect, Rect)
    func split_right(width: long) -> (Rect, Rect)
    func inset(amount: long) -> Rect
```

Every one is **total**: a split wider than the rectangle answers the
whole rectangle and an empty one, and `inset` past the middle answers
an empty rectangle. A 3-row terminal is a resize, not a bug, and a
layout vocabulary that traps on a small window is a layout vocabulary
that traps on a window.

**The clamping is the app's.** The editor wants its file pane between
18 and 24 columns and a quarter of the width; that is `clamp(cols / 4,
18, 24)` at the call, not a `minimum:`/`maximum:` pair on `split_left`.
Splits stay arithmetic; policy stays where the policy is.

Refused: flex, grid, and constraint solvers. The editor's entire
layout is four splits.

### D5 and D6. One event union, and an event is a value

```text
union Event:
    key(pressed: Key)
    text(typed: string)
    mouse(pointer: Mouse)
    resize
    closed
```

A payload field is named, always, and a `match` arm binds it **by the
field's own name** with no rename form (UNION.md D5, D11) — so the
field names are chosen to read well at the arm that will bind them,
`key(pressed):` rather than `key(key):`. This memo first wrote
`key(Key)`; running its own samples through the checker said
otherwise, and the correction is here rather than in a footnote.

`Key` is an **enum** — `left`, `enter`, `ctrl_s`, `page_down`, … — with
one member per name the host can produce, plus `unknown`. That set is
**derived, not invented**: `src/apps/key.zig`'s own `Key` union is
`enter, tab, backspace, delete, up, down, left, right, home, end,
page_up, page_down, escape` plus `control: u8`, which
`src/apps/host.zig` renders as `ctrl_` + the letter — so the enum is
those thirteen, `ctrl_a` through `ctrl_z`, and `unknown`. Forty
members is not too many: the alternative, a `control(letter: string)`
member mirroring the host's payload, puts a string comparison back at
every call site, which is the thing this decision exists to remove.
`Key.ctrl_s` is a name the compiler checks.
The enum is what makes `match` exhaustive: a key added to the host
later is a compile error at every `match` that did not consider it,
which is the whole reason ENUMS.md made exhaustiveness the default.
For the program that wants the raw name anyway — debugging, or a key
termui has not learned — `Events.last_name() -> string` is the named
escape hatch.

**D6 is a bug fix disguised as a type.** `term.io.row()`,
`.column()`, `.button()`, `.modifiers()` and `.value()` read data
belonging to *the event most recently returned by `read()`*. That is
mutable global state with a lifetime nothing enforces: hold an event
across another `read()` and its coordinates silently become another
event's. A `Mouse` value with its five numbers copied in at the moment
the event is made cannot do that. The editor gets this right today by
reading all five immediately and passing them as arguments — five
arguments at one call site, which is what a struct is for.

### D7. There is no widget tree

A retained tree of heterogeneous widgets needs one of three things
Luce does not have: inheritance, dynamic dispatch, or a `union Widget`
listing every widget kind. The first two are refused permanently. The
third is worse than refused — **it is a ceiling**: a union declared in
a package is a closed set, an app cannot add a member to it, and the
first program that wants a widget termui did not think of would have
to fork the package.

So there is no tree. **The app's own struct is the tree**, with a
named field per pane:

```text
struct App:
    screen: Screen
    files: Rows
    output: Rows
    focus: Focus
```

Every pane is reachable by name, at its concrete type, with its own
methods — and composition is calling `draw` with a `Rect`. This is
`docs/SELF.md`'s sentence about state that travels with behaviour,
applied to a screen: the tree was always there, written in the app's
own vocabulary, and giving it a second existence inside the library
buys nothing but a way to get them out of step.

### D8 and D9. Providers in, widget events out

The one widget in v0.1 that shows data it does not own is `Rows`, the
scrolling list, and it does not take the list:

```text
struct Rows:
    render: (func(long) -> string)?
    top: long = 0
    selected: long = 0
    count: long = 0
```

**`render` comes first and carries no default**, because fields with
defaults come last and because a `Rows` with no provider is a pane
that shows nothing — the language's field order made the required
thing required, which is the check catching a design mistake rather
than a typo.

`render` is BINDING D7's storable form filled by D1/D4's borrowing
bind, and the editor's file pane is its customer:
`app.files.render = app.names.at`, where `Names.at(index) -> string`
is an ordinary reading method on a struct that owns the list. The
widget reads app data without owning it and without a type parameter.

Handing the widget the list instead would make the widget the owner of
app data, which S21 would then make the app `give` away — and the app
still needs the list. The provider is not a workaround for the missing
generic; it is the honest direction of the dependency.

Out the other side, **a widget answers its own event union**:

```text
union RowsEvent:
    moved(index: long)
    chosen(index: long)
```

`app.files.key(k)` answers a `RowsEvent?`, the app matches it, and the
app decides what "chosen" means. No `Msg` type parameter, because
there are no type parameters; no generic message, because a widget's
events are a small closed set that the *widget* owns, which is exactly
what a union is for. This is PACKAGES.md's "widget event unions
instead of generic messages", and it is the decision that makes a
generic-free widget library possible at all.

### D10. No keymap, deliberately

A keymap maps a key to *the app's* intent, and termui cannot name that
type — it is the generic that does not exist. So termui ships none,
and the app writes a table of its own:

```text
const KEYS = {
    int(Key.left): Intent.move_left,
    int(Key.ctrl_s): Intent.save,
}
```

That is a file-scope map constant holding enum values (CONSTANTS.md),
and it replaces the editor's 50-line `Intent.of` if-chain with data.
The win is the editor's, not termui's, and saying so here is what
keeps termui from growing a feature it cannot type.

**The `int(...)` on every key is ceremony, and it is the language's,
not the design's.** `map` keys are `long` or `string` — `{Key.left:
…}` is refused with *"map keys are long or string, got Key"* — even
though an enum **is** an integer at a chosen width with equality as its
whole comparison surface, which is exactly what a map key needs. Both
shapes were probed and both work (`int(Key.x)` keys, or a const
`array(Intent, _)` indexed by `int(key)` when the enum is dense), so
this design is not blocked; it is noted here because a table keyed by
an enum is the natural spelling of every keymap anyone will ever write,
and today the reader pays for it at every row. Filed separately.

### D11. Unicode belongs to std

termui needs two questions answered that `std.strings` cannot answer
today, and the editor answers them for itself in a private `Text`
struct built on `byte_at` and continuation-byte tests:

- **How many cells does this string occupy?** There is no `width`.
- **What is the character at this position?** There is no character
  iteration.

Worse, `strings.pad_left` and `strings.pad_right` pad to a width
counted **in bytes** — their doc comment says so plainly — so every
label containing a non-ASCII character misaligns by however many
continuation bytes it carries. In a terminal UI that is not an edge
case; it is the first column of the first box-drawn pane.

So `std.strings` gains the character vocabulary and termui defines
none of its own:

- `characters(s) -> list(string)` — the code points, as strings.
- `width(s) -> long` — display cells.
- `take(s, cells) -> string` — the prefix that fits.
- `pad_left`/`pad_right` **corrected to pad by cells.** ASCII is
  unchanged, which is why this is a fix rather than a break, and the
  specs prove both halves.

**Named limitation, with its seam.** v0.1 counts *code points*, so
`width` answers 1 for a wide CJK character that occupies two terminal
cells, and combining marks count separately. That is exactly what the
editor does today, so nothing regresses — and unlike today it is
wrong in **one function** instead of in every program, which is the
point of moving it. When the width table lands, `strings.width` is the
only body that changes.

### D12. v0.1 is five modules

```text
packages/termui-0.1.0/
├── luce.yaml            # name: termui, version: 0.1.0
├── termui.luc           # Style, Color, Rect          (import termui)
├── screen.luc           # Cell, Screen                (import termui.screen)
├── events.luc           # Event, Key, Mouse, Events   (import termui.events)
├── border.luc           # Border.draw -> interior Rect
├── rows.luc             # Rows, RowsEvent
└── tests/
    ├── layout_test.luc
    ├── screen_test.luc
    └── rows_test.luc
```

`termui.luc` is the entry module and holds the vocabulary every
consumer needs; the rest are imported by name, because PACKAGES.md D2
is explicit that dots map to directories and nothing re-exports.

**`Border.draw(screen, area, title, style) -> Rect`** draws a box and
answers the interior — a deep function in §3's sense, since "draw a
box" is one line at the call and four clipped edges, a title clipped
to the top edge, and four corners inside. The junction-merging
compositor that `os.term.ui.junction` was built for — two panes
sharing an edge choosing `┬` over one overwriting the other — is
**deferred to v0.2** and named here so it is not quietly forgotten;
v0.1 draws the editor's shared edge the way the editor draws it now,
by asking for the junction explicitly.

No text field, no scrollbar, no tabs, no menu in v0.1: the editor does
not use them, and a widget without a customer is a guess.

## Ownership

Nothing new, and this section is a consequence rather than a design.

- `Screen` holds two arrays, so it is a **carrying struct**: the
  binding that received `Screen.of(...)` owns it, `let s = app.screen`
  aliases it (S26), and it dies with its owner. termui's surface
  contains no `give` and no `copy`.
- `Rect`, `Style`, `Cell`, `Mouse`, `Key` and every widget event are
  **values**: they copy, take no verbs, and cross a worker boundary
  freely. Layout arithmetic allocates nothing.
- `Rows` holds no container at all — it holds counters and a function
  value, and a function value never owns the objects inside it
  (BINDING's second run). So `Rows` is a **value struct**, and
  `let r = app.files` copies it. That is the payoff of refusing the
  owning bind, visible in the first library written after it.
- `Screen.resize` assigns fresh arrays over its fields; the old ones
  are released by that assignment, which is ordinary field
  replacement and not a new rule.

## What termui refuses, permanently

- **A framework that owns `main`** (D1).
- **A widget base type, a widget union, or dynamic dispatch** (D7).
- **Generic messages, a `ctx` parameter, or a callback registry** (D9)
  — each of them is the generics the owner has refused twice.
- **A theme or palette owned by the library** (D3).
- **A layout solver** (D4).
- **Any escape byte.** termui never writes one; the host owns them.

## Sequencing

Each step lands green on its own.

1. **The two compiler blockers this design's own prototype found**
   (below): `match` on a temporary, which is a wrong answer and
   critical on its own account — *fixed 2026-08-12*; and a function
   value not landing on a nested assignment target, which is the
   wiring line `rows.luc` needs. Neither blocks steps 2 and 3 —
   prototyping established that, which is why they are listed as
   blocking step 4 rather than everything.
2. **`std.strings`' character vocabulary** (D11), with the
   `pad_left`/`pad_right` correction and its specs. *Built
   2026-08-12*; `screen.write` is already its customer.
3. **`termui.luc` + `screen.luc` + `events.luc`**, with the package's
   `tests/` tree — the first `luce test` run inside a package. All
   three exist as a verified prototype.
4. **`border.luc` + `rows.luc`** — gated on step 1.
5. **The editor migrates** (task 20): `frame()` becomes splits and
   draws, `Intent.of` becomes a map, `Draw` mostly disappears, and the
   editor stops calling `term.clear()` every keystroke.
6. **loom embeds the dependency** — `MemoryLoader` serves termui's
   sources beside the editor's own as a static package set, which is
   PACKAGES.md's named requirement on step 3's resolution work and the
   proof that a vendored store can ride inside a binary.
7. **Docs and site**: `docs/STD.md` for the strings additions,
   loom.luciaos.com for `loom edit`'s new dependency, and this memo's
   as-built note.

## Findings from designing it

The design was not only probed but **prototyped**: `termui.luc`,
`screen.luc`, `events.luc` and `rows.luc` were written in full and
run, which is how the two findings that matter were found. Every
number quoted in D2 comes from that prototype.

- ✅ **`match` on a temporary gave a wrong answer; fixed 2026-08-12.**
  `match pane.move_by(5):` took the wrong arm with a zeroed payload —
  and the reduction is three lines: `match make():` where `make`
  answers `E.b(n = 42)` printed `a 0`. The MIR said exactly why: the
  temporary was stored into *two* slots, the first was
  `drop_storage`'d, and then the second — the same storage — was
  read. Binding it first (`let e = make()`) was correct, which is how
  it survived. UNION.md promises the opposite in as many words: *a
  temporary one lives to the end of the statement, and the `match` is
  the statement.* The cause was the statement-temporary ledger: both
  `04_semantics/statements.zig`'s match walks flushed the scrutinee's
  park immediately after recording the held slot, and
  `05_hir/lower.zig`'s `replayMatch` emitted that release before the
  dispatch. The park now stays open across the arms and flushes in
  the merge, so the release is once, from one slot, after every arm
  has read it — and an arm that leaves early releases it on its own
  way out, from the floor its `return`/`break`/`continue` records.
  **The oracle was not blind to it**, which this memo assumed and the
  fix disproved: the interpreter dereferenced the freed run and
  segfaulted, so any spec that had matched a temporary would have
  failed loudly. Nothing was asked. Six spec rows in
  `specs/union_spec.zig` and two in `specs/ownership_spec.zig` ask
  now.

Six further compiler facts were probed rather than assumed — real
files compiled by the installed toolchain and run. Four held, one is
a blocker, and one is ceremony the design has to live with.

- ✅ `array(Cell, r, c)` of a string-bearing value struct constructs
  zeroed, assigns and reads.
- ✅ Struct `==` compares plain value structs, so the diff is the
  language's own equality.
- ✅ A `(func(long) -> string)?` field holds a **borrowing bind of a
  carrying receiver** (`names.at` where `Names` owns a list), and
  calling through it after the list grew sees the new elements — S26's
  alias, exactly as BINDING promised.
- ❌ **A function value does not land on an assignment target more
  than one field deep.** `app.rows.render = plain` with a local `app`
  is accepted, and so is `self.render = plain`, but
  `self.rows.render = plain` and `slots[0].render = plain` are both
  refused with *"plain is a function; write plain(...) to call it, or
  annotate the place it goes"* — the expected type is not propagated
  through an assignment path that passes `self` or an index before its
  final field. It is not about binds: a plain function name fails the
  same way. `self.pane.render = self.names.at` is the canonical wiring
  line of this whole design, so this is step 1.

- ✅ A `Screen` may replace its own grids on resize — `self.back = new
  array(Cell, rows, columns)` releases the old one as ordinary field
  replacement, proved over two hundred resizes.
- ⚠️ **An enum cannot key a map** (D10), so a keymap pays `int(...)`
  per row. Both workarounds were probed and work; filed separately.

A sixth, minor: a field refused for its type makes its struct report
*"has an empty body"* as a second diagnostic, which is noise from a
failure already reported.

**And the memo's own samples were run through the checker**, which is
where two of the decisions above got their final shape. `union Event`
was first written `key(Key)`, and a payload field is named, always
(D5); `struct Rows` was first written with `render` last, and fields
with defaults come last, so the checker's complaint turned into the
better design — `render` first and required, because a pane with no
provider shows nothing. Neither was a typo. That is the whole argument
for checking a design memo's code: a design that cannot be written
down is not yet a design, and both of these were found before a line
of the package existed.
