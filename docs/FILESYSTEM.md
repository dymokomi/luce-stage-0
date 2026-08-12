# The filesystem surface — what a path is, what a file is, and what is missing

**Status: PROPOSED.**  Nothing here is built.  Every fenced block is
```` ```text ````, because a design memo's examples are the design's
and not the build's — though every shape below was written into a real
`.luc` and run against the installed toolchain before it was written
down here, and the memo says so wherever that changed a decision.

Two std modules and nine host builtins are the whole of what a Luce
program knows about a file system today.  They were built one
customer at a time — `files.read` for the editor, the byte channel for
`std.zip`, `dir_create` for zipper — and each addition was right on its
own.  What has never been decided in one sitting is the shape of the
whole: **what a path is, what a file is, and which question a program
is allowed to ask about a name before it touches it.**  The first
consumers that need the answer are one run away — `luce install`
laying out a store, a build tool, the registry's server side, and
`examples/zipper` already — and every one of them wants the same thing
the language cannot say: *is there a directory here, or a file, or
nothing at all?*

This memo decides that, and takes the two adjacent decisions it cannot
honestly leave open: whether `paths` and `files` are the right two
modules, and whether a `Path` value type should exist.

Version numbers below are of 2026-08-11: `abi.version` 16,
`format_version` 41.

---

## The evidence, measured

Everything in this section was run, not reasoned.

**1. `files.exists` answers a question its name does not ask.**
`files.exists(p)` is `file_exists(p)`, which is `Dir.cwd().openFile(io,
path, .{})` — and Zig 0.16's `OpenFileOptions.allow_directory`
defaults to `true`.  So it opens directories and answers `true` for
them:

```text
files.exists("probe/sub")        # true  — a directory
files.exists("probe/note.txt")   # true  — a file
files.exists("probe/nope")       # false
```

It has always meant *there is an entry at this name*, and nothing —
not the doc comment in `files.luc`, not the row in `docs/STD.md`,
not `abi.FileExistsFn` — says so.  The two live callers rely on the
undocumented meaning: `examples/zipper/zipper.luc:116` writes `if not
files.exists(into)` where `into` must be a **directory**, and gets the
answer it wants by accident.  Hand it a *file* and zipper proceeds,
then fails on the first `make_directory` with `io_failed`.

**2. It also lies in the other direction.**  A file that certainly
exists, under a directory that refuses to be opened:

```text
$ chmod 000 locked
files.exists("locked/inside.txt")   # false
```

`false` here does not mean "nothing is there".  It means "I was not
allowed to look", and the bool has no room to say so.  This is the
same shape `docs/FAILURE.md` refused for `key_read` — an in-band
answer a loop falls past, leaving the bug writable — decided the other
way by default rather than on purpose.

**3. There is no way to ask what kind of thing is at a path.**  No
`is_directory`, no `kind`, nothing in `paths`, nothing in `files`,
no host slot.  A program can only find out by trying:
`files.read("probe/sub")` raises `io_failed` with *"cannot read
probe/sub"*, which is the answer to a different question and arrives
too late to change what the program does.

**4. `files.list` answers names with no kinds**, so a recursive walk
is not writable.  `list(path) -> list(string)!` sorted, no `.`, no
`..`.  To walk, a program must open every entry and infer the kind
from the failure — a syscall per entry *and* a conflation of "it is a
directory" with "the disk is broken".

**5. The flagship example is paying for it now.**
`examples/editor/editor.luc:492` fills its file pane with
`files.list(".")`; `open_selected` (line 518) calls `files.read` on
whatever is selected.  Selecting a subdirectory in the editor's own
file pane produces `cannot read src` in the status bar and no way
forward.  The pane cannot even mark a directory with a trailing `/`,
because it does not know.

**6. The host already has the kind and throws it away.**
`host.zig`'s `loadDirectory` iterates with `std.Io.Dir.Iterator`,
whose `Entry` is `{ name, kind, inode }`, and appends **only
`entry.name`** to the NUL-joined buffer.  The information a walk needs
has been measured by the operating system, handed to loom, and
discarded, once per entry, since `dir_list` was written.

**7. `dir_create` (ABI 16) removed one reason to ask and not the
others.**  It is idempotent and makes parents precisely so that no
caller writes `if not files.exists(p)` in front of it
(`docs/MISSING.md`, `abi.DirCreateFn`).  That argument closes the
*guard* use of `exists`.  It says nothing about the walk, the pane,
or the "is this a directory" question, which are not guards — they are
the program's actual subject.

**8. `p.base()` does not work, and the diagnostic sends you to the
wrong module.**  Value-method sugar on a `string` routes by name
construction into `std.strings` alone (`04_semantics/calls.zig`'s
`stringsCall`).  With `import std.paths` in scope:

```text
p.base()
# luce.sema.import: string manipulation lives in the standard library:
#                   import std.strings to use base (docs/STD.md)
```

Take that advice and you get *"string has no method base, and neither
has the strings module"*.  Path spellings are free functions —
`paths.base(p)` — and only free functions.  This matters below,
because it is the strongest thing anyone can say for a `Path` type.

---

## The neighbours

**Go** splits exactly where this tree does: `path`/`filepath` are pure
text, `os` touches the world, and `os.Stat` answers `(FileInfo,
error)` — the two-outcome shape, with `os.IsNotExist(err)` as the
convention that tells the outcomes apart.  `fs.ReadDir` answers
`[]DirEntry`, each carrying `IsDir()`, and it *replaced* the older
`Readdir` for that reason.

**Rust** has `Path`/`PathBuf` as real types — and it has them because
`OsStr` is not `String` on Windows, which is a problem Luce does not
have.  Its lesson for us is the other one: `Path::exists()` returns a
bare `bool` and swallows the error, and the standard library added
`try_exists() -> io::Result<bool>` in 1.63 **because the swallowing
was a bug source**.  `DirEntry::file_type()` is documented as
requiring no syscall on most platforms.

**Python** has `pathlib.Path`, the strongest case for a path object in
any mainstream language, and `os.scandir` (PEP 471), which exists
because `listdir` + `stat`-per-entry was the measured bottleneck —
`os.walk` got 2–20× faster when it moved.  PEP 471 is the direct
precedent for the listing question below, and it went the way of
carrying kinds.

**Zig** exposes eleven `File.Kind` members (`block_device`,
`whiteout`, `door`, `event_port`, …).  Nobody's *language* should:
Rust, Go and Python each expose three distinctions to ordinary code
and keep the rest behind a platform-specific door.

---

## Decisions

| | decision |
|---|---|
| **D1** | **The `paths`/`files` boundary is right, and the principle is: `paths` is the *name*, `files` is the *world*.**  A function belongs in `paths` if and only if it can be answered from the characters of the string, with no host in the room.  That is why `paths` needs no host gate, can fail on no input, traps on none, works in a program compiled with `allow_host` off, and is testable with no file system.  It is why **`exists` is not in `paths` however well it would read there**: asking is touching.  The cost is that the boundary must be policed in the one direction it will be pushed — a `paths.absolute(p)` that resolves against the current directory, or a `paths.clean` that consults a symlink, would put the world into the name module and take that whole paragraph away.  Neither is offered here. |
| **D2** | **No `Path` value type.  Refused.**  §69, honestly applied: a `Path` wrapping a `string` hides *no* representation, because the representation must stay a `string` at every boundary — `args`, `luce.yaml`, `dir_list`, `file_open`, every diagnostic, every error message.  So it buys one thing (method sugar, D8 below) and charges a `Path(s)`/`string(p)` conversion at every one of those boundaries, plus a second vocabulary for the same concept (§62), plus a type whose constructor validates nothing — because D1 has already decided `paths` normalizes nothing, so there is no invariant for a validated constructor to hold.  §3's list of things not to create names it twice: "one-line wrapper" and "tiny types that force readers to jump between files without hiding information".  Rust's `Path` earns its keep on a problem (`OsStr` ≠ `String`) Luce does not have; Python's `pathlib` earns its on operator overloading and 40 methods, neither of which is on offer here. |
| **D3** | **`Kind` is an enum in `std.files` with three members: `file`, `directory`, `other`.**  Three because that is the set Go, Rust and Python each expose and the set a program branches on: recurse, read, or leave alone.  `other` is honest and total — a socket, a device, a fifo, a filesystem that will not say — and it is one member rather than seven because a program that needs to tell a block device from a door is writing an operating system and not using one.  A member added later is a compile error at every `match` that missed it (`docs/ENUMS.md` R1), so the set reopens as a superset and costs nothing to keep small now. |
| **D4** | **The question is `files.kind(path) -> Kind?!`, and that one signature is the whole answer.**  `none` means *nothing is there* — the same reason every time, no message worth carrying, `docs/FAILURE.md`'s rule for `T?` verbatim.  The `!` means *the world would not say* — a refused parent directory, a disk that failed — which is a reason a caller may want to print, arrives from the world rather than from the program, and passes FAILURE.md's operational test for an error with no room for argument.  The two are different answers and the signature has a place for each.  **This compiles and runs on today's language**: `-> Kind?!` parses, narrows into a `match`, and `catch none` collapses the two when a caller genuinely does not care. |
| **D5** | **`Kind` describes what the path *names*, with links followed.**  `stat`, not `lstat` — the same thing `open`, `read`, `write` and `delete` already mean, so a `kind` that answered otherwise would describe a different file from the one the next line touches.  A **dangling** link is therefore `none`: nothing is there to read, which is exactly what the program will find.  `symlink` is deliberately not a `Kind` member; the tree's symlink policy is `docs/PACKAGES.md` D1's — *resolution is lexical, never a `realpath`* — and that is about finding source files, not about what `open` does.  These two do not conflict and both stay. |
| **D6** | **`files.exists` is subsumed and removed, and the builtin `file_exists` is retired with it.**  §26: `kind` answers strictly more, and the two-door version has one door that lies twice (evidence 1 and 2).  The migration is `files.exists(p)` → `(files.kind(p) catch none) != none`, and its wordiness is the feature: `catch` means *it failed and I am deliberately discarding a reason*, which `docs/FAILURE.md` chose the word for because it should be greppable.  A `files.exists` is that `catch none` with the discard made invisible.  Corpus cost: **two call sites** (`zipper.luc:116`, and the `files.exists` rows in `specs/std_spec.zig`), and zipper's rewrite is an improvement rather than a translation — `if (files.kind(into) catch none) != Kind.directory` catches the file-in-the-way case that the current line waves through. |
| **D7** | **`files.list(path) -> list(Entry)!`, where `Entry` is `{ name: string, kind: Kind }`, sorted by name.**  One listing function, not two (§62), and the kind travels with the name that has it — which is where PEP 471, `fs.ReadDir` and `DirEntry::file_type` all ended up.  `Entry` is a plain value struct: no resources, copies for nothing, crosses every boundary with no verb.  It sits beside `zip.Entry` in std, which is the same word for the same idea in a different container, and beside `json.Kind`, which is the precedent for a std module owning an enum of its own.  Corpus cost: **one call site** (`editor.luc:492`), which wanted the kinds anyway. |
| **D8** | **The kinds in a listing are fetched per entry, inside `std.files`, and that is an implementation detail behind D7's signature.**  `files.list` is `dir_list` plus one `path_kind` per name.  A listing of N entries therefore costs N+1 host calls today, where the host could give the same answer in one — and when that matters, an appended `dir_entries` slot makes it one call **and not one Luce program changes**, because the signature already carries the kind.  That is the whole argument for deciding D7 now: §30 keeps the option, §23 puts the cost in one module instead of in every caller, and §63 makes this run one slot instead of two.  The reason it is not merely free today is worth stating: the kind an OS directory iterator hands over is the *link's* kind and may be "unknown" on some filesystems, so a host filling `dir_entries` must `stat` those entries to keep D5's one meaning — the fast path is fast for most entries, not all. |
| **D9** | **One new host slot: `path_kind`.**  `PathKindFn(context, path, path_length, kind: *i64) -> Answer`, appended, optional, fail-closed like every service.  `yes` with a kind code — 0 nothing, 1 file, 2 directory, 3 other — is the world answering; `no` is the world refusing to answer, which the program meets as `io_failed`.  **The absent case is `yes` with 0 and not `no`**, because `Answer` cannot carry the distinction D4 turns on and the out-parameter can: this is the one place the three-valued channel is genuinely too narrow, and widening the payload rather than inventing a fourth `Answer` keeps `abi.Answer` meaning what it means everywhere else.  `file_exists` is retired from use in the same bump, exactly as the whole-file text slots were retired at `docs/BYTES.md` R2 — the vtable stays append-only, nothing reorders, and no artifact at the new version indexes it. |
| **D10** | **One new intrinsic, `path_kind`, and one retired, `file_exists`.**  It lowers to a `luce_rt_path_kind` call answering `Kind?` boxed the way every `T?` already is, with the runtime raising the `io_failed` itself and naming the path — `docs/BYTES.md` B8 and B9's shape, unchanged, because the runtime is the side that knows the path and "the kind lookup failed" without saying which path is a message that helps nobody. |
| **D11** | **`paths` gains nothing in this run.**  The one candidate with real corpus evidence is a `clean`/`is_within` pair — `zipper.luc`'s `safe_name` hand-writes zip-slip defence today, and any extractor, installer or server that writes under a root wants the predicate.  It is deferred rather than refused, for two reasons that are both about getting it right: a lexical `is_within` is *unsound* across symlinks (Go documents this about `path.Clean` and it is the reason `filepath.EvalSymlinks` exists), and zipper's gate is half archive-format policy (backslashes, drive letters, APPNOTE 4.4.17.1) that does not belong in a general path module.  The trigger is named in Sequencing. |
| **D12** | **The string-method router stays `std.strings`' alone, and its diagnostic is fixed.**  `p.base()` will not route to `paths`, because `"hello".dir()` compiling is a worse sentence about the model than `paths.base(p)` is a verbose one (§9) — a path is a string, but not every string is a path.  What must change is evidence 8's diagnostic: a string method that `strings` does not have must not advise importing `strings`, and where the name is one of `paths`', it should name `paths.NAME(s)`.  Two sentences in `calls.zig`, independent of everything else here, and it is the cheap fix for the only real complaint a `Path` type would have answered. |

---

## The kind question, argued

Three shapes were weighed.

**Separate predicates** — `is_file(p)`, `is_directory(p)` — lose on two
counts.  They are two host calls to answer one question about one
path, which is a race with itself: a name can change between them.  And
each has to decide what to answer when the world refuses, which puts
evidence 2's lie in two places instead of removing it.  Python has
both and its own documentation warns that `Path.is_dir()` returns
`False` on a permission error.

**A `stat`-shaped answer** — a struct with size, times, mode — is
refused in Non-goals below and does not compete here: every field is a
promise, and no current customer wants one.

**One question, one answer, three outcomes** wins because the language
already has exactly three ways to answer and no two of them mean the
same thing.  Written out:

```text
match try files.kind(child):
    directory:
        walk(child)
    file:
        visit(child)
    other:
        skip(child)
```

and where the caller does not care why:

```text
if (files.kind(target) catch none) == Kind.directory:
    ...
```

and where the caller does:

```text
let what = files.kind(target) catch reason:
    print("cannot look at " + target + ": " + reason)
    return
if what == none:
    print(target + " is not there")
```

`none` and `!` are not two spellings of failure being awkwardly
reconciled; they are the two things that can actually happen, and
FAILURE.md's rule assigns each of them without a tie-break.  The `?`
is what makes the compiler refuse a call site that forgot the empty
case, which the `"eof"`-versus-`string?` argument in FAILURE.md
already settled once for `key_read`; the `!` is what keeps a refused
directory from being reported as an empty one, which is the bug
Rust shipped `try_exists` to fix.

## Listing with kinds, priced both ways

| | one call per entry (D8 today) | one call for the listing (`dir_entries`, later) |
|---|---|---|
| host calls for N entries | N + 1 | 1, plus one per link or unknown-kind entry (D5) |
| ABI cost | none beyond `path_kind` | one more appended slot, one more retired (`dir_list`) |
| runtime cost | none — `files.list` is a Luce loop | a second parallel run (one kind byte per entry) beside the NUL-joined names, and the `list(Entry)` built where the names list is built |
| what a Luce program writes | `files.list(p)` | `files.list(p)` — **identical** |

A store of five thousand files costs five thousand extra `fstatat`
calls, on the order of milliseconds, and PEP 471's measurements say
that becomes 2–20× on a deep walk once the tree is large enough to
matter.  So the fast path is worth having and is not worth having
*first*: it changes no signature, no spec, no example and no
document, which is the definition of something that can wait.  What
cannot wait is D7, because after `luce install` and a build tool exist,
changing `files.list`'s return type stops costing one line.

---

## What this costs

- **`abi.version` 16 → 17.**  One appended slot (`path_kind`), one
  retired from use (`file_exists`).  A version is a rebuild of every
  artifact there is, and a stale one is refused by name rather than
  run.
- **`format_version` 41 → 42.**  One intrinsic appended (`path_kind`),
  one retired (`file_exists`).  No migration; modules recompile.
- **`libluce_rt`:** one export, `luce_rt_path_kind`, which calls the
  installed slot, raises `io_failed` on refusal naming the path, and
  answers a boxed `Kind?` — nothing new in kind, and both engines
  reach the same implementation.
- **Both engines in lockstep**, as always: the interpreter reaches the
  same export through the same `Host` table, and the artifact-refusal
  row for the bump is written the way `docs/BYTES.md`'s was.
- **`std.files`:** one enum, one struct, one new function, one removed,
  one changed return type.  `std.paths` is untouched.
- **Specs:** two-engine rows in `specs/std_spec.zig` for each kind, for
  absence, for a refused parent, for a dangling link, for a listing
  that carries kinds, and for the host with the slot absent
  (`host_unavailable`, fail-closed, unchanged).
- **Corpus:** `zipper.luc` one line (improved), `editor.luc` one call
  site plus the pane it enables, `host_spec.zig`'s `file_exists` row,
  `editor.luc`'s builtin keyword table, `docs/STD.md`'s two blocks,
  and the site's builtin reference.

Nothing here needs a language change.  Every shape in this memo was
written into a `.luc` and run against the installed toolchain first:
`-> Kind?!` checks and executes, a `Kind?` narrows into a `match`, an
enum member may be spelled `file` beside the `file` resource type, and
`xs.sort_by((a, b) -> a.name < b.name)` sorts a `list(Entry)`.

---

## Sequencing

**Before the first real consumer.**  D3–D7, D9 and D10 are one
movement and should land in one run, on both engines, with specs at
each step — before `luce install`, before a build tool, before the
registry's server side, and before anything else calls `files.list`.
This is the cheap-library-slice rule and it is the entire reason for
the memo's timing: `files.list` has **one** caller today and
`files.exists` has **two**, so changing both costs three lines.  After
`luce install` ships, changing `files.list` costs everyone, forever,
and the wart in `exists` becomes permanent by weight rather than by
argument.

**Do not race the version numbers.**  This run moves both
`abi.version` and `format_version`.  `docs/BITWISE.md`'s lesson,
repeated by `docs/BYTES.md` and `docs/UNION.md`: two runs through one
version number is the way to lose both.  Anything else in flight that
moves either waits or goes first.

**Can wait, in this order.**

1. **D12's diagnostic.** Independent of everything, two sentences, and
   it can land before, during or after.
2. **The `dir_entries` fast path (D8).**  Pure optimization behind an
   unchanged signature.  Its trigger is a measured walk — the package
   store's, most likely — and `bench/` is where the number goes.
3. **D11's `paths.clean` / `paths.is_within`.**  Its trigger is the
   *second* program that hand-writes a containment gate.  Zipper is
   the first and its gate is half archive policy; when a second one
   exists, the common half is visible and can be written once instead
   of guessed at now.

---

## For ratification

Three, and only the ones that genuinely need the owner.  Everything
else above had one honest answer and was taken as a decision rather
than spending a question on it.

| | question | recommendation |
|---|---|---|
| **R1** | **Does `files.exists` go, and does the builtin `file_exists` go with it?**  This is a removal from the shipped std surface *and* from the language's free builtins — the only thing in this memo that takes something away.  The alternative is keeping a bool predicate, honestly renamed and documented, beside `kind`. | **Both go** (D6).  A bool that answers `false` for "I was not allowed to look" is the bug `docs/FAILURE.md` refused for `key_read`, measured here rather than argued (evidence 2), and `kind` answers strictly more.  Two corpus sites, one of which gets *better*.  If the owner would rather keep a predicate, the honest form is `files.there(p) -> bool!` — fallible, so the refusal still has somewhere to go — and it should be added *after* `kind`, once a month of writing against `kind` says whether anybody misses it. |
| **R2** | **Does `files.list` change shape now** — `list(string)!` to `list(Entry)!` — **or gain a sibling that carries kinds?**  A sibling breaks nothing today and costs a second name for one concept forever. | **Change it now** (D7).  One call site, and that call site is `editor.luc`'s file pane, which is broken today *for want of the kinds*.  Go replaced `Readdir` with `ReadDir` and Python added `scandir` beside `listdir`; the first is the tidier surface a decade later and the second is why `os.listdir` still has to be explained.  Luce has one caller and gets to choose. |
| **R3** | **Is file metadata — size, modified time, mode — in scope for the run *after* this one, or refused?**  `docs/MISSING.md` already records "no file metadata" as what is left of the byte-channel item, so it is a named gap rather than an invention. | **Refused until a customer names a field** (Non-goals).  The two usual customers are answered elsewhere: the compile cache keys on the *content* hash of the program (`docs/PACKAGES.md`), not on mtime, which is the decision that makes a build reproducible; and "how big is it" is answered by reading it, since a size read before a read is the same race `exists` was.  If the owner knows of a customer — a `luce install` that must not re-download, an `ls -l` in loom — the field it needs should be named in this ruling and only that field designed. |

---

## Non-goals — what must not be built, and why

- **A filesystem abstraction layer, a VFS, or a pluggable backend.**
  `LuceHost` *is* the seam, and it is already narrow, optional and
  fail-closed.  A second layer inside the language would be §50's
  premature extensibility with a §42 pass-through in front of it.
  There is exactly one host today and the shape of a second is not
  known; the way to be ready for it is a narrow boundary, which
  already exists.
- **`stat`.**  Size, mtime, mode, inode, uid, gid, nlink.  Each is a
  promise the ABI must keep on every platform, and no current
  customer wants one (R3).  A `stat` struct is also the shape that
  invites the check-then-act race back in through a side door.
- **Watchers** (inotify, FSEvents, kqueue).  A callback protocol, a
  thread nobody spawned, a platform matrix, and an event model the
  language does not have — the host never calls *into* a program.
  `docs/THREADS.md` deliberately shipped `spawn`/`wait` and no shared
  state; a watcher is that whole argument reopened for a feature with
  no customer.
- **Globbing.**  A glob is a matcher, and a matcher is text — so it is
  `strings` or `paths` work over `files.list`, written in Luce, where
  its dialect is visible.  Baking one into `files` bakes a dialect
  (`**`? `{a,b}`? case?) into the host boundary.
- **Permissions, `chmod`, ownership, ACLs.**  `abi.Answer` is
  `yes`/`no`/`exhausted` on purpose, and a permission model is an
  operating-system decision `docs/V2.md` deferred with capabilities.
  Inventing a Unix mode bitfield in the language would be inventing a
  security model in the standard library.
- **Symlink creation, reading, or resolution** — `symlink`,
  `read_link`, `realpath`.  D5 gives the whole symlink surface a
  program needs: a link is what it points at, and a broken one is
  nothing.  Resolution stays lexical per `docs/PACKAGES.md` D1.
- **Recursive helpers** — `remove_tree`, `copy_tree`, `copy_file`.
  Each is a loop over the primitives plus a policy (follow links?
  stop on the first error, or carry on? preserve what?), and a
  recursive delete in a standard library is a foot-gun with no undo.
  Once `kind` exists these are ten legible lines in the program that
  wants them, with its own policy in view.
- **Current-directory calls** — `getcwd`, `chdir`.  §31 and §51: a
  program that can move its own cwd makes every relative path in it
  ambiguous, including the ones already in flight.  loom resolves
  relative to the directory it was started in and says so.
- **Temporary files and directories.**  A naming policy, a cleanup
  policy, and a security argument about `/tmp`, for no customer.
- **A second path separator, drive letters, or UNC paths.**  `paths`
  says `/` and says so out loud.  When a Windows host is real, it is
  a memo, not a flag.
