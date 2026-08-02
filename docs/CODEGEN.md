# Code generation — the LLVM path

Luce has one code generator.  It lowers the typed Luce IR to LLVM IR,
hands that to libLLVM, and gets back machine code.  `docs/CODEGEN.md`
is the decision record for why; this is the description of what is
there.

The path is **partial**.  The interpreter still runs every `.lc` and
is still what `luce build` writes by default.  What follows says
exactly how far the LLVM path reaches.

## The pipeline

```text
FILE.luc → 02_lex → 03_parse → 04_semantics → typed MIR → 07_optimize
                                             ↓
                            std.zig.llvm.Builder  (08_llvm/lower.zig)
                                             ↓
                                        LLVM bitcode
                                             ↓
                     libLLVM: parse, default<O2>, emit  (08_llvm/emit.zig)
                                             ↓
                                  FILE.o  (relocatable object)
```

```sh
luce build FILE.luc --backend=llvm [-o FILE.o]
```

The object is built for the host triple, is position-independent,
exports exactly `luce_main`, and declares no undefined symbols beyond
`libluce_rt`.  Linking it is the caller's job today — there is no
shared-library or executable emit mode, and loom cannot load an
object.  `src/luce/08_llvm/test.zig` closes the loop instead: it links
with `cc -shared`, `dlopen`s the result, and runs it against a host
table built in Zig.  That link is itself the proof of the
no-undefined-symbols claim.

**Two rules govern `lower.zig`**, both inherited from what the deleted
hand-written backends cost:

- No `else` arm.  The switches over `ir.Instruction` and
  `ir.Intrinsic` name every tag, so a new IR instruction is a compile
  error here rather than a silent fallthrough.
- No `unreachable` for "not yet".  Anything without a lowering returns
  `.unsupported` naming the tag, so a gap is a message and never wrong
  code.

**IR construction uses `std.zig.llvm.Builder`** — the pure-Zig builder
in the pinned standard library — and links nothing.  `emit.zig` is the
only file in the tree that touches libLLVM, and it uses the narrowest
tier of the C API: parse a bitcode buffer, make a target machine, run
a textual pass pipeline, write an object.  That is the tier LLVM's own
developer policy describes as stable; IR *construction*, the part that
has broken repeatedly across releases, stays in-tree.

**The stage directory is `08_llvm/`, and the numeric prefix is what
makes that name legal.**  Zig derives symbol names from the source
path, and LLVM claims every symbol beginning `llvm.` as one of its own
intrinsics: a file at `src/luce/llvm/abi.zig` makes the compiler abort
with "llvm intrinsics cannot be defined!".  `08_llvm/abi.zig` yields
`08_llvm.abi.…`, which does not begin `llvm.`, so the check never
fires.  Never drop the prefix from this one.

## The generated module

Each Luce function becomes an `internal` LLVM function whose `i1`
result is the **trapped** flag:

```llvm
define internal i1 @"luce.3.gcd"(ptr %host, ptr %rt, i64 %depth, i64 %0, i64 %1, ptr %out)
```

True means the program is unwinding and the caller must return true in
turn without reading `%out`.  Traps are fatal and uncatchable, so the
flag only ever travels one way.  A returned value goes through `%out`,
which is absent when the function returns nothing.  Every function
carries `%host`, `%rt`, and `%depth` as hidden leading arguments.

That convention beat the zero-cost alternative — a `noreturn` host
callback plus `longjmp` — because it needs no platform unwinding
machinery and works unchanged on wasm32.

Locals are entry-block `alloca`s that mem2reg promotes.  Every
`alloca`, including scratch slots created deep in the walk, is emitted
in the entry block, so nothing accumulates inside a loop.

## Call depth, and the trace a trap carries

Luce promises that runaway recursion **traps** — a stable code, a
message, a call stack — rather than overflowing the machine's own
stack.  The interpreter keeps that promise by counting frames on the
explicit stack it runs on.  Generated code runs on the native stack,
so it counts differently: `%depth` is how many Luce frames are still
allowed *including this one*, a callee is handed one less, and a call
that would take it to zero traps `call_depth_exceeded` at exactly the
call where the interpreter's frame stack would have refused to grow.

That is a register subtract and a compare against a constant, and the
limit is the same whether or not LLVM inlined the callee, because the
arithmetic is in the IR rather than in the stack pointer.  It also
costs nothing measurable: LLVM hoists the check to the top of each
function and folds it into the decrement, so recursive `fib` pays one
`subs` and one branch per *function*, not per call.  A/B against a
build with the check removed measured `-0.75%` to `+0.63%` across
`loops`, `matmul`, `fib(35)`, a mutually recursive Ackermann, and a
hundred-million-call loop — noise in every case.

How deep is too deep is the host's to say, through the ABI's
`call_depth` slot; a null slot means `abi.default_call_depth`, which
is `backend.Budget`'s default, so both engines refuse the same call.
loom answers `host.call_depth` for the interpreter and the ABI alike.
A host is free to name an enormous number, but the machine's stack is
still finite: a limit above what it can hold is a limit that never
fires.

**The trace costs nothing at all until a trap happens.**  There is no
LLVM debug metadata on this path and none is wanted.  Every exit on
the unwinding path — an inline trap, the edge after a call that
trapped — first calls `luce_rt_unwound` with the function's index and
the instruction it was at, so the trace assembles itself innermost
first as the program leaves.  The names and the source positions
travel as constant data emitted once per module and handed to
`luce_rt_open`; a `--release` artifact emits the names and drops the
origins, so it still prints `at divide / at ratio / at main` with no
lines, exactly as docs/MODES.md describes.  Nothing on the execution
path reads any of it — not a load, not a branch — which is the same
bargain the interpreter strikes.

Because the trace only exists once unwinding is over, the trap is
reported once, from `luce_main`, with everything in it.

Scalars are generated inline: checked integer arithmetic, comparison,
branches, calls.  Everything below the instruction level is a call
into `libluce_rt`.

## `libluce_rt`

`src/luce/runtime.zig` plus
`runtime/{value,heap,containers,text,operators,exports}.zig`.  Luce's
semantics below the instruction level live here: the object heap,
ownership and serials (docs/OWNERSHIP.md), `List`/`Map`/`Array`/
`Builder`, string storage and the String primitives,
`str`/`parse_int`/`parse_float`/`chr`/`ord`, checked arithmetic, and
the trap channel they all report through.

It builds as a real `libluce_rt.a` and installs beside the binaries.
**The interpreter calls it too** — `interpreter/machine.zig` keeps only
the dispatch loop, the frame stack, the traceback, and host effects.
There is exactly one implementation of every semantic, and the
interpreter's suites are what prove it.

The C surface (`runtime/exports.zig`, some 58 `luce_rt_*` entry
points) holds to three conventions:

- **A fallible call returns `i32`; `1` means the program trapped.**
  That is the same edge generated code already uses for a Luce call,
  so there is no second propagation mechanism to keep in step.  `i32`
  rather than `_Bool` because `_Bool`'s width and extension rules are
  the one place LLVM's `i1` and the platform ABI disagree.
- **Results travel through an out-pointer.**  Nothing returns by value
  except a plain scalar answer.
- **A trap is announced once, when the program has stopped.**  A trap
  raised inline by generated code (`luce_rt_raise`) and one raised
  inside the library both land in the same place; every frame records
  itself on the way out (`luce_rt_unwound`); and `luce_rt_report`
  hands the host the code, the words, and the finished call trace
  together.  One channel, reporting the whole trap rather than half of
  it.

Allocation failure is not a Luce trap: no program can cause it
deliberately and none can catch it.  It becomes a status of its own,
so a host can tell "the program failed" from "the machine ran out".

A Luce value crosses the boundary as a pointer to a 24-byte
`runtime.Value` in an entry-block `alloca`.  The layout is asserted
against the Zig struct, so the two cannot drift.

## The published host ABI

`src/luce/08_llvm/abi.zig` is the contract and the only authority on
it; `abi.version` is the number a loader checks.  A compiled artifact
exports one symbol:

```c
int32_t luce_main(const LuceHost *host);   /* 0 ok, 1 trapped, 2 exhausted */
```

`LuceHost` is a flat `extern struct` of `context` followed by one
pointer-sized slot per service, in declaration order, which is exactly
the layout generated code walks with `getelementptr`.  The `Slot` enum
names those positions once so the lowering and the struct cannot
drift.

Effects reach the outside world through this table rather than through
undefined symbols, because an undefined symbol does not link into a
two-level-namespace macOS dylib — and a vtable is the shape
`backend.Host` already has for the interpreter.  *Semantics* do not
come through it: lists, maps, strings, ownership, and the conversions
are `libluce_rt` calls, because they are the language rather than a
capability a host may withhold.

**Three rules hold the whole thing together:**

- **`trap` is required.**  `luce_main` calls it without a null check,
  once, after the program has stopped, with the trap's code, its
  words, its call trace, and the number of frames the trace's cap cut.
  One channel, always present.
- **Every effect service is optional and fails closed.**  A null slot
  traps `host_unavailable` rather than touching anything — the same
  rule the interpreter follows, and what keeps the pure `evaluate()`
  API pure.
- **Every fallible service answers an `Answer`:** `yes` (done, results
  in the out-parameters), `no` (the service said no — the file could
  not be read, the index is out of range; what that means is the
  caller's to decide), or `exhausted` (the host could not get memory,
  which is not a trap and ends the run the way the runtime's own arena
  failure does).  Strings a service hands back are borrowed for the
  call only; generated code copies them into the run's arena.
  Services that cannot fail — `arg_count`, `term_rows`, `term_cols` —
  answer their value directly.

`finished` is the one outbound-only slot: the object leak census at
the end of a run that did not trap.  Memory is explicit in Luce, so
what a program did not free is part of what it did.

Compatibility: **fields are append-only and never reordered** (their
order *is* the layout), any change to an existing field's meaning or
signature bumps `version`, and a loader must refuse an older version
rather than tolerate it.

Version history, which is also the shape of the decisions: **2**
dropped `str_int` — a pure conversion belongs in the runtime, where it
is `luce_rt_str` — and added `finished`.  **3** added the remaining
host services (files, arguments, the terminal) and with them the
single `Answer` convention, which changed `print`'s return type and so
required the bump.  **4** made a trap a whole trap: `trap` carries the
call trace and is called once when the program has stopped, and
`call_depth` arrived beside it, because a trace of a runaway recursion
is only worth having if the recursion traps in the first place.

`key_text` has no slot of its own: it answers what the last `key_read`
carried, which the runtime remembers, so it fails closed on
`key_read`'s slot.

## What is not lowered yet

Each of these fails by naming itself, so the compiler says what is
missing rather than miscompiling:

- **Float** — every constant, local, parameter, arithmetic and
  comparison involving `Float`, plus `convert` (`Int(x)` / `Float(x)`).
- **Struct values** — `struct_make`, `struct_get`, `struct_set`, and
  any struct-typed local or signature.
- **Bytes.**
- **Evaluator ports** — `input_load`, `output_store`, and an entry
  function with parameters.
- **The scalar math intrinsics** — `abs`, `min`, `max`, `clamp`,
  `sqrt`, `floor`, `ceil`.  These want LLVM intrinsics rather than
  runtime calls, which is why they are still open.
- **Every host service except `print`** — `file_read`, `file_write`,
  `file_exists`, `arg_count`, `arg`, all seven `term_*`, `key_read`,
  `key_text`.  The ABI table has slots for all of them; the lowering
  has not caught up.  Check `lower.zig` before trusting this bullet.

Trap reporting is **not** on that list any more: a compiled trap
reports its code, its message, and its call stack with
`file:line:column`, and `--release` strips the lines and keeps the
names, the same as the `.lc` path (docs/MODES.md).

## Building

libLLVM is a hard build dependency of the language module, because the
one code generator calls it in process.  `build.zig` finds it by
asking `llvm-config` — on `PATH` or in the usual Homebrew and
distribution prefixes — for its include directory, library directory,
libraries, system libraries, and C++ runtime.  Point the build
elsewhere with:

```sh
zig build -Dllvm-config=/path/to/llvm-config
```

Both executables link it, because loom compiles too (`loom luce
FILE.luc`, and bare `.luc` paths in the shell).

## Where this goes next

`docs/CODEGEN.md` holds the sequencing.  What remains: close the gaps
above, add the shared-library and executable emit modes (then wasm32),
and delete the interpreter's dispatch loop last.  The runtime library
it calls stays.
