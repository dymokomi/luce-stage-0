# What it would take for Luce to need no `cc`

> **This is research, not a decision, and it must not be read as one.**
> The owner's instruction is the whole warrant: *"cc is an external
> dependency. We must enable [the toolchain] to produce an executable
> without any external dependencies."*  So this file gathers.  It
> establishes what `cc` is actually being asked for today, surveys the
> routes that could replace it, prices each against the invariants this
> tree has already ratified, ranks them, and ends with the questions
> that genuinely need the owner.  **Every fenced block in it is
> `text`** — these are command lines, symbol dumps and measurements,
> not Luce, and the doc guard would be right to refuse them as Luce.
>
> Unusually for a research memo, most of what follows was **measured
> rather than read**.  The decisive claims were run on this machine
> against this tree; §0 is the ledger, and every `[M]` below points
> back into it.

The occasion is that `cc` is the last external tool on the shipped
path.  `docs/CODEGEN.md` already records the decision to use it and the
LLD investigation that preceded it, and both were correct when they
were written.  What has changed since is that **`./vendor-llvm.sh`
exists**: the project already takes LLVM source, pins it by hash,
builds it, and links it statically.  The argument that reaching LLD
"means discovering a second toolchain or vendoring one"
(`src/apps/native.zig`) is still true — but the second half of it
stopped being a cost the day vendoring became the house habit.

---

## 0. The evidence ledger

Everything marked `[M]` was measured on **macOS 15.7.3 (24G419),
Apple Silicon**, against **this tree's `build/`** (Apple clang 17.0.0,
`ld-1230.1`, vendored LLVM/LLD **22.1.8**).  Absolute times mean
nothing off this host; the *shapes* are what the memo rests on.

**M1 — LLD 22.1.8 links this tree's real artifact with no `cc` and no
SDK.**  Using `programs/editor.luc`'s object and the installed runtime,
against a directory containing exactly one file:

```text
ld64.lld -arch arm64 -dylib -o out.lc ed.o libluce_rt.a \
         -lSystem -syslibroot <dir containing ONLY libSystem.tbd> \
         -platform_version macos 13.0 15.0
```

→ 806,832 bytes, `Signature=adhoc`, `flags=0x20002(adhoc,linker-signed)`,
`otool -L` names only `/usr/lib/libSystem.B.dylib`, and it `dlopen`s.
The stub was Zig 0.16's shipped `libSystem.tbd`, 334 KB of text.

**M2 — the same for `--emit=exe`.**  `t.o` + `libluce_start.a` +
`libluce_rt.a`, same stub, no `cc`, no crt objects: the binary ran and
printed `hi`, exit 0.

**M3 — LLD does the ad-hoc signing itself.**  Both M1 and M2 came out
`linker-signed` with no `codesign(1)` anywhere.  This answers the
sharpest question the brief posed: on arm64 the signature is
mandatory, and the linker is what supplies it.

**M4 — Zig 0.16 links `liblld{ELF,COFF,Wasm,MinGW,Common}` but refuses
LLD for Mach-O.**  `otool -L $(which zig)` names all six; `zig
build-lib -dynamic -flld -target aarch64-macos` answers **`error: using
LLD to link macho files is unsupported`**.  Zig's Mach-O linker is
self-hosted and does its own ad-hoc signing (verified: `-fno-lld`
produced a `linker-signed` dylib).

**M5 — Zig calls LLD from a child process, not in-process.**
`src/link/Lld.zig`: *"We will invoke ourselves as a child process to
gain access to LLD.  This is necessary because LLD does not behave
properly as a library — it calls exit() and does not reset all global
data between invocations."*  Since Zig 0.7.1 (Dec 2020).  **The child
is Zig's own binary**, so this costs no external dependency.

**M6 — our generated object's relocation surface is five types, no GOT,
no TLS.**  `programs/editor.luc` → 1,031 fixups:

```text
type=2  ARM64_RELOC_BRANCH26     479   (BL to luce_rt_*)
type=3  ARM64_RELOC_PAGE21       218   (ADRP, internal)
type=4  ARM64_RELOC_PAGEOFF12    218   (ADD/LDR, internal)
type=0  ARM64_RELOC_UNSIGNED     113   (64-bit absolute, __const/__eh_frame)
type=1  ARM64_RELOC_SUBTRACTOR     3   (__eh_frame deltas only)
```

Zero `GOT_LOAD_*`, zero `ADDEND`, zero `TLVP_*`.  Sections are
`__text`, `__literal{4,8,16}`, `__TEXT __const`, `__DATA __const`,
`__compact_unwind`, `__eh_frame` — **no `__data`, no `__bss`, no TLS.**

**M7 — our object imports only our own runtime.**  `nm -u ed.o` is 29
symbols, every one `_luce_rt_*`.  No `memcpy`, no `__stack_chk_fail`,
no `__divti3`, no unwind personality.

**M8 — but the *linked* `.lc` imports 104 libSystem symbols**, including
`_fork`, `_execve`, `_socket`, `_pthread_create`, `_getaddrinfo`.  All
of them arrive with `libluce_rt.a`, which is **one object file**
(`ar t` → `libluce_rt_zcu.o`), so linking any part of it links all of
its references.  It also drags in `__tlv_bootstrap` and **256 KB of
`__thread_bss`** (`0x40010`) into every artifact.

**M9 — a "thin" artifact is 102 KB against 810 KB, and its import
surface is exactly our 29 names.**  Linking `ed.o` with
`-Wl,-undefined,dynamic_lookup` and no runtime yields a `.lc` that
exports exactly `_luce_main` and `_luce_artifact` and imports exactly
the `luce_rt_*` set.  `RTLD_NOW` refuses it cleanly when the host has
no runtime; `RTLD_LAZY` opens it.

**M10 — dyld's first-open cost is ~78 ms and is independent of size.**
Five never-seen copies each:

```text
810 KB artifact:  79.4  76.8  76.8  78.0  78.6  ms
102 KB artifact:  76.9  78.1  78.8  76.5  75.4  ms
warm re-open of the same file:   1.0  0.8  0.8  ms
```

`docs/ENGINE.md` Hat 3 records 89.4 ms for the same term.  **Shrinking
the artifact does not touch it** — it is the OS validating a code
signature it has never seen, not paging.

**M11 — the same bytes through `mmap` + `mprotect` cost 0.08 ms.**
`mmap(RW, MAP_ANON)` + `read` + touch every page + `mprotect(R|X)` on
810 KB: 0.08 ms.  On 102 KB: 0.01 ms.  That is the whole size of the
prize in M10, and it is ~1000×.

**M12 — the macOS W^X matrix, run with a real `mov w0,#42; ret`:**

```text
signing state                              plain RW→mprotect RX→call   MAP_JIT + toggle
ad-hoc, no hardened runtime                WORKS                       WORKS
hardened runtime, no entitlement           SIGKILL at the call         mmap → EINVAL
hardened + com.apple.security.cs.allow-jit SIGKILL at the call         WORKS
hardened + allow-unsigned-executable-memory WORKS                      WORKS
```

Note the shape of the failure: under the hardened runtime `mprotect`
**returns 0 and lies**, and the kernel kills the process at the jump.

**M13 — the link is 30 ms, and it is 60% of a trivial build.**
`cc -shared` over `hello`: 0.02–0.03 s, against 0.05 s for the whole
`luce build`.  For `editor` it is 0.03–0.04 s of 0.26 s.
`docs/ENGINE.md` Hat 3 records 51.8 ms for `sort.luc`.

**M14 — `build/luce` already names only `libSystem`.**  The vendored
static LLVM means the compiler binary has no LLVM dylib dependency at
all.  `docs/ENGINE.md` line 485 still says it names `libLLVM.dylib`;
that sentence describes the system-LLVM build and is stale for a tree
that has run `./vendor-llvm.sh`.

**M15 — `llvm-config` genuinely does not know LLD exists.**  On the
vendored install, `llvm-config --libs | grep -c lld` → `0`, and
`.llvm/install/lib` contains no `lld*` at all, because `vendor-llvm.sh`
passes no `-DLLVM_ENABLE_PROJECTS`.  `docs/CODEGEN.md`'s claim is
correct as written and is a fact about the *configure line*, not about
LLD.

---

## 1. What the link is walking into

Six facts about this tree, each with the file that holds it.  Every
route below is priced against these and nothing else.

**1.1 The link is already one invocation of a fixed shape.**
`src/apps/native.zig`'s `link` builds exactly this argv and nothing
else:

```text
cc [-shared [-Wl,--no-undefined if not Darwin]] -o PENDING OBJECT [START] RUNTIME
```

One object, one or two of our own static libraries, one output.  No
`-l` the user chose, no include paths, no search paths, no third-party
libraries — because Luce has no FFI and no way to name one.  `LUCE_CC`
overrides the driver.  The output is published by rename, so a loader
never sees a partial file.

**A fixed-shape link is what makes every route below tractable**, and it
is worth noticing that the one flag in there is already the right one:
`-shared` defaults to `-z undefs` on ELF, so a compiler-emitted call
nobody wrote — `memcpy` from a struct copy, `__stack_chk_fail`,
`__udivti3` — would link silently and fail at *load*.  `--no-undefined`
turns that into a build error, which is the same instinct as routing
effects through `LuceHost` rather than as undefined symbols.

**1.2 Nothing external is invoked on the run path, and that is sacred.**
`docs/CODEGEN.md`: *"Running an artifact that already exists is one
`dlopen`, one symbol lookup, one call."*  A machine that only *runs*
Luce programs needs no compiler, no LLVM, and no C toolchain today.
Every route below must leave that true, and one of them makes it truer.

**1.3 The artifact tag already refuses the wrong file by name.**
`08_llvm/artifact.zig` carries magic, layout version, host ABI version,
machine, `source_hash`, `generator`, and the debug flag; `native.zig`'s
`open` reads it *before* calling anything, and `explain` gives six
distinct sentences.  **This is the mechanism any new artifact shape
would inherit rather than invent** — including, notably, a shape whose
runtime lives somewhere else.

**1.4 `loom` links no LLVM and must not start.**  `docs/CODEGEN.md` is
explicit, and `otool -L build/loom` is how it stays true.  The reason
is the measured 5.7 ms of dyld that naming `libLLVM.dylib` cost, against
a 3.1 ms floor.  Any route that puts a linker in `loom` is refused on
sight; any route that puts one in `luce` is merely a size question.

**1.5 Vendoring toolchain source is established practice.**
`vendor-llvm.sh` pins LLVM **22.1.8** by SHA-256, configures
`LLVM_TARGETS_TO_BUILD='AArch64;X86;WebAssembly'`, `BUILD_SHARED_LIBS=OFF`,
and every optional external library **off** *"so the static link needs
nothing beyond libm and the C++ runtime"*.  `build.zig`'s `discoverLlvm`
prefers `.llvm/install` over anything the machine has.  The precedent
for how this project takes on toolchain source is therefore already
written, and the answer was: pin it, build it, link it statically,
prefer it.

**1.6 The specs are the only thing that tests linking, and they test it
986 times.**  `src/luce/specs/agree.zig` line 231 runs
`cc -shared -o … program.o <luce_rt_library>` for **every** spec that
runs a program, then `dlopen`s the result.  Its own comment: *"The link
is also the proof that the artifact declares no undefined symbols
beyond `libluce_rt`."*  So the two-engine oracle does not test the
linker — but the harness that carries it links 986 times per suite,
which is a different and quite strong thing.  §5 takes this seriously.

---

## 2. What `cc` is actually being asked for

Stripped of habit, `cc` supplies four things.  Naming them separately
matters, because the routes below replace different subsets.

**2.1 A linker.**  `ld` (here `ld-1230.1`).  This is the part everyone
thinks of, and it is the part that is most replaceable: M1 and M2 show
LLD 22.1.8 doing the whole job for both artifact shapes.

**2.2 Platform knowledge — and much less of it than expected.**  On
macOS `cc` contributes the SDK path (via `xcrun`/`xcode-select`), which
is where `-lSystem` resolves.  M1 shows the entire contribution
collapsing to **one 334 KB `.tbd` stub**.  TBD v4 is a text
declaration of a dylib's exported surface: install name, targets,
re-exported libraries, symbol lists.  A linker resolves `-lSystem`
against it and records an `LC_LOAD_DYLIB` for
`/usr/lib/libSystem.B.dylib`; the real dylib is found at run time by
dyld, from the shared cache, and is present on every macOS by
definition.  **No crt objects were needed** (M2) — modern Mach-O uses
`LC_MAIN` with an entry offset, and `libSystem` provides the process
start.

Linux is where this gets expensive, and the asymmetry is the single
biggest cost difference in this memo.  Reading Zig 0.16's shipped tree
directly:

```text
lib/zig/libc/darwin/libSystem.tbd        334 KB  one declarative text file
lib/zig/libc/glibc/abilists              249 KB  binary index: symbol → glibc version → target
lib/zig/libc/glibc/csu/{init.c, elf-init-2.33.c, abi-note.S, errno.c}
                                                 glibc's crt startup as SOURCE
lib/zig/libc/musl/crt/{crt1.c, Scrt1.c, rcrt1.c} musl crt as SOURCE
```

**But the two emit kinds are affected very differently, and the split
is worth stating exactly.**

- **`--emit=library` needs essentially nothing.**  GCC's own spec
  (`GNU_USER_TARGET_STARTFILE_SPEC` in `gcc/config/gnu-user.h`) supplies
  **no crt0 at all** under `-shared`, and Zig's Linux path builds only
  `Scrt1.o` and `libc_nonshared.a` — never `crti`/`crtn`, never
  `crtbegin`/`crtend`.  A `.so` has no `PT_INTERP` (the driver
  deliberately omits `-dynamic-linker` under `-shared`).  A C-shaped
  shared library with no C++ static destructors needs zero crt objects.
  **This is the trivially self-containable case, and it is the one that
  matters most, because the `.lc` is the artifact loom runs.**
- **`--emit=exe` is where the cost lives.**  It needs the dynamic-linker
  path table, `Scrt1.o` (which *is* `_start`, and belongs to glibc), and
  `libc_nonshared.a`.

**And `PT_INTERP` is a sharper problem than it looks: no linker knows
it.**  LLD's `getDynamicLinker` returns `""` when the flag is absent,
and GNU ld has no built-in default for x86-64 Linux either — the table
lives in *clang's driver* (`ToolChains/Linux.cpp`) and *gcc's config
headers*.  Zig ships its own, `DynamicLinker.standard(cpu, os, abi)` in
`lib/std/Target.zig`, about 280 allocation-free lines.  So a
self-contained toolchain must carry a few dozen rows mapping target to
`/lib64/ld-linux-x86-64.so.2`, `/lib/ld-linux-aarch64.so.1`, and so on.
It is small, and it is *not optional*, and nothing below the compiler
driver will supply it.

There is also a genuine escape hatch worth naming: a **static-musl-style
executable** — own `_start`, raw syscalls — needs no `PT_INTERP`, no crt
object, and no libc.  It trades glibc's NSS (`getaddrinfo`, `getpwnam`)
and `dlopen`, both of which glibc itself warns are unsupported when
statically linked, and neither of which Luce can currently reach.

**2.3 compiler-rt builtins.**  `libluce_rt.a` references `__divti3`
(128-bit division, from Zig's std); our own object does not (M7).  On
macOS this resolves through `libSystem`'s re-export of
`libcompiler_rt.dylib` — visible in the very `.tbd` we would ship.  On
Linux `__divti3` lives in `libgcc_s`/`compiler-rt`, **not in libc**, so
a Linux self-contained link owes a builtins archive.  Zig ships 270
files of `compiler_rt` for exactly this, and we build with Zig, so the
implementation already exists in our own dependency.

**2.4 Ad-hoc code signing.**  On arm64 macOS every executable page
backed by a mapped Mach-O must carry a valid signature or the kernel
refuses it.  `ld64` does this automatically; **so does LLD** (M3); so
does Zig's self-hosted Mach-O linker (M4).  This is not a thing `cc`
uniquely knows.

---

## 3. The routes

### A. Vendor LLD, ship the stubs

Add `-DLLVM_ENABLE_PROJECTS=lld` to `vendor-llvm.sh`, ship
`libSystem.tbd` beside `libluce_rt.a`, and have `luce` link with LLD
instead of spawning `cc`.

**Proven, not projected.**  M1 and M2 are this route executed by hand
with our exact pinned version, on our real artifacts, for both emit
kinds, with the SDK removed from the picture.  The remaining work is
plumbing, not discovery.

**The API is one header and it is argv-shaped.**
`lld/Common/Driver.h` (verified identical across LLVM 21/22/main):

```text
lld::Result lldMain(ArrayRef<const char*> args, raw_ostream &out,
                    raw_ostream &err, ArrayRef<DriverDef> drivers);
struct Result { int retCode; bool canRunAgain; };
LLD_HAS_DRIVER(macho)  →  lld::macho::link(args, out, err, exitEarly, disableOutput)
```

So the command line we already build in `native.zig` is very nearly the
command line we would hand `lldMain`.  Upstream documents the embedding
explicitly: *"You can embed LLD in your program to eliminate
dependencies on external linkers … construct object files and command
line arguments just like you would do to invoke an external linker and
then call the linker's main function."*

**The catch, and it is real.**  LLD-as-a-library is documented,
tested and *not guaranteed*.  `lld/docs/NewLLD.rst`: *"it is your
responsibility to give trustworthy object files … A corrupted file
could cause a fatal error or SEGV."*  The header broke twice without a
release note (LLVM 14 reordered `link()`'s parameters; LLVM 17 deleted
`safeLldMain` for `lldMain`).  Per-port re-entrancy is uneven — ELF and
COFF now build a per-call context, while **Mach-O still hand-resets two
dozen file-scope globals** through a `cleanupCallback`, and lld's own
lit config excludes wasm and lets Mach-O tests opt out of its
run-twice mode.  lld/ELF's maintainer, writing in 2024: *"I believe
that invoking LLD as a separate process remains the recommended
approach."*

**Which is why the sub-choice matters more than the route.**

- **A1, in-process** (`lldMain`, check `canRunAgain`).  One process per
  build; `luce` is a one-link-per-run compiler, so the re-entrancy
  weakness barely applies — except in `zig build test`, where the
  harness links 986 times, and where it applies completely.
- **A2, self-exec** — build the argv in process, then spawn *our own
  binary* with a reserved first argument, exactly as Zig does (M5).
  This costs a `fork`/`exec` per link, which next to a link is noise
  (M13), and it makes `fatal()`-calls-`exit()` and global-state
  contamination structurally impossible.  **It adds no external
  dependency, because the child is `luce`.**  Every large project that
  kept in-process LLD long enough to hit the problem — Zig, MLIR/ROCm,
  Rust before it shipped — converged here.

Rust is the other data point: `rust-lld` has been the default linker
for `x86_64-unknown-linux-gnu` since **1.90.0 (2025-09-18)**, and it is
shipped as a **separate binary invoked through `cc -fuse-ld=`**, never
embedded.  The in-process attempt (rust-lang/rust#36120, 2016) died
partly on inactivity and partly on the structural blocker that lld does
not supply `-lc`/`crt1.o` the way a C driver does.  **We do not have
that blocker**, because §2.2 shows our platform surface is one stub.

**Size.**  LLD's six libraries are ~5.6 MB against a 157 MB libLLVM —
rounding error, and `luce` is already 57.8 MB.  Only `lldMachO`,
`lldELF` and `lldCommon` are needed.

**What it does not fix.**  The 78 ms (M10).  A `.lc` produced by LLD is
still a code-signed dylib that dyld validates on first sight.

**Cost: 3–4 engineering runs.**  One to extend `vendor-llvm.sh` and
prove the static link of `lldMachO`/`lldELF`/`lldCommon` from
`build.zig` (LLD is invisible to `llvm-config`, M15, so the library
list is hand-written and ordered format-libraries-then-`lldCommon`).
One for the self-exec driver and the argv construction.  One for
shipping and locating the `.tbd`.  One for Linux, which is genuinely
its own run because of §2.2.

### B. Our own container and our own loader for `.lc`

Stop producing a platform dylib for the loadable form.  Emit our own
container, and have `loom` `mmap` it, apply fixups, and call it.

**The measurements are unusually favourable.**  Five relocation types,
no GOT, no TLS, no writable data (M6); 29 imports, all ours (M7); a
102 KB image when the runtime is elsewhere (M9); and 0.08 ms against
78 ms to get it into memory (M10, M11).  The closest precedent —
wasmtime's `.cwasm` — went further and engineered its *code generator*
so the container needs **no relocations at all**, routing every host
call through a function-pointer array in its context structure.  That
is `LuceHost`, arrived at independently for the same reason.  Dart
ships an ELF container plus its own loader in every Flutter app.

**And the enabling move is one we already have the mechanism for.**
Under this route `libluce_rt` moves out of the artifact and into the
runner, and the 29 `luce_rt_*` references resolve against a static
name→address table compiled into `loom`.  `docs/CODEGEN.md` lists "a
shared `libluce_rt`" as a known open question and declines it because
it *"would trade a self-contained file that runs anywhere the machine
matches for an rpath and a version-matched install."*  **The custom
loader makes that objection not apply**: there is no rpath, and the
version match is already enforced by `artifact.generator` (1.3), which
exists precisely to refuse an artifact built by a different code
generator.

**Three costs, and the first is decisive.**

1. **macOS W^X (M12).**  Unhardened, this route works today with a
   plain `mmap`+`mprotect`.  Hardened — which is what notarization
   requires, and notarization is what "a person downloads `loom`"
   requires — plain `mprotect(RX)` returns success and then the kernel
   **SIGKILLs at the jump**.  The supported path is `MAP_JIT` plus
   `com.apple.security.cs.allow-jit`, plus the
   `pthread_jit_write_protect_np` write/execute toggle, plus a
   Developer ID certificate to attach entitlements that AMFI honours.
   `MAP_JIT` requires `MAP_ANON`, so the container **cannot be mapped
   from the file** — it must be copied into anonymous memory, forfeiting
   page-cache sharing between processes.  Wasmtime has this as an open
   unfixed issue.
2. **Unwind registration and tooling.**  `dlopen` registers
   `__eh_frame`/`__unwind_info` and hands lldb and Instruments the
   image.  A custom loader owes both, and Luce's debug promise is
   `file:line:column` **plus a call trace**.
3. **It cannot serve `--emit=exe`.**  A standalone binary must be a
   real Mach-O/ELF the kernel executes.  **No custom loader reaches
   it.**

**That third point is the ranking, and it should be stated plainly:
route B alone cannot satisfy the owner's directive.**  As long as
`luce build --emit=exe` is a shipped capability, something must produce
a real platform executable, and that something is a linker.  B removes
`cc` from the `.lc` path; only A removes it from the toolchain.

**Cost: 6–10 engineering runs**, and a signing-and-distribution
decision that is not an engineering question.

### C. The thin artifact (an enabler, not a route)

Independent of A and B: stop putting `libluce_rt` inside every
artifact.  810 KB → 102 KB, exports 2 instead of 82, imports 29 instead
of 104, and the 256 KB of `__thread_bss` per artifact goes away (M8,
M9).  Under `dlopen` this needs `loom` to export the `luce_rt_*`
symbols and `RTLD_NOW` so a mismatch fails at open rather than at call.

It does not remove `cc`.  It is listed because it is **the prerequisite
that makes B cheap**, it is independently valuable, and it is the one
item here that could be done this week without deciding anything else.
It also changes what a `.lc` *is* — an artifact that needs a host
carrying a matching runtime — which is a real change and belongs to the
owner, not to this memo.

### D. `zig cc` as the linker (the footnote)

It works: `zig cc -shared` linked our real editor object and runtime
into a loading, ad-hoc-signed `.lc` with a *cleaner* install name than
`cc` produced.  `docs/CODEGEN.md` already names it as the obvious answer
for cross-compilation, and Zig is already a build dependency.

**It is not an answer to the directive**, because it replaces one
external tool with another — and a *larger* one, since a shipped `loom`
would then owe a Zig installation to compile a `.luc`.  What it proves
is worth keeping: the platform knowledge in §2.2 is a solved problem
with a known shape, and the shape is "ship stubs, call a linker
library."

### E. Do nothing yet, on purpose

`cc` is present on every machine that has a C toolchain, is a
*build-time* dependency only, and a machine that merely runs Luce
programs already needs nothing (1.2).  The honest version of this
position is that the directive's word "executable" may be about the
**run** path, which is already satisfied.

It is listed to be refused honestly rather than ignored: the directive
says *produce*, and producing is the build path.  But E is the correct
answer to a narrower question, and §6 asks which question was meant.

---

## 4. The one page

Ranked, with the reason in one line each.

1. **A2 — vendored LLD, called by self-exec, with a shipped `.tbd`.**
   The only route that actually discharges the directive for both emit
   kinds; proven end-to-end today (M1, M2, M3) with our pinned version;
   sidesteps LLD's one genuine weakness (Mach-O re-entrancy) by the
   same trick Zig uses, at a cost of one `fork` against a 30 ms link.
2. **C — the thin artifact.**  Cheap, independently valuable, 8×
   smaller artifacts, and it is what makes 3 affordable.  Does not
   discharge the directive.
3. **B — our own container and loader for `.lc`.**  The
   LuciaOS-shaped end state and the only thing that touches the 78 ms
   (M10, M11), but it cannot serve `--emit=exe`, and macOS's hardened
   runtime turns it into an entitlements-and-notarization project
   (M12).  Additive to 1, never a substitute.
4. **A1 — in-process LLD.**  Same as A2 minus the safety, and the
   986-link spec harness is exactly the workload the weakness targets.
   Worth reaching for only if the self-exec proves awkward.
5. **D — `zig cc`.**  Refused as an answer, kept as evidence.
6. **E — do nothing.**  Refused, but §6 asks whether it answers the
   question actually being asked.

**The honest headline: the macOS half of this is smaller than it
looks, and on Linux the split is not between platforms but between
emit kinds.**  One 334 KB text file and one linker library carry macOS
from "needs Xcode" to "needs nothing" (M1, M2).  On Linux the **`.lc`
is nearly free** — no crt objects, no `PT_INTERP`, no libc if the
runtime keeps its imports honest — while **`--emit=exe` owes the
dynamic-linker table, `Scrt1.o`, `libc_nonshared.a` and a compiler-rt
archive** (§2.2, §2.3).  That is the useful shape: *the artifact loom
runs is the cheap case on both platforms, and the standalone binary is
the expensive one on both.*  Any plan that prices this per-platform
rather than per-emit-kind will misjudge it.

---

## 5. How each route is tested

The brief is right that **the two-engine oracle does not cover
linking** — `agree` compares two engines' behaviour, and a linker bug
produces an artifact that both arms never see.  A linker bug is a
silent-corruption factory: wrong addend arithmetic gives a program that
runs and computes the wrong number.

What actually covers it today, and what would have to:

**5.1 The 986 links already in the suite (1.6).**  Every spec that runs
a program links one and `dlopen`s it, and the result is compared
against the interpreter on prints, trap code, trap message, call trace,
leak census and the world left behind.  **That is a differential test of
the linker**, even though it was built as a differential test of the
engine — the interpreter never links, so any relocation the linker got
wrong shows up as a disagreement.  Any route that changes who links
inherits this for free, and it is a stronger safety net than it looks.

**5.2 What each route additionally owes.**

- **A** owes an equivalence test: the same object linked by `cc` and by
  LLD must produce artifacts that behave identically, and the
  `libSystem.tbd` path must be proven with the SDK made unavailable
  rather than merely present.  `src/apps/loom/product.zig` — the
  miniature install tree already used to prove the loom→luce hand-off —
  is the right home.
- **B** owes far more, because it replaces `dyld`.  The relocation
  applier needs direct unit tests per type (M6's five), and — the one
  test that actually catches an addend bug — a **differential test
  against the platform loader**: link the same object into a real dylib,
  `dlopen` it, load the container with our loader, and compare the
  bytes of every relocated word.  That test is available only while
  both paths exist, which is an argument for building B *beside* A
  rather than instead of it.
- **C** owes an import-surface assertion.  `nm -u` on an artifact
  should be a *test*, not an observation: the import set is exactly the
  kind of thing that silently regrows when LLVM's O3 pipeline changes
  underneath us (M7 vs M8 is that gap made visible).

**5.3 The one test that is missing today regardless.**  Nothing asserts
what an artifact imports or exports.  M8's 104 libSystem symbols and 82
exported symbols are not written down anywhere, were not chosen, and
would not be noticed if they doubled.

---

## 6. Questions for the owner

**Q1 — Does "without any external dependencies" mean the build path or
the run path?**  The run path already has none (1.2): `loom run
FILE.lc` invokes nothing.  If the directive is about a person *running*
Luce programs, it is satisfied and the rest of this memo is
optimisation.  If it is about a person *compiling* them — which is how
the word "produce" reads — then route A is the work.  Every other
question is downstream of this one.

**Q2 — Must both emit kinds be self-contained, or only the `.lc`?**
This turned out to be the better-shaped version of "which platforms"
(§2.2).  The `.lc` is the cheap case *everywhere* — one stub on macOS,
nothing at all on Linux.  `--emit=exe` is the expensive case
everywhere: ad-hoc signing and `libluce_start` on macOS, the
dynamic-linker table plus `Scrt1.o` plus `libc_nonshared.a` plus a
builtins archive on Linux.  "The artifact loom runs must need nothing;
a standalone binary may still want a toolchain" is a coherent and much
cheaper ruling than "everything, everywhere", and it happens to match
what `docs/CODEGEN.md` already says a `.luc` is allowed to cost.

**Q3 — Is `loom` going to be notarized?**  This decides route B
entirely, and it is a distribution question rather than an engineering
one.  Unhardened, B's loader works today with a plain `mmap`+`mprotect`
(M12).  Hardened — which notarization requires — B needs `MAP_JIT`, the
`allow-jit` entitlement, a Developer ID certificate, and a copy of
every artifact's text into anonymous memory.  If the answer is "yes,
eventually", B should be designed for `MAP_JIT` from the first line
rather than retrofitted.

**Q4 — Is `--emit=exe` permanent?**  It is what makes route B unable to
stand alone (§3.B). If standalone executables were ever to become
something else — a `.lc` plus a shipped runner, say — the calculus
inverts and B becomes sufficient on its own.  This memo assumes
`--emit=exe` stays, because it is shipped and documented, and flags the
assumption rather than making it quietly.

**Q5 — May a `.lc` stop being self-contained?**  Route C, and route B
after it, move `libluce_rt` out of the artifact and into the runner.
That is an 8× size win and the enabler for everything interesting, and
it changes what a `.lc` *is*.  `artifact.generator` already refuses a
mismatched pair by name, so the failure mode is a sentence rather than
a crash — but "a file that runs anywhere the machine matches" is a
property `docs/CODEGEN.md` chose on purpose, and only the owner can
trade it.

**Q6 — Is 78 ms per cold run worth an entitlement?**  `docs/ENGINE.md`
already says *"it is a reason to look at the 89 ms"*, and M10/M11 say
the only thing that looks at it is route B.  That is a real 1000×
on the one number the docs call the iteration-speed complaint — bought
with a signing story, a JIT entitlement, and a hand-written loader.

---

## 7. Non-goals — what this memo asks nobody to decide

- **Whether LLVM stays.**  `docs/CODEGEN.md` is the decision record for
  the code generator and nothing here reopens it.  Every route above
  keeps `emit.zig` exactly as it is; what changes is only what happens
  to the object afterwards.
- **Cross-compilation.**  `docs/CODEGEN.md` names it as the largest
  thing missing and correctly identifies the link as the blocker.
  Route A removes that blocker as a side effect — LLD takes a target
  like any other argument — but a `--target` flag, a `libluce_rt` per
  target, and the CLI surface for both are a design memo of their own.
- **Whether `loom` gains the runtime.**  §3.C sketches the cost;
  Q5 asks the question.  This memo does not propose the edit.
- **The serialized module, the artifact tag's fields, or `abi.version`.**
  All three are load-bearing here and none of them needs to move for
  any route above.  A new artifact *container* (route B) would carry the
  same tag, read the same way, refusing the same six ways.
- **Reopening `cc` as a bad decision.**  It was the right call when
  `docs/CODEGEN.md` made it, and the fact that changed is
  `vendor-llvm.sh`, not the reasoning.
- **Windows.**  Neither binary is built or tested there today, and
  adding it to this question would triple it.

---

*Gathered, not decided.  Nothing in the tree moved to write this: no
flag, no CMake line, no version number, not one line of Zig.  What did
move is the evidence — §0 is fourteen measurements that did not exist
before, and the three that matter most (M1, M2, M12) are the ones that
turn this from a survey into a decision the owner can actually take.
The next thing that should happen to this file is answers to §6 — after
which it becomes the evidence section of a design memo, and that memo
gets a **Ratified** banner like every other one in `docs/`.*
