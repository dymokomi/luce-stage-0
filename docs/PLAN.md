# Terminal plan

Where the loom terminal goes next, in order.  The north star stays
[LOOM.md](LOOM.md): the Fabric is a demand-driven DAG, Views demand
interfaces, and nothing recomputes merely because it exists.  "Realtime"
therefore means *re-demand after every change and recompute only what was
invalidated* — the Spool already gives us that — not a push engine or a
thread pool.

## Phase 1 — compute from the terminal

The terminal can build and wire texels but cannot yet make them compute.
These commands close that gap and are prerequisites for everything below.

- Done: `set NAME VALUE`, `eval NAME` (registry: concat, sum, upper),
  `pull OUTPUT`, and boundary texels — `keyboard` (line, count) and
  `mouse` (x, y, button) are ensured on open, and every line read commits
  a keyboard observation before dispatch.  Push refreshes boundary
  observations; demand pulls them — that is the whole reconciliation.
  The mouse cannot fire until raw-mode input arrives (Phase 2).
- `state NAME TYPE VALUE` / `tick` — create State/Delay texels via
  `loom/evaluation/state.h` and advance them with `TemporalRuntime`,
  so recurrence is visible in the terminal.

## Phase 2 — shell ergonomics

- `&&` and `;` between commands on one line: split into segments before
  word-splitting; `&&` stops the chain on the first failing command, `;`
  continues.  Quotes already group words and must also protect separators.
- History and line editing: raw-mode input, arrow-key history, and tab
  completion of command names, port names, and texel names.  Prior art:
  linenoise/replxx — a few hundred lines, no dependency needed.

## Phase 3 — the live DAG

Done — the engine is an explicit push/pull hybrid per
[EVALUATION.md](EVALUATION.md): commits and volatile observations produce
ChangeSets, the disposable FiberIndex turns them into a dirty closure,
the session's long-lived Spool advances past clean records, and
`watch OUTPUT` / `unwatch OUTPUT` re-demand dirty subscriptions after
every line, printing only outcomes that moved.  Push invalidates; pull
evaluates.
- `view prose|table NAME...` — build View texels with the existing
  `make_prose_view` / `make_table_view`, and render the focused View
  through `Shell::compose` after changes.  The terminal becomes the first
  real client of the trusted shell instead of growing a rival one.

## Phase 4 — concurrency where it earns its place

Threading enters for responsiveness, not throughput: keep the prompt
editable while evaluation runs or a Delay ticks on a clock.

- One evaluation worker beside the input thread.  The Store stays
  single-writer; each Spool stays thread-confined (it is a disposable
  cache); results cross back on a queue and print above the prompt.
- Parallel evaluation of independent subgraphs is a later optimization
  the architecture explicitly permits (batch, fuse, compile) — do it when
  a real workload is slow, not before.

## Phase 5 — demand roots beyond the session

From LOOM.md's demand-root taxonomy (one-shot and event-activated exist
by Phase 3; standing arrives with presented Views): durable **scheduled
demand** as visible demand Texels — schedule, retry and missed-occurrence
policy, budget, the output to demand — compiled into timer wake-ups with
stable occurrence identities, plus effect-intent identities so recovery
never repeats an external action.  The vision's proof criteria: a
scheduled job survives restart; an event-activated automation runs
without duplicating its effect.

## Borrowed ideas, and from where

ghostty is a terminal *emulator* — VT parsing, GPU renderers, PTY plumbing
— which is the layer our terminal runs inside, not the layer we are
building.  Worth taking: its thread separation (read/write/render maps to
our input/evaluate/print split), shell-integration semantic zones (prompt
vs command vs output regions, which is how watch output can interleave
cleanly with an editable prompt), and keybinding/config tables.  Not worth
taking: emulation and rendering internals.  For line editing the closer
prior art is linenoise/replxx; for structured shells, nushell.

## Non-goals for now

Terminal emulation, GPU or curses UI, an evaluator thread pool, push-based
recomputation, and any scheduler that runs work nobody demanded.
