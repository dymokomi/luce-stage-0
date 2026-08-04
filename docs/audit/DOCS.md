# Documentation audit — the sentences, both directions

Audited at `0a22b81` (merge of `refusal-tests`).  What was checked: every
prose claim in `site/content/**` (48 pages), `docs/*.md` (13 files),
`README.md`, `CLAUDE.md` and `AGENTS.md`, against the code and against a
freshly built toolchain — and the reverse, every feature in the code
checked for a place a reader could find it.

The 173 build-verified code samples were **not** the subject.  Sentences
were.

## What was run

```
./build.sh                       ok
zig build test                   Build Summary: 48/48 steps succeeded;
                                 944/944 tests passed
./site/build.sh --fast           48 pages, 173 samples verified
                                 (121 run, 22 trap, 5 raise, 23 refused, 2 shell)
                                 "every sample matches its page, every link resolves"
```

**944** is therefore the true count, and it is the number three
documents get wrong.

URL checks used the local `site/out`, not the live host.  Behavioural
claims were checked by running `build/luce` and `build/loom` over scratch
programs, not by reading alone.

## The answer

**Close, and not yet.**  This is a genuinely well-documented project —
better than most languages at this stage — and it is not a super
repository today, for one reason that runs through every finding below:
**nothing checks a sentence.**  The site checks its 173 samples and
fails the build on a wrong output, a dead link or a dead anchor, which
is why 24 of its 48 pages are clean on every claim I could test and why
a week of demolition left not one sentence describing a deleted engine.
But no check covers the prose *around* a sample, so `/std/files/` and
`/tour/host/` sit there telling readers that append, delete, rename,
directory listing, the clock, `sleep`, stderr, stdin and environment
access are "not built" — nine features that shipped, that the bundled
programs already use, and that two other pages on the same site
correctly announce.  A false negative is the expensive kind of wrong: it
does not cost a reader a search, it costs them the feature.  `docs/` has
no check at all, and it shows — three entry points give three different
test counts and none is right (it is 944), the trap-code count is wrong
in four places, `docs/V2.md` still calls the backend unable to lower
floats or structs, and `MISSING.md` contradicts its own body.  The
reference pages, meanwhile, are excellent: all 43 ownership situations in
order with stable anchors, all 18 trap codes, all 52 reserved names
byte-exact, all 26 methods, and zero invented features anywhere.  The
material is here and the judgement behind it is sound; what is missing is
the machinery that keeps it true.  Two small tests — one asserting the
reference names every builtin, one asserting it names every trap code —
plus a `docs/` index, a `CONTRIBUTING`, a `LICENSE`, and a README that
admits the documentation site exists, and the answer becomes yes.

---

# Part 1 — Ranked findings

Severity: **1** a reader acts on it and is wrong; **2** two documents
disagree, or a number drifted; **3** organization and reachability.

## Sev 1

### F1. The ABI-8 host expansion reached the compiler and three site pages missed it — two of them say the features do not exist

This is one event with three faces, and it is the worst finding in the
audit, because two of the three are not omissions but **active denials**
of shipped behaviour.  A reader is not left uninformed; they are told
"no" and will not try.

**(a) `/std/files/` documents 5 of 10 functions and denies the other 5.**

> "There is no append mode, no delete, no rename, no directory listing
> and no path manipulation.  There is also no standard input, no clock
> and no `sleep`.  Each of those is one host builtin plus one wrapper
> here, and **none of them is built**."
> — `site/content/std/files.md:121-124`

`src/luce/std/files.luc` defines `append_text`, `append_lines`,
`delete`, `rename` and `list`.  I compiled and ran all five:

```
$ build/loom run sf.lc
3
true
false
```

Only *path manipulation* is genuinely still missing.  The "surface"
table (`std/files.md:16-22`) lists `exists read write read_lines
write_lines` and stops, so semantics a caller needs are stated nowhere:
`rename` replaces an existing target (the whole point of
write-then-rename), `list` answers sorted plain names rather than paths,
and `delete` of an absent file answers `io_failed` rather than
succeeding quietly.

**(b) `/tour/host/` repeats the denial, nine features wide.**

> "There is no standard input, no clock, no `sleep`, no `exit`, no
> environment access, no stderr, no directory listing, no delete or
> rename, and no path manipulation.  Each is one builtin plus one
> wrapper, and **none of them is built yet**."
> — `site/content/tour/host.md:112-114`

Nine of the eleven shipped at ABI 8.  Only `exit` and path manipulation
remain.  The repository's own bundled programs contradict the page:
`programs/calc.luc:109,114` uses `read_line` and `print_error`, and
`programs/life.luc:92,100` uses `clock_ms` and `sleep_ms`.  The same page
also undercounts the raw builtins — "The host's raw file builtins are
`file_read`, `file_write` and `file_exists`" (`tour/host.md:37`) — where
there are seven.

**(c) `/ref/builtins/` omits nine host builtins.**

The **Host builtins** table (`site/content/ref/builtins.md:62-76`) has 15
rows; the analyzer has **24** host-gated builtins
(`src/luce/04_semantics/builder.zig:4234-4257`).  Missing:

```
read_line   print_error   clock_ms   sleep_ms   env
file_append file_delete   file_rename dir_list
```

All nine work; I ran a program using every one.  Four are fallible and
need `try`/`catch`, which a reader cannot guess from silence:

```
h.luc:9:13: dir_list can fail: write 'try dir_list(…)' to pass the error
on, or 'dir_list(…) catch …' to handle it [luce.sema.fallible]
```

**The site already knows, three times over.**  `/ref/lexical/:66-68`
reserves all nine names; `/status/:151-154` announces that "the clock,
`sleep`, environment access, stderr, reading a line, directory listing,
delete/rename and append mode all shipped with host ABI version 8"; and
`docs/STD.md:157-200` documents the `files` wrappers in full.  So the
information exists in the repository and in two site pages, and the three
pages a user actually consults to answer "can I do X" all say no.

### F2. `docs/V2.md` describes a backend that has not existed for a week

> "Finish code generation: the LLVM backend exists and covers the integer
> and String core, but not floats, structs, or the host services, and
> loom cannot yet load what it produces (docs/CODEGEN.md)."
> — `docs/V2.md:156-159`

Every clause is false.  The lowering is total (`CLAUDE.md:43`,
`docs/PIPELINE.md:45`), and `loom run FILE.lc` is one `dlopen`.  This
matters more than an ordinary stale line because `CLAUDE.md:27` names
V2.md "the north star" and `README.md:11` sends the reader there first —
it is the paragraph a newcomer reaches earliest and trusts most.

### F3. Three entry points, three wrong test counts

The suite passes at this commit.  Nobody says how large it is correctly:

| file:line | says | true |
|---|---|---|
| `README.md:28` | `zig build test     # 832 tests in ~4 min` | 944 |
| `CLAUDE.md:19` | `zig build test     # 892 tests in ~5 min` | 944 |
| `docs/ENGINE.md:28` | "**832/832 in ~4 min**, of which 536 are the executable specification" | 944 |

The ENGINE.md instance is the worst of the three: it sits inside a banner
headed "All nine steps are done, 2026-08-03", so it reads as a
freshly-verified current fact rather than a dated one.  The arithmetic is
visible in the log — `CLAUDE.md` was last touched at `63a1366`, and the
next commit added exactly 52 tests: 892 + 52 = 944.

### F4. `docs/MISSING.md` contradicts its own body, and miscounts the specs

Two separate defects in the one document that exists to be the honest
gap list:

> "Ten conceptual stages, eight folders, **four executable specs**"
> — `docs/MISSING.md:10-11`

There are **eight** (`src/luce/specs.zig` imports behavior, ownership,
errors, std, host, modules, optimizer, module_format).  `ENGINE.md:944`
already caught this exact error elsewhere; the fix never reached
MISSING.md.

> "speed: strings is the one benchmark row still well behind its C twin,
> and **small-string optimisation is the queued answer**"
> — `docs/MISSING.md:399-402`

330 lines earlier the same file says SSO shipped — "**small-string
optimisation took most of it back**" (`:69-73`) — and its own work order
marks it `~~done~~` (`:370-375`).  The closing summary is a wishlist
paragraph on a document whose body has moved past it.

### F5. `docs/ENGINE.md` states a stale `format_version` as a live fact

> "Today `.lc` is a direct binary serialization of verified MIR
> (`format_version` 16) and `.lcn` is the tagged native artifact beside
> it." — `docs/ENGINE.md:383-384`

The version is **17** (`src/luce/06_mir/module.zig:32`) and `.lcn` no
longer exists.  Most of ENGINE.md's present tense is explicitly framed as
history by its own preamble (`:33-42`) and is fine; this sentence opens
with "Today".

Worse, its doc-defect callout is itself the defect:

> "**`docs/MODES.md:103` says `format_version` 15.** It is 16
> (`06_mir/module.zig:23`). A doc defect found in passing."
> — `docs/ENGINE.md:503-504`

Stale three ways: the true value is 17, `MODES.md:105` now correctly says
17, and the code reference is `module.zig:32`.

## Sev 2

### F6. The `strings` benchmark row has four different current numbers

| file:line | claim |
|---|---|
| `README.md:70-72` | "`strings` is the one row still behind, at **2.31x**" |
| `CLAUDE.md:43` | "`strings` the one row still behind at **2.49×**" |
| `docs/STRINGS.md:1016` | "compute ratio **2.71× C → 2.68× C**" |
| `docs/CODEGEN.md:467` | `| strings | 2.5x | **1.73x** |` |
| `docs/CODEGEN.md:888` | `| strings | 20.6 ms | 47.4 ms | 2.31x | 2.49x |` |

The 2.31/2.49 pair is not a contradiction — they are the raw and
floor-subtracted columns of one table, and `/guide/performance/` prints
both correctly.  The problem is that the two *entry-point* documents pick
different columns for the same headline sentence without saying which,
while `CLAUDE.md:43` separately declares the compute column authoritative
("the one a code-generation change moves").  `CODEGEN.md` then
contradicts itself inside one file: `:467` and `:888` are both labelled
compute ratios for `strings` and differ by 0.76×, with the older figure
never marked superseded.

Pick one column, say which, and quote it everywhere.

### F7. The trap-code count is wrong in four places, three different ways

- `docs/FAILURE.md:25` — "Applied to the **21 codes** in
  `06_mir/defs.zig` … Eighteen stay traps."
- `docs/LANGUAGE.md:193` — "leaves **eighteen of the twenty** trap codes
  exactly where they were."
- `site/content/tour/failure.md:24` — "leaves eighteen of Luce's
  **twenty** trap codes exactly where they were."
- `site/content/guide/failure.md:34` — "Applying that rule to Luce's
  **twenty** trap codes left eighteen exactly where they were."

`mir.TrapCode` has **18** members (`src/luce/06_mir/defs.zig:220-238`)
and `/ref/failure/` correctly lists all 18 — so the site contradicts
itself between its tour, its guide and its reference.

The history also misattributes.  At `72fe8be^` the enum had twenty; the
trap-or-error rule removed exactly **one** (`file_read_failed`), leaving
nineteen.  The twentieth (`step_budget_exhausted`) went later, in
`16ed137` ("Cut Bytes, the evaluator ports, and the step budget"), which
had nothing to do with the rule.  The true sentence is: the rule left
nineteen of twenty where they were, and Luce now has eighteen.

### F8. `/ref/builtins/` states a rank restriction on `fill` that does not exist

> "| `fill(value)` | rank-1, **value elements only** |"
> — `site/content/ref/builtins.md:128`

`dim` and `fill` are dispatched *before* the rank gate
(`src/luce/04_semantics/builder.zig:3908-3930`), so `fill` works at any
rank.  Verified:

```
$ cat fl.luc
func main():
    var g = new Array(Int, 2, 3)
    g.fill(7)
    print(str(g[1, 2]))
$ build/loom run fl.lc
7
```

The "value elements only" half is correct.  Only `sort`, `reverse`,
`find` and `contains` are rank-1-only.  This is an error on a normative
page that will send a reader to write a loop they do not need.

### F9. `/std/strings/` calls a `String` an object

> "Both hand back fresh objects the receiver owns." — of `split` and
> `join`, `site/content/std/strings.md:91`

`join` returns a `String`, which the rest of the site correctly and
repeatedly insists is a **value, not an object**
(`tour/strings.md:3-5`, `tour/collections.md:3-4`, `/ref/types/:16-19`).
Only `split`'s `List(String)` is an object.  The value/object line is the
one distinction the whole memory model rests on, so blurring it in a
std page is worse than an ordinary slip.

### F10. `/std/math/`'s trig accuracy figure holds only to about `|x| < 1e4`

> "| `math.sin(x)`, `math.cos(x)`, `math.tan(x)` | radians, **any
> magnitude** |" … "the trigonometric functions to about **1e-12
> absolute**"
> — `site/content/std/math.md:26,29`

Range reduction is `r = x - floor(x / tau) * tau` in double precision
(`src/luce/std/math.luc:109`), so absolute error grows with `|x|`.
Measured against libm: 1e-14 at `x=1e3`, 1.4e-12 at 1e4, 6.8e-11 at 1e6,
1.3e-8 at 1e9, 8.0e-3 at 1e15.  "Any magnitude" is true of the *domain*,
but sitting in the same table as an accuracy claim it reads as a
guarantee.  The same sentence is in the `math.luc` header (`:5-7`), so it
is one fix in two places.

### F11. "Eight folders" is seven

`docs/PIPELINE.md:47` and `docs/MISSING.md:10` both say "Ten conceptual
stages, eight folders."  There are **seven** stage directories —
`01_source 02_lex 03_parse 04_semantics 06_mir 07_optimize 08_llvm`.
Stage 5 is `05_hir.zig`, a barrel file with no directory, which
PIPELINE.md's own table row says in as many words.  The tree diagram at
`PIPELINE.md:16` and `AGENTS.md:5` both draw it as `05_hir/` with a
directory slash.

### F12. `CLAUDE.md`'s map of `src/apps/loom/` names two files that are not there

> "**`src/apps/loom/`** — `main.zig` (dispatch), `shell.zig` …,
> `runner.zig` …, `host.zig` (the real host…), `key.zig`
> (escape-sequence decoding), `palette.zig`" — `CLAUDE.md:61`

`src/apps/loom/` holds `main.zig palette.zig product.zig runner.zig
shell.zig`.  `host.zig` and `key.zig` live one level up at `src/apps/`,
shared with the compiler; `product.zig` is unmentioned.  An agent told to
edit "loom's host" looks in the wrong directory.

### F13. The status page's corpus counts are half-drifted, on a page that swears they are not

> "The corpus pays for it constantly, and **the counts are real**"
> — `site/content/status/index.md:107`

Re-derived against `programs/`:

| claim | file:line | actual |
|---|---|---|
| "**17 string comparisons** and no `else`" | `status/index.md:109` | **15** (`editor.luc:361-400`) |
| "**46** `word == "…"` comparisons" | `status/index.md:114` | **46** ✓ |
| "**87** `Struct.func(state, …)` calls" | `status/index.md` §3 | **88** — near enough |
| "`term_style(fg, bg, bold)` is called **16 times** and **13** of them end in … `false`" | `status/index.md:145` | **12** and **11** in `editor.luc`; **15** and **14** across `programs/` |

Two of four are right, which is better than it sounds and worse than the
page promises.  `site/content/examples/programs.md:124-126` carries the
same "seventeen string comparisons" figure, so that one is a single edit
in two places — and it adds a second error, "with no `else`", where
`editor.luc:402` has one.  The same four numbers appear in
`docs/MISSING.md`
(`:182-183`, `:187-188`, `:209-210`, `:262-263`) — they drifted in
lockstep, which means one was copied from the other rather than
re-derived.  `MISSING.md`'s line references have drifted further still
(`editor.luc:127`→129, `wordcount.luc:23`→25, `:33`→35, `:58`→62,
`editor.luc:187`→189).

### F14. `docs/OWNERSHIP.md` S9 contradicts itself in two lines

> "**S9. An alias after the owner is gone traps at use — in safe
> builds.**" … "`# RUNTIME trap: use_after_free (safe builds)`"
> — `docs/OWNERSHIP.md:134-139`

Then immediately:

> "There is no build mode that omits it: docs/MODES.md settles that Luce
> is always ReleaseSafe" — `:143-145`

"In safe builds" is residue from an era with an unsafe one, and it is the
headline — the part quoted elsewhere.  The site fixed this: `/ref/ownership/#s9`
reads "an alias used after the owner is gone traps at use", full stop.

### F15. `MISSING.md` calls a shipped method unbuilt

> "`m.get(k) -> V?` is the answer and **is not built**"
> — `docs/MISSING.md:152-154`, repeated `:385` and `FAILURE.md:308`

`Map.get(key, default) -> V` **is** built
(`src/luce/04_semantics/builder.zig:3956`), specced, and documented on
`/ref/builtins/`.  Only the `V?`-returning overload is absent.  As
written, a reader concludes `get` does not exist.

## Sev 3

### F16. Three smaller site-prose slips

- **`/std/strings/:154-155`** — "`find` also returns `-1` for an
  *argument* error".  `strings.find(s, needle)` is `find_from(s, needle,
  0)` (`strings.luc:41-42`), and `start = 0` can never fail the
  `start < 0 or start > size` guard.  Only `find_from` can.  The point
  being made is right and attached to the wrong function.
- **`/std/strings/:112-116`** — `format_float` is described as
  unconditional fixed-point.  It **traps** on `decimals < 0`
  (`strings.luc:180-181`) and falls back to `str(value)` above `|value| >
  1e15` (`:186-187`), so `format_float(1.0e20, 2)` prints
  `100000000000000000000`.  On a page whose own "The one sentinel"
  section is about honesty at the edges, the trap should be stated.
- **`/examples/programs/:39-43`** and **`/examples/errors/:125-129`**
  describe `programs/calc.luc` as a one-shot expression evaluator.  Since
  `7bff37d` it is a REPL when given no arguments (`calc.luc:105-118`),
  driven by `read_line` and `print_error` — the very builtins
  `/tour/host/` says do not exist (**F1b**).  `/examples/programs/:110`
  likewise omits that `life.luc` now animates with `clock_ms`/`sleep_ms`.

These three, plus F1, all trace to the same commit.  A host-surface
change landed in the compiler, the std library, `docs/STD.md` and
`programs/`, and stopped short of five site pages.

### F17. `docs/` has no index, and the README names 6 of 13 files

There is no `docs/README.md` and no table of contents anywhere.
`README.md` links `V2 LANGUAGE OWNERSHIP PIPELINE MODES CODEGEN` — and
never mentions **ENGINE, FAILURE, MEMORY, MISSING, STD, STRINGS,
CODING_GUIDE**.  `MISSING.md`, the file a newcomer most wants, is
referenced only from inside four other docs and from neither README,
CLAUDE.md nor AGENTS.md; it is reachable only by listing the directory.

A reader also cannot tell a frozen decision record from a live reference
without reading forty lines of preamble — `ENGINE.md` is a memo written
in the present tense about a world that no longer exists, and
`PIPELINE.md` is current status, and they look identical from the
directory listing.

### F18. Nothing in the repository mentions the documentation site

`luce.luciaos.com` appears exactly once outside `site/` — in
`CLAUDE.md:65`.  Not in `README.md`, not in any `docs/*.md`, not in
`AGENTS.md`.  The README's **Packages** block (`:136-165`) lists
`src/luce`, `src/apps/*`, `programs/`, `bench/`, `tools/vscode-luce/`,
`docs/`, `build.sh` — and omits `site/` entirely, though it is a
first-class deliverable with its own build gate.

The link works in the other direction: the generated footer
(`site/src/page.zig:119`) points back at the GitHub repo.  Only the
repo→site edge is missing, and it is the one a cloner needs.

### F19. No `CONTRIBUTING`, no `LICENSE`, and two agent files that disagree

- No `CONTRIBUTING.md`.  The rules exist — they are spread across
  `CLAUDE.md` (commit author, workflow), `AGENTS.md` (commit style) and
  `docs/CODING_GUIDE.md` (the actual conventions) — but a human is never
  pointed at them; `README.md` never names `CODING_GUIDE.md`.
- No `LICENSE` file at all, on a repo whose site is public.
- `AGENTS.md` and `CLAUDE.md` overlap heavily and have already drifted:
  `CLAUDE.md:21` says `zig fmt src/ build.zig site/src/`; `AGENTS.md:13`
  says `zig fmt src/ build.zig` — following AGENTS.md leaves `site/src/`
  unformatted.  `AGENTS.md:27` still offers a deleted subsystem as the
  model commit subject: "often scope-led (`Benchmarks: ...`, **`WASM
  backend M3: ...`**)".  `AGENTS.md` never mentions `site/`.

### F20. `tools/vscode-luce/` ships a v1 grammar

The status page discloses this honestly — "There **is** a VS Code syntax
definition in the repository, and it is stale — it still lists builtins
from a removed era" (`status/index.md:262-264`) — and it is true.  The
grammar highlights `create_image`, `create_texel`, `texel_content`,
`texel_evaluator`, `texel_input`, `texel_output`, `texel_set`,
`read_file`, `port`, `schema`, `entrypoint`: Fabric-era names, none of
which the compiler has accepted since v1.  It knows none of the 24 host
builtins, and none of `try catch none give copy`.  Honest disclosure is
not a fix for a shipped tool; either update it or stop shipping it.

---

# Part 2 — Coverage, the reverse direction

Inventory built from the code, then checked for a findable home on the
site.

| surface | in code | documented | where |
|---|---|---|---|
| Pure builtins | 17 | **17** (100%) | `/ref/builtins/` |
| Host builtins | 24 | **15** (63%) | `/ref/builtins/` — **F1c** |
| Container/String methods | 26 | **26** (100%) | `/ref/builtins/`; one wrong (**F8**) |
| Trap codes | 18 | **18** (100%) | `/ref/failure/` |
| Error codes | 2 | **2** (100%) | `/ref/failure/` |
| Reserved names | 52 | **52** (100%) | `/ref/lexical/` — exact match, in order |
| Ownership situations | 43 | **43** (100%) | `/ref/ownership/`, anchors `#s1`–`#s43` |
| Keywords | 25 | **25** (100%) | `/ref/lexical/` |
| Precedence levels | 6 + prefix/postfix | **8 rows** (100%) | `/ref/expressions/` |
| `luce` subcommands | 3 | **3** (100%) | `/guide/toolchain/` |
| `luce` flags | 4 (`-o --release --emit --full`) | **4** (100%) | `/guide/toolchain/` |
| `loom` CLI forms | 4 + bare | **5** (100%) | `/guide/toolchain/` |
| Exit codes | 5 | **5** (100%) | `/guide/toolchain/` |
| std modules | 3 | **3** (100%) | `/std/` |
| std functions | 53 | **45** (85%) | `/std/*` — see below |
| std constants | 5 | **3** (60%) | `/std/math/` — `ln2`, `ln10` absent |
| Diagnostic codes | 59 | **21** (36%) | scattered |
| Host ABI slots | 28 (2 required) | 0 — correctly internal | — |

Methods by receiver: List 9, Map 6, Array 6, Builder 3, String 2 — all 26
documented, none phantom, one described wrongly (**F8**).

### std, module by module

| module | in `.luc` | on site | absent |
|---|---|---|---|
| `math` | 25 | 24 | `random_step` |
| `strings` | 18 | 16 | `is_space_byte`, `fold_case` |
| `files` | 10 | **5** | `append_text`, `append_lines`, `delete`, `rename`, `list` (**F1a**) |

The `strings` pair is defensible — `is_space_byte` and `fold_case` are
exactly the two internal helpers `MISSING.md` flags under "no
visibility", so documenting them would advertise a leak rather than an
API.  `random_step` is a genuine omission from an otherwise complete
page.  `files` is the finding.

Two undocumented *behaviours* worth one line each: `strings.find` and
`find_from` treat an **empty needle as a match at `start`**, while
`strings.count` counts an empty needle as **zero** — two different
answers to the same question.

**Zero phantom features.** Not one builtin, method, trap code, keyword or
diagnostic code named on the site is absent from the compiler.  The
site never invents.

But the mirror image is not clean.  The site's characteristic failure is
the **false negative** — naming a shipped feature as unbuilt (**F1a**,
**F1b**), or attaching a restriction that is not there (**F8**, **F10**).
That is the more damaging direction of the two: a missing table row costs
a reader a search, while "none of them is built" costs them the feature.

### The diagnostics fraction, and whether it matters

59 stable codes are emitted; the site names 21.  It should not name all
59 — most are ordinary "expected X, found Y" parse errors whose message
is the documentation.  But the 38 unnamed include several a user will
certainly hit and may want to search for:

```
luce.sema.main        wrong or missing entry point
luce.sema.reserved    you named a variable `len`
luce.lex.tab          you indented with a tab
luce.lex.indent       your indentation is not four spaces
luce.import.missing   the sibling file is not there
```

`/ref/lexical/` explains the tab and four-space rules in prose without
ever naming `luce.lex.tab` or `luce.lex.indent`, so a user who pastes the
code into a search box finds nothing.  The cheap fix is not 38 new
sections — it is naming the code beside the rule that raises it, which
the page already does for `luce.lex.number`.

### Documented-but-gone

None found on the site.  In `docs/`: `.lcn` (`ENGINE.md:383`),
`format_version` 16 (same line), `backend.Host` (`ENGINE.md:55,489` —
now `interpreter.Host`), and `m.get` described as unbuilt (**F15**).

---

# Part 3 — docs/*.md internal coherence

The thirteen decision records are individually strong and collectively
unmaintained.  There is no mechanism that would notice any of the above —
the site fails its build on a wrong claim; `docs/` fails nothing.

**What holds up.** `PIPELINE.md`'s status table maps one-to-one onto the
stage folders, every row's prose matches the code, and its "Not stages"
table matches `compile/ runtime/ interpreter/ support/ std/ specs/`
exactly.  `MODES.md` is correct throughout including `format_version` 17.
`CODING_GUIDE.md` matches the code it governs.  `OWNERSHIP.md` carries
all 43 situations with the wording the site derives from.

**What does not.** The stale numbers in F3/F5/F7/F11; the internal
contradictions in F4/F6/F14; the dangling cross-reference at
`LANGUAGE.md:548` ("docs/MISSING.md tier 2, item 13" — Tier 2 is sum
types and has no numbered items; the match is Tier 3 item 11); and
`OWNERSHIP.md`'s situations running out of numeric order (S32 → S36, S37,
S38, S40, S39, S41, S42, S43, then S33, S34, S35).  The site page
presents the same 43 in order, so the *derived* document is better
organized than its source.

**MISSING.md, specifically.** Asked whether it is still the honest gap
list: **yes on the gaps, no on the evidence.**  Every gap I checked is
still real — no sets, no character classes in std, no receivers, no
multiple returns, no comparator sort, no default arguments, no `//`, no
visibility, no bitwise/hex/separators, no codepoint iteration, stage 5
unwritten, no `fmt`/`test`/LSP/debugger, seven `trap(` left in
`std/math.luc`.  What has rotted is everything that makes the gaps
*credible*: the spec count (F4), the SSO summary (F4), `m.get` (F15), and
essentially every line reference and corpus count (F13).  Two known
backend gaps — cross-compilation and a shared `libluce_rt` — are named in
`CODEGEN.md` and folded into Tier 0's tail but never reach the ordered
work list, so the two largest items have no scheduled position.

A gap list whose numbers cannot be trusted is still useful and is no
longer *authoritative*, which is the thing it was for.

---

# Part 4 — The contributor path

A fresh-eyes walk from `git clone`.  Where I got lost is recorded, not
smoothed over.

**1. Build.** `README.md:20-30` is accurate and honest about
prerequisites: Zig 0.16, LLVM as a build prerequisite of `luce` only,
`cc` for linking.  `./build.sh` worked first time.

*Lost here:* the README offers `brew install llvm` / `apt install
llvm-dev` / `-Dllvm-config=PATH` and never mentions `vendor-llvm.sh`,
which sits in the repository root and builds a pinned LLVM from source —
the supported answer when the system LLVM is wrong.  Its own header is
excellent and `build.zig:434` names it in an error message, so the script
is discoverable *after* you fail.  The README should name it before.

**2. Test.** `zig build test` passed.  The README says 832 tests, which
is wrong by 112 (**F3**).  A contributor whose run prints a different
number cannot tell whether they broke something.

**3. Run a program.** `README.md:34-38` works verbatim:

```
$ build/luce build programs/hello.luc
programs/hello.luc -> programs/hello.lc
$ build/loom run programs/hello.lc you
hello, you
```

`--emit=exe` works verbatim too.  Exit codes match the documented table
exactly — trap 1, uncaught error 3, missing file 1, duplicate `-o`
refused with `luce: -o was given twice`.  This section is the best part
of the README.

**4. Find the language spec.** `README.md:13` points at
`docs/LANGUAGE.md`.  It never points at `luce.luciaos.com` (**F18**),
which is a far better answer — a tour, worked examples, and a reference
with 173 verified samples.  A contributor who does not read `CLAUDE.md`
never learns it exists.

**5. Find the coding rules.** *Lost here.* `README.md` never names
`docs/CODING_GUIDE.md`.  I found it by listing `docs/`.  It is
authoritative, it is good, and it is invisible from the front door.

**6. Make a first change and know where its test goes.**  The rule is
crisp and stated twice — "anything that runs a Luce program is a
specification and lives in `specs/`; anything that inspects a structure
lives beside the code it proves" (`CLAUDE.md:23`, `AGENTS.md:23`).  It is
in neither the README nor `CODING_GUIDE.md`, so a human contributor who
does not open the agent files never sees it.  The two registration steps
that silently skip your tests — adding to `src/luce/luce.zig`'s test
block and `src/luce/specs.zig`'s — are likewise agent-file-only.

**7. Navigate `docs/`.** *Lost here, worst of all.*  Thirteen files, no
index, no ordering, no indication of which are frozen (**F17**).

### What Zig, Rust and Go give a first-timer that this does not

| they have | here |
|---|---|
| `CONTRIBUTING.md` at the root | absent — rules exist, scattered across three files |
| `LICENSE` | absent |
| A docs index (`docs/README.md`, rustc-dev-guide's SUMMARY) | absent |
| An architecture overview aimed at humans | `CLAUDE.md`, aimed at agents; the README's Packages block is the closest |
| A link from repo to docs site | absent (**F18**) |
| "Good first issue" or an ordered work list | closest is `MISSING.md`'s work order — unlinked, and its numbers have drifted |

None of these is large.  A `docs/README.md` with one line per file, a
`CONTRIBUTING.md` that is mostly links, a `LICENSE`, and four lines in
the README pointing at the site, the coding guide and `vendor-llvm.sh`
would close the whole column.

### CLAUDE.md vs README.md

They do not contradict each other on substance — both describe one
engine, machine-code `.lc`, no fallback.  They differ on the test count
(892 vs 832, both wrong), on which benchmark column is the headline
(**F6**), and in reach: `CLAUDE.md` is current, detailed and correct
almost everywhere, while `README.md` is a commit or two behind on every
number it shares.  `CLAUDE.md` serves agents well.  `README.md` does not
yet serve humans as well, mostly by omission — the site, the coding
guide, `MISSING.md` and `site/` itself are all absent from it.

`AGENTS.md` is the odd file out: a third overlapping description with its
own drift (**F19**).  Either it should be a stub pointing at `CLAUDE.md`,
or the two should be generated from one source.

---

# Part 5 — The site's ops story

**There is no `site/README.md`**, and no page documents how to build or
deploy the site.  What exists instead is better than nothing and better
than most: both scripts carry real header comments.

`site/build.sh:1-11` explains the ordering and the `--fast` escape, and
matches its behaviour exactly — I ran `./site/build.sh --fast` and it
built the toolchain check, the generator, ran the generator's own 18
tests, and emitted 48 pages with 173 samples verified.  `site/deploy.sh:1-9`
documents build-from-clean-first with a `--fast` override, names its three
environment overrides (`LUCE_SITE_HOST`, `LUCE_SITE_KEY`,
`LUCE_SITE_ROOT`), refuses to publish an unbuilt tree, and curls the live
URL afterwards.  Both are accurate.

What is missing is the *pointer*.  `CLAUDE.md:65` is the only place in the
repository that says the site exists, how it is built, or where it is
deployed.  `README.md` and `AGENTS.md` say nothing.  A contributor who
edits `site/content/ref/types.md` has no way to learn there is a build
that will check their claim.

The one thing genuinely undocumented anywhere: the deploy target is a
hard-coded IP (`ubuntu@35.153.110.211`) served by Caddy, with no note of
who owns it, where the Caddy config lives, or what to do when it moves.

Recommended: a short `site/README.md` — what the generator is, the fence
vocabulary (`run`/`trap`/`raise`/`fail`/`module`), how to add a page, how
to run just the site build, and where it deploys — plus one line in the
root README naming `luce.luciaos.com` and `site/`.

---

# Part 6 — What is clean

Worth recording, because the list is long and the audit above is not
representative of the whole.

- **The site is free of deleted machinery.**  Greps across all 48 pages
  for `LOOM_ENGINE`, `LOOM_IMAGE`, `.lci`, `luce wasm`, WASM, Fabric,
  Texel, `native_spec`, `evaluate(`, Port schema, `allow_fabric`, `Bytes`,
  the hand-written emitters and the MIR JIT return **nothing**.  A week of
  demolition and not one sentence was left behind.  `docs/` is nearly as
  clean — the surviving mentions in `ENGINE.md` are explicitly framed as
  the history the memo was written about.
- **`/ref/lexical/`'s reserved-name list is byte-exact** against
  `04_semantics/declarations.zig:49-61`, all 52, in the same order — and
  correctly omits the `term_*` names, which genuinely are not reserved.
- **`/ref/ownership/` is in better shape than `docs/OWNERSHIP.md`**: all
  43 situations, in numeric order, each with a stable `#sNN` anchor the
  compiler's `[OWNERSHIP.md S21]` diagnostics point at.  I checked the
  anchors and headings one by one.
- **`/ref/failure/`** lists all 18 trap codes with correct messages and
  both error codes, and the call-depth-is-policy claim is true
  (`abi.default_call_depth = 256`, trapped at the call).
- **Limits check out**: 64 MiB source and `file_read` ceiling
  (`host.zig:900`), 100 diagnostics per stage
  (`declarations.zig:46`), 64 trace frames (`runtime/trace.zig:101`), at
  most 4 index dimensions (`builder.zig:1970`).
- **`/guide/toolchain/`** matches the binaries on every point I tested:
  the three `--emit` shapes, the artifact tag, the exit table, the
  two-mode story, `LUCE_CC`/`LUCE_LIB`.
- **`/status/`** is the most honest page in the tree.  It records a
  prediction the repository got wrong ("Small-string optimisation was
  predicted to remove 'essentially all' … It removed roughly three
  quarters"), discloses its own stale VS Code extension, and separates
  "deliberately absent, permanently" from "absent and not decided"
  without rounding up.  Its only defect is F13.
- **Zero phantom documentation.**  Nothing on the site describes a
  feature the compiler does not have.
- **Twenty-four site pages verified clean** on every checkable claim:
  all of `tour/` except `host.md` (`index values control functions
  ownership strings absence modules next`), all of `examples/` except
  `programs.md` and `errors.md` (`index hello loops maps lists structs
  text optionals traps files ownership`), `std/index.md`, and
  `guide/index.md`, `guide/memory.md`, `guide/strings.md`.
- **Spot-checked and correct**, in case they read as suspicious: stable
  O(n log n) sort (`containers.zig:233`, `std.sort.block`); Map O(1) for
  index/`has`/`get`/index-set and *not* for `remove`, which the pages
  correctly never claim; the 22-byte SSO threshold (`value.zig:81`);
  exactly four string escapes; five `Float?` reductions and seven
  remaining `std.math` traps, both counts exact; `T?` refused as a list
  element; `catch:` refused on a `let`; `editor.luc` embedded in `loom`.

---

# The short list

Twelve changes close everything above that matters.

1. **The ABI-8 sweep** (**F1**): rewrite `/std/files/`'s surface table and
   its "What is missing"; rewrite `/tour/host/`'s missing-list and its
   raw-builtin list; add nine rows to `/ref/builtins/`.  One commit, five
   pages, and it is the highest-value edit in this document.
2. Rewrite `docs/V2.md`'s roadmap item 5 (**F2**).
3. Fix the test count in `README.md`, `CLAUDE.md`, `ENGINE.md` — it is
   **944** (**F3**).
4. Fix MISSING.md's spec count and closing summary (**F4**), and `m.get`
   (**F15**).
5. Fix `ENGINE.md:383` and `:503` (**F5**).
6. Pick one benchmark column, say which, quote it everywhere (**F6**).
7. Fix the trap-code count in four places — it is **18** (**F7**) — and
   "eight folders" (**F11**).
8. Fix `fill`'s rank claim (**F8**), `join`'s return (**F9**), the trig
   accuracy caveat (**F10**), and the three slips in **F16**.
9. Fix `CLAUDE.md`'s `src/apps/loom/` map (**F12**), and drop "in safe
   builds" from OWNERSHIP.md S9 (**F14**).
10. Re-derive the corpus counts on `/status/`, `/examples/programs/` and
    in MISSING.md — and consider generating them (**F13**).
11. Add `docs/README.md`, a `CONTRIBUTING.md`, a `LICENSE`, and README
    lines naming the site, `CODING_GUIDE.md` and `vendor-llvm.sh`
    (**F17**, **F18**, **F19**).
12. Add `site/README.md` (**Part 5**), and either fix or stop shipping
    `tools/vscode-luce/` (**F20**).

The deeper fix is structural, and the audit points at it twice.

`docs/` needs the thing `site/` already has — a build that fails when a
sentence stops being true.  Test counts, version constants, trap-code
counts and benchmark rows are all mechanically checkable, and every one
of them drifted this week.

And the site needs one check it does not have.  Its build proves every
sample *runs*; nothing proves the prose around a sample is still true, so
a page can say "none of them is built" beside a working example forever.
The two cheapest additions would have caught most of F1 and F7 on their
own: a test asserting that `/ref/builtins/` names every row of the
analyzer's builtin table, and one asserting that `/ref/failure/` names
every `TrapCode`.  Both are a dozen lines against tables the compiler
already exports, and both turn the largest class of finding in this
document into a build error.
