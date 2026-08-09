# What Luce could mean by "at the same time"

> **This is not a decision, and it must not be read as one.**  The
> owner's instruction is the whole warrant: *"we'll pause and think
> about threads — I think we'll need to really think about this
> seriously — gather what are the options and what suits Luce."*  So
> this file gathers.  It surveys what other languages did, prices each
> shape against the invariants Luce already ratified, and ends with the
> questions the owner would have to answer to rule.  It recommends
> nothing.  Every fenced block in it is `text`: these are sketches of
> syntax that does not exist, and the doc guard would be right to
> refuse them as Luce.

The occasion is the ratified path toward a web server — after enums
and `union` (`docs/MISSING.md` Tier 2, owner 2026-08-04: *"Tagged
unions obviously"*) come sockets, HTTP, JSON, and an API server.  A
server is the first program Luce will be asked to write where "wait
for two things at once" is the problem rather than an ornament, and it
is the first place where the answer "there are no threads" stops being
free.  Nothing about that path is blocked today — a single-threaded
accept loop is writable the moment sockets exist — but the shape
chosen for it is very hard to take back, so it is worth choosing on
purpose.

---

## 1. What concurrency would be walking into

Six facts about this tree, each with the file that holds it.  Every
model below is priced against these and nothing else.

**1.1 Aliasing is free and untracked.**  `docs/OWNERSHIP.md` S8: *"`let
x = y` — two names, one object.  No move, no ceremony… aliasing is
free and untracked."*  That is the single most load-bearing sentence in
the memory model, it is what keeps casual code free of memory words,
and **it is sound only because nothing else is running.**  One binding
owns; every other name reads and writes the same object with no
record kept anywhere that it exists.  Add a second thread of control
with access to the same object and there is no place in the design that
could even notice.

**1.2 There is no automatic memory manager, permanently.**
`docs/MEMORY.md` closes with it in the strongest terms the project
uses: *"Reference counting is absent, at every layer: not in the
language, not in the runtime, not behind values.  Scope ownership is
the whole story, and anything that reclaims memory does it because a
scope ended, not because a counter reached zero."*  `docs/OWNERSHIP.md`
lists `share` — opt-in refcounted islands — under *"refused
permanently, not deferred."*  This matters more than it looks, because
**most published designs for safe shared-memory concurrency buy their
safety with a collector** (§2), and that half is not for sale here.

**1.3 There are no first-class functions and no closures.**
`docs/LANGUAGE.md`, "Deliberately absent": *"First-class functions,
closures, tuples…"*.  `docs/MISSING.md` Tier 4 is blunter, and it
already names the subject of this memo: *"Interfaces, inheritance,
operator overloading, async, reflection.  No."*  It also states the
house workaround where the absence bites: *"A `sort_by` taking a
top-level `func` name needs no capture, no lifetime story, and no
interaction with ownership.  Do that; leave closures out."*  Every
model below is scored on whether it forces that door open (§5).

**1.4 A run is a `Runtime`, and it is a parameter — not a global.**
`libluce_rt` has no container-level mutable state; `luce_rt_open`
returns a `*Runtime` and every one of the 72 exports takes it as its
first argument (`src/luce/runtime/exports.zig`).  Generated code
threads it: `08_llvm/lower.zig`'s header says *"every function
therefore carries three hidden arguments before its own: `%host`,
`%rt`, and `%depth`."*  **Two independent runs in one process are
already structurally possible**, and that is the most important
engineering fact in this document.

What is *inside* a `Runtime` is equally important.  `runtime/heap.zig`
holds one object table — a growable `ArrayList` of 128-byte rows —
with `{index, generation}` handles into it, a `free_row` list threaded
through the rows, and a `live` counter that is the leak census.
`resolve` is a load and a compare; `attach` appends and may
**reallocate the table**, and the doc comment on `resolve` says so:
*"The pointer is into the object table and is only good until the next
object is allocated."*  So sharing one `Runtime` between two threads is
not a race on a counter that could be made atomic — it is a reader
holding a pointer that a concurrent allocation frees.  Any
shared-runtime model has to change the table's representation before
it can even discuss a lock.

Ownership is per-run too: `Owner` is `{loose, container, binding:
{serial, local}}`, where `serial` is a frame number of *this* run.

**1.5 Determinism under test is a feature, and it is enforced.**
`src/luce/specs/agree.zig` runs every spec program twice — the oracle
and the compiled artifact — and demands *"the same printed bytes, the
same trap code, the same trap message, the same call trace frame for
frame, the same raised error, and the same leak census"*, plus the
world each arm left behind.  The seeded `World` goes as far as faking
the clock, and says why: *"Two engines cannot agree on a wall clock,
and what is under test is the marshalling, not the calendar."*  A
model whose interleaving is not reproducible does not merely make
tests flaky; **it makes the differential oracle unable to compare
sequences at all**, which is the mechanism `docs/ENGINE.md` chose over
golden files precisely because it catches silent agreement.

**1.6 The host boundary is where effects live, and it has room.**
`08_llvm/abi.zig`: one exported `luce_main(const LuceHost*)`, an
append-only table of 32 slots, every effect optional and fail-closed
(`host_unavailable`), every fallible one answering
`yes`/`no`/`exhausted`.  `Answer` is a non-exhaustive enum, so a new
service is free to define a third answer without disturbing the
thirty-one slots in front of it.  **A scheduler can live behind this
table without the language knowing.**  `sleep_ms` and `key_read`
already block there, and `key_read` already does something a poll would
have to do — it presents the pending frame before it blocks.

**And one program.**  `examples/editor/editor.luc` is already an event loop:

```text
while not state.quit:                       # examples/editor/editor.luc:459,
    let visible = max(term_rows() - 1, 1)   # comments elided
    state.adjust(visible)
    state.frame()                           # draw
    let name = key_read()                   # block for the next event
    if name == none:
        break
    state.key(name, key_text(), visible)    # dispatch on the event
```

The shape candidate A proposes is not new to Luce.  It is the shape of
the only interactive program in the tree.  What the editor has never
needed is a *multiplexed* wait — one call that blocks until any of N
things is ready — and that is the entire delta.

---

## 2. The field

Nine models, each read for one question: **what does it pay, and in
what currency?**  Every claim here carries its source, because a
decision record whose facts about other languages cannot be checked is
a decision record that cannot be trusted about its own.

### 2.1 Go — CSP, and a detector that is an admission

Go's slogan is from *Effective Go*: *"Do not communicate by sharing
memory; instead, share memory by communicating"*, and the paragraph
above it makes the claim the slogan compresses — *"Only one goroutine
has access to the value at any given time.  Data races cannot occur, by
design"*
([go.dev/doc/effective_go#concurrency](https://go.dev/doc/effective_go#concurrency)).
Goroutines are cheap enough to be the unit of everything: *"little
overhead beyond the memory for the stack, which is just a few
kilobytes… It is practical to create hundreds of thousands of
goroutines in the same address space"*
([FAQ](https://go.dev/doc/faq#goroutines)).

**But the language does not enforce the discipline.**  The memory model
(revision of June 6, 2022) defines behaviour for race-free programs —
*"In the absence of data races, Go programs behave as if all the
goroutines were multiplexed onto a single processor"* — and for racy
ones says only that an implementation *"can, upon detecting a data
race, report the race and halt execution"*
([go.dev/ref/mem](https://go.dev/ref/mem)).  Sharing is possible, so
races are possible, so Go ships a detector.  The detector's own
introduction is candid about what that means: it is built on
ThreadSanitizer, *"can detect race conditions only when they are
actually triggered by running code"*, and *"race-enabled binaries can
use ten times the CPU and memory, so it is impractical to enable the
race detector all the time"*
([blog](https://go.dev/blog/race-detector); the docs give *"memory
usage may increase by 5-10x and execution time by 2-20x"*,
[race_detector](https://go.dev/doc/articles/race_detector)).

**And the empirical result is the one that should change minds.**  Tu,
Liu, Song and Zhang studied 171 concurrency bugs across Docker,
Kubernetes, etcd, CockroachDB, BoltDB and gRPC-go (ASPLOS '19,
[DOI](https://doi.org/10.1145/3297858.3304069),
[PDF](https://songlh.github.io/paper/go-study.pdf)).  By cause: 105
shared-memory, 66 message-passing.  But among **blocking** bugs — 85 of
the 171 — message passing was the *larger* half, 49 against 36, and the
paper says so in as many words: *"Contrary to the common belief that
message passing is less error-prone, more blocking bugs in our studied
Go applications are caused by wrong message passing than by wrong
shared memory protection."*  Their tooling numbers are worse news than
the bug counts: Go's built-in deadlock detector found 2 of 21
reproduced blocking bugs, and `-race` found 10 of 20 reproduced
non-blocking ones, several only after ~100 runs.

**What Luce should take from Go.**  Not the mechanism — Go collects
garbage, which settles it (§1.2).  Two lessons.  First, *"channels
make it safe"* is not true and there is a measured paper saying so;
choosing message passing buys freedom from data races and buys a fresh
population of deadlocks in exchange.  Second, a dynamic race detector
is what a language ships when its type system cannot rule races out.
Luce's equivalent already exists in spirit — the generational handle
that turns use-after-free into a trap — and it is worth noticing that
**that check is not race-safe**: `resolve` is an unsynchronized load
and compare (§1.4), so under sharing it would be a detector that itself
races.

### 2.2 Erlang / BEAM — share nothing, and the arena resonance

The Erlang documentation states the model in one sentence: *"Threads of
execution in Erlang share no data, that is why they are called
processes"*
([conc_prog](https://www.erlang.org/doc/system/conc_prog.html)).
Sending copies: *"All data in messages sent between Erlang processes is
copied, except for refc binaries and literals on the same Erlang
node"*
([eff_guide_processes](https://www.erlang.org/doc/system/eff_guide_processes.html)).
A process starts at *"327 words of memory"*, of which 233 are heap and
stack, *"quite conservative to support Erlang systems with hundreds of
thousands or even millions of processes"* (same page).

**The resonance with Luce is exact, and it is the most useful thing in
this survey.**  BEAM's collector is *"a per process generational
semi-space copying collector using Cheney's copy collection algorithm
together with a global large object space"*, and each process's stack
and heap live *"in the same memory block"*
([garbagecollection](https://www.erlang.org/doc/apps/erts/garbagecollection.html)).
That is why BEAM's pauses are local: a collection touches one
process's block.  **A per-process heap that dies whole is what a Luce
run already is** — `luce_rt_open` gives a run an arena and
`luce_rt_close` drops it in one go (`runtime/exports.zig`) — which
means Luce gets the *property* that makes BEAM's collector cheap
without having a collector at all.  The isolation is the design; the
collector is BEAM's way of coping with what happens inside one
process, and Luce copes with that by scope ownership instead.

**And the one exception is exactly the one Luce cannot copy.**  Erlang
does share something: binaries larger than 64 bytes are *refc*
binaries, held outside every process heap with *"a reference counter to
keep track of the number of references"*
([binaryhandling](https://www.erlang.org/doc/system/binaryhandling.html)).
That is the escape hatch that makes large-payload messaging cheap in a
copying system — and `docs/MEMORY.md` forbids it at every layer.  So a
Luce message-passing design is Erlang's **without the optimization
Erlang needed**: every send is a real copy, at every size.  Whether
that is acceptable is a measurement, and it is a question for the owner
(§6).

Two more mechanisms worth knowing.  Preemption is by a fixed
*reduction* budget per scheduling quantum: a process runs until it
exhausts its budget or blocks in a `receive` with no matching message
([theBeamBook,
scheduling](https://github.com/happi/theBeamBook/blob/master/chapters/scheduling.asciidoc);
the constant `CONTEXT_REDS` is 4000 since OTP 20, 2000 before, and
lives in the OTP source rather than the user-facing docs).  And "let it
crash" is not a slogan but a structure: supervision trees of *"workers
and supervisors"*
([design_principles](https://www.erlang.org/doc/system/design_principles.html)),
bidirectional links and unidirectional monitors
([ref_man_processes](https://www.erlang.org/doc/system/ref_man_processes.html)),
argued from Armstrong's 2003 thesis
([PDF](https://erlang.org/download/armstrong_thesis_2003.pdf)).
Luce's trap model — a trap ends the run, cleanly, with everything
reclaimed (S34) — is a supervision tree with exactly one worker.  A
worker model would make the analogy literal.

### 2.3 Pony — the closest published relative, studied hardest

Pony is the language a Luce reader should study first, because its
central idea is Luce's central idea taken further: **an ownership
system that makes concurrency safe without a borrow checker.**
`consume` is `give` almost verbatim; its actor references are values;
and its designers were explicitly trying to avoid Rust's lifetimes.

**The mechanism, inverted from the obvious one.**  A Pony reference
capability says what *other aliases are denied*, not what this
reference may do: *"We use a matrix of deny properties, with notions
such as isolation, mutability, and immutability all being derived from
these properties"* (Clebsch, Drossopoulou, Blessing, McNeil, *Deny
capabilities for safe, fast actors*, AGERE 2015,
[PDF](https://www.ponylang.io/media/papers/fast-cheap.pdf)).  The
matrix has two axes — what is denied to aliases in *this* actor, and
what is denied to aliases in *any* actor — and the six capabilities are
its cells
([tutorial](https://tutorial.ponylang.io/reference-capabilities/capability-matrix.html)):

```text
                        deny global RW   deny global W   deny nothing global
  deny local RW              iso              --                --
  deny local W               trn             val                --
  deny nothing local         ref             box               tag
                          (mutable)      (immutable)        (opaque)
```

Read off the [guarantees
page](https://tutorial.ponylang.io/reference-capabilities/guarantees.html):
`iso` is *"the only variable anywhere in the program that can read from
or write to that object"*; `trn` is *"write unique"* without being read
unique; `ref` is mutable but actor-local; `val` is *"globally
immutable"*; `box` is *"locally immutable"*; `tag` *"can't be used to
either read from or write to the object; hence the name opaque"* — and
`tag` is what an actor reference is, which is how actors become
first-class values.  **Sendable is exactly the diagonal**: `iso`, `val`
and `tag`, because only those three deny the same things locally and
globally.

**And the machinery that makes it usable is where the cost lives.**
Aliasing is an operation on types (`iso! = tag`, `trn! = box`);
ephemeral types (`iso^`) exist because *"an isolated type cannot be
assigned to a field"*; `consume` empties a variable and the compiler
refuses every later read; `recover` promotes a capability inside a
block whose only inputs may be sendable; and field reads go through
**viewpoint adaptation**, a second matrix composing the origin's
capability with the field's — *"reading a `ref` field from an `iso`
reference returns `tag`"* (paper §4;
[aliasing](https://tutorial.ponylang.io/reference-capabilities/aliasing.html),
[consume](https://tutorial.ponylang.io/reference-capabilities/consume-and-destructive-read.html),
[recover](https://tutorial.ponylang.io/reference-capabilities/recovering-capabilities.html)).

**Three findings that matter more than the mechanism.**

*First, and it is the decisive one for Luce:* **Pony has garbage
collection.**  Per-actor heaps are collected per-actor, and objects
shared between actors are collected by ORCA, which is *"a concurrent
and parallel garbage collector for actor programs"* that *"tracks
dependencies by deferred reference counts"* and *"piggy-backs reference
updates on actor message passing"* (Clebsch, Blessing, Franco,
Drossopoulou, *Orca: GC and type system co-design for actor
languages*, OOPSLA 2017,
[PDF](http://janvitek.org/pubs/oopsla17a.pdf)).  The type system's
contribution is that it removes the *barriers*, not the collector:
invariant I1 — *"if an actor may write to an object, then no other
actor can read from or write to this object's fields"* — is what lets
ORCA *"avoid write barriers"* and trace *"without synchronisation"*.
So the closest published relative of Luce's ownership model achieves
safe sharing by **pairing capabilities with a collector and a deferred
reference count**, and `docs/MEMORY.md` has refused both halves of that
pairing, permanently and by name.  Anyone proposing capabilities for
Luce inherits an unsolved problem Pony did not have to solve: what
frees a `val` that two workers can both see, when the answer may not be
a counter and may not be a collector.

*Second, the complexity is not free and the bill is still arriving.*
The 2015 paper did not prove soundness — *"In future work, we intend to
extend the formalisation in this paper to prove soundness"* (§8) — and
the published viewpoint-adaptation table turned out to be wrong:
`trn->trn` was corrected from `trn` to `box` in 2020 to close a
soundness hole
([ponyc#3572](https://github.com/ponylang/ponyc/issues/3572)).  A
search of `ponylang/ponyc` for issues titled "soundness" returns a
steady series across a decade, including *"`iso` being a subtype of
`trn` is unsound with covariant methods"*
([#1964](https://github.com/ponylang/ponyc/issues/1964), open nearly
four years) and a 2026 arrow-type reification bug whose fix was a
breaking change
([#4963](https://github.com/ponylang/ponyc/issues/4963)).  The design
is well studied; the *interaction* of viewpoint adaptation, generics,
automatic receiver recovery, match bindings and subtyping has produced
exploitable data-race holes in the shipping compiler roughly every
couple of years.

*Third, the project says the learning curve is the problem.*  Pony's
own learning page: *"If you are like most people learning Pony, your
biggest stumbling block is going to be reference capabilities… Lots of
folks get frustrated while learning reference capabilities and end up
thinking that Pony has 'too much type system' or is 'too hard'"*
([ponylang.io/learn](https://www.ponylang.io/learn/reference-capabilities/)),
and the tutorial's matrix page opens *"We have all struggled when
learning this part of Pony, too."*  LWN's assessment is the fair
counterweight — you learn *"six specific types of pointer, instead of
arbitrary lifetimes"* as in Rust
([LWN, Jan 2025](https://lwn.net/Articles/1001224/)) — but for a
language whose stated aim is that casual code contains no memory
words, six capabilities is not a small ask.

**Two footnotes, because a decision record should be accurate about
its exemplars.**  Pony is actively maintained (ponyc 0.68.0, 1 August
2026, on a one-to-three-week cadence,
[releases](https://github.com/ponylang/ponyc/releases)) and still
pre-1.0 by its own README.  And the one well-documented production
user, Wallaroo Labs, moved to Rust in 2021 — but the reasons they gave
were *"the more robust ecosystem of existing libraries available for
Rust"*, community size, and hiring, plus a product pivot
([writeup](https://www.wallaroo.ai/blog/wallaroo-move-to-rust)).
**None of their stated reasons was that the capabilities did not
work**, which is the more uncomfortable finding rather than the less:
the type system was not what failed.

**Pony also has closures**, and they interact with capabilities in a way
worth recording: a lambda desugars to an object with an `apply` method,
captures make it `ref` by default, and **a capturing lambda is
therefore not sendable** unless everything it captured is
([object literals](https://tutorial.ponylang.io/expressions/object-literals.html)).
That is the closure problem (§5) reappearing inside the capability
system rather than being solved by it.

### 2.4 The single thread, taken seriously — Node, redis, nginx

Three unrelated production systems chose one thread of control for
state and **drew the same line in the same place**, which is the most
transferable finding in this survey.

**Node/libuv.**  The loop has named phases — timers, pending callbacks,
poll, check, close — and *"node will block here when appropriate"* in
the poll phase
([event loop](https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick)).
Network I/O is genuinely non-blocking: *"all (network) I/O is performed
on non-blocking sockets which are polled using the best mechanism
available on the given platform: epoll on Linux, kqueue on OSX…"* —
but **file I/O is not**, and libuv says why: *"Unlike network I/O,
there are no platform-specific file I/O primitives libuv could rely on,
so the current approach is to run blocking file I/O operations in a
thread pool"*
([design](https://docs.libuv.org/en/v1.x/design.html)), whose default
size is four
([threadpool](https://docs.libuv.org/en/v1.x/threadpool.html)).  The
hazard is documented as a *security* property, not only a performance
one: *"If it is possible that for certain input one of your threads
might block, a malicious client could submit this 'evil input', make
your threads block, and keep them from working on other clients.  This
would be a Denial of Service attack"*
([Don't Block the Event
Loop](https://nodejs.org/en/learn/asynchronous-work/dont-block-the-event-loop)).

**redis.**  *"Redis is, mostly, a single-threaded server from the POV
of commands execution… It is not designed to benefit from multiple CPU
cores"*, and it reaches 180,180 SET/s with 50 clients and no
pipelining, 1.5 M/s with pipelining of 16
([benchmarks](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/benchmarks/)).
antirez's argument for the choice is the one a Luce reader should
weigh, because it is an argument about *data structures*, not about
throughput: *"A multi-threaded on-disk store is mandatory.  A
multi-threaded complex in-memory system is in the middle where things
become ugly: Redis clients are not isolated, and data structures are
complex.  A thread doing LPUSH need to serve other threads doing LPOP.
There is less to gain, and a lot of complexity to add"*
([antirez.com/news/126](https://antirez.com/news/126)).  Redis 6.0 then
added threaded I/O anyway — *"not only… threads for writes… but also
use threads for reads and protocol parsing"* — and left command
execution serial (`redis.conf`, THREADED I/O; release notes
[6.0.0](https://raw.githubusercontent.com/redis/redis/6.0.0/00-RELEASENOTES)).

**nginx.**  *"Each worker process is single-threaded and runs
independently, grabbing new connections and processing them"*, with the
recommended configuration *"one worker process per CPU core"*, and
*"NGINX can scale to handle hundreds of thousands of concurrent HTTP
connections per worker process"*
([Inside NGINX](https://blog.nginx.org/blog/inside-nginx-how-we-designed-for-performance-scale)).
Since 1.9.1 the kernel does the load balancing: `reuseport` *"instructs
to create an individual listening socket for each worker process (using
the `SO_REUSEPORT` socket option…), allowing a kernel to distribute
incoming connections between worker processes"*
([docs](https://nginx.org/en/docs/http/ngx_http_core_module.html)),
measured at *"2 to 3 times"* the requests per second with latency
standard deviation collapsing from 26.59 ms to 3.15 ms
([benchmark](https://www.f5.com/company/blog/nginx/socket-sharding-nginx-release-1-9-1)).
And nginx pays libuv's file-I/O tax too, with the same remedy: `aio
threads` since 1.7.11
([thread pools](https://www.f5.com/company/blog/nginx/thread-pools-boost-performance-9x)).

**The through-line, and it is the sentence to carry into the ruling:**
none of these three is "single-threaded" as a slogan.  All three are
*single-threaded for state mutation, with threads bolted on exactly
where the kernel refuses to make an operation asynchronous.*  Three
independent projects hit that seam and drew the line in the same place.
For Luce that maps precisely: the Luce program stays single-threaded
and the **host** — which already owns raw mode, buffering and every
escape byte (§1.6) — is where a thread pool would go if `file_read` had
to stop stalling the loop.  Nothing about the language would know.

The lineage under all of it is Kegel's C10K problem
([kegel.com/c10k.html](http://www.kegel.com/c10k.html)) and the
primitives that answered it: kqueue in FreeBSD 4.1
([Lemon, USENIX 2001](https://www.usenix.org/legacy/publications/library/proceedings/usenix01/freenix01/lemon.html))
and `epoll` in Linux 2.5.44
([epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html)).
That is the one host slot candidate A actually needs.

### 2.5 Rust — the price of proving it

Rust is the one language in this survey that prevents data races
statically without collecting garbage, which makes it the direct
comparison for anything Luce might attempt.  The marker traits are two
sentences: *"A type is Send if it is safe to send it to another thread.
A type is Sync if it is safe to share between threads (T is Sync if and
only if `&T` is Send)"*
([nomicon](https://doc.rust-lang.org/nomicon/send-and-sync.html)).

**What is worth Luce's attention is the dependency chain.**  `Send` and
`Sync` do not stand alone; they are the top of a stack that begins with
ownership and lifetimes.  `thread::spawn`'s signature says so out loud
— `F: FnOnce() -> T + Send + 'static` — and the docs explain each
bound: *"The `'static` constraint means that the closure and its return
value must have a lifetime of the whole program execution… threads can
outlive the lifetime they have been created in"*, and *"The `Send`
constraint is because the closure will need to be passed by value from
the thread where it is spawned to the new thread"*
([std::thread::spawn](https://doc.rust-lang.org/std/thread/fn.spawn.html)).
Lifetimes, ownership, closures and marker traits all appear in one
signature, and none of them is optional.  The 2015 *Fearless
Concurrency* post names the same dependency from the other end:
*"Rust's secret weapon is ownership… many languages provide memory
safety through garbage collection.  But garbage collection doesn't give
you any help in preventing data races"*
([blog](https://blog.rust-lang.org/2015/04/10/Fearless-Concurrency/)).
`Rc` is the worked example of why: *"Rc isn't Send or Sync (because the
refcount is shared and unsynchronized)"*, and `Arc` pays atomics for
the privilege.

**The async half is the cautionary part, and its designers say so.**
Function coloring is the standard name, from Bob Nystrom's 2015 essay:
*"You've still divided your entire world into asynchronous and
synchronous halves and all of the misery that entails"*
([What Color is Your
Function?](https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/)).
Rust's own async book concedes the rule — *"`await` can only be used
inside an async context"* — and the gaps: *"there are some missing
parts and rough edges… Some uses of async in traits are not yet
well-supported.  There is not a good solution for async destruction"*
([async book](https://rust-lang.github.io/async-book/)).  `Pin` exists
because a suspended frame is self-referential: *"if that value is
moved, the pointer will still point to the old address… A key example
of such self-referential types are the state machines generated by the
compiler to implement `Future` for `async fn`s"*
([std::pin](https://doc.rust-lang.org/std/pin/index.html)).  The
feature's own designer wrote, eight years in, *"The `Pin` type itself
has been the source of a fair amount of consternation"* and called one
consequence *"an unforced error"*
([without.boats, *Why async
Rust?*](https://without.boats/blog/why-async-rust/)).  `async fn` in
traits stabilized only in Rust 1.75 (December 2023) and still lacks
`dyn` support and a clean answer to `Send` bounds
([announcement](https://blog.rust-lang.org/2023/12/21/async-fn-rpit-in-traits/)).
There is no executor in `std`, so the ecosystem is coupled to
runtimes: *"Executor coupling is a big problem for async Rust as it
breaks the ecosystem into silos"*
([corrode.dev](https://corrode.dev/blog/async/)).

**And one line from that post is the single most relevant sentence in
this whole survey for Luce**: *"Rust could not adopt this approach
[green threads] because Rust does not have a garbage collector"*
(without.boats, above).  The absence of a collector is precisely what
forced Rust into stackless futures, `Pin`, coloring, and a decade of
ergonomics work.  **Luce shares that constraint and has less type
system to pay with.**

### 2.6 Java's virtual threads — make blocking cheap instead

Project Loom is the counter-argument to async/await, made by a platform
that could afford the alternative.  A virtual thread is *"an instance
of `java.lang.Thread` that is not tied to a particular OS thread"*,
scheduled M:N onto carrier threads by a work-stealing `ForkJoinPool`,
with stacks *"stored in Java's garbage-collected heap as stack chunk
objects"*
([JEP 444](https://openjdk.org/jeps/444), final in JDK 21, September
2023).

**The argument is about which style is readable, and it is worth
reading in full** because it is the same argument Luce would have.  JEP
444: asynchronous pipelines mean developers *"must break down their
request-handling logic into small stages… They thus forsake the
language's basic sequential composition operators, such as loops and
try/catch blocks"*, with the consequence that *"stack traces provide no
usable context, debuggers cannot step through request-handling logic,
and profilers cannot associate an operation's cost with its caller."*
Its Alternatives section rejects `async`/`await` by name: *"It would
split the world between APIs designed for threads and APIs designed for
coroutines."*  Ron Pressler's *State of Loom* is blunter: the async
style *"fights the design of the Java platform at every turn and pays a
high price in maintainability and observability"*
([cr.openjdk.org](https://cr.openjdk.org/~rpressler/loom/loom/sol1_part1.html)),
and its takeaway list reads *"Blocking a virtual thread is cheap — be
synchronous!  No language changes are needed."*

**Two facts that keep this from being a model Luce can copy.**  The
stacks live in the garbage-collected heap (§1.2 again), and virtual
threads do **not** remove data races — the Java memory model applies
unchanged, and Pressler says so: *"virtual threads exhibit the same
memory consistency — specified by the Java Memory Model — as platform
`Thread`s."*  Loom made concurrency *cheap*; it did nothing to make it
*safe*.  Java tolerates that because it has been tolerating it since
1995.

**And one caution about maturity.**  `synchronized` blocks pinned a
virtual thread to its carrier until JEP 491 fixed it in JDK 24 (March
2025) — *"this will eliminate nearly all cases of virtual threads being
pinned"* ([JEP 491](https://openjdk.org/jeps/491)) — and *structured
concurrency*, the API that makes any of this composable, has been in
preview through **JEP 428, 437, 453, 462, 480, 499, 505, 525 and 533**
and is still not final in JDK 27
([JEP 533](https://openjdk.org/jeps/533)).  Nine rounds.  A language
with vastly more resources than this project has spent a decade on the
part that comes *after* the primitive.

Pressler's other essay is the one to keep for a different reason: the
benefit of user-mode threads *"has little to do with task-switching
costs"* — with a 1 µs switch against a 20 µs wait, *"the best we can
hope for by optimizing task-switching is to increase our capacity by
5%"*
([inside.java](https://inside.java/2020/08/07/loom-performance/)).  The
win is the number of requests in flight, which a single-threaded event
loop also gets.

### 2.7 Swift — actors, and a public retreat from the friction

Swift built the full modern stack: `async`/`await` (SE-0296),
structured concurrency (SE-0304) and actors (SE-0306) in 5.5,
`Sendable` (SE-0302) in 5.7, global actors (SE-0316), and in Swift 6 a
language mode that *"extends Swift's safety guarantees to prevent data
races in concurrent code by diagnosing potential data races in your
code as compiler errors"*
([swift.org](https://www.swift.org/blog/announcing-swift-6/)).

**Two findings matter here.**

*First, actor isolation does not buy atomicity across a suspension,*
and SE-0306 says so in the section on reentrancy: *"actor-isolated
state can change across an `await` when an interleaved task mutates
that state, meaning that developers must be sure not to break
invariants across an await"*, and *"reentrant actors are thread-safe
but are not automatically protecting from the 'high level' kinds of
races that may still occur"*
([SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md#actor-reentrancy)).
The proposal's own example is annotated with a raised-eyebrow emoji in
the source.  A model that eliminates data races and leaves logical
races is exactly what §2.1's Go study measured from the other side.

*Second — and this is the finding worth the owner's attention — Swift
publicly walked it back.*  The Language Steering Group endorsed a
vision document whose text is remarkable for an official artifact:
*"The Swift 6 language mode provides a baseline of correctness… but
sometimes it comes at the cost of the second [goal], and it can be
frustrating to adopt"*; *"**Writing a single-threaded program is
surprisingly difficult under the Swift 6 language mode.**  This is
because Swift 6 defaults to a presumption of concurrency"*; and *"if
there isn't any use of concurrency, the entire program will run
sequentially, and there's no risk of data races — every concurrency
diagnostic is necessarily a false positive!"*
([Improving the approachability of data-race
safety](https://github.com/swiftlang/swift-evolution/blob/main/visions/approachable-concurrency.md)).
Swift 6.2 then shipped SE-0461, which **reverses** SE-0338 and runs
nonisolated async functions on the caller's actor by default, and
SE-0466, a `-default-isolation` setting introduced explicitly *"to
mitigate false-positive data-race safety errors in sequential code"*.
Roughly eight of the dozen concurrency proposals in 6.2 exist to soften
6.0.

**The lesson for a language whose stated aim is Python ease.**  Swift
paid the annotation cost across its whole ecosystem and then decided
the cost fell hardest on the programs that were never concurrent in the
first place.  Luce's corpus is entirely such programs.  Whatever model
is chosen, **a Luce program that does not ask for concurrency must not
acquire one word of ceremony because concurrency exists.**  That is a
constraint the field has now paid to learn.

### 2.8 Zig — the cautionary tale, and it is this tree's own toolchain

Zig had `async`/`await` — reworked in 0.5.0 (2019), stackless
coroutines, and the release notes claimed it escaped function coloring
because code could *"work in both an async context and blocking
context"*
([0.5.0 notes](https://ziglang.org/download/0.5.0/release-notes.html)).
It lived in the bootstrap compiler.  The self-hosted compiler never
implemented it, and 0.10.0's notes are the honest record: *"async/await
is not done yet (#6025).  Users of async/await cannot upgrade until a
few more months when this feature is complete"*
([0.10.0 notes](https://ziglang.org/download/0.10.0/release-notes.html)).
0.11.0 made the self-hosted compiler mandatory and the feature simply
became unavailable.  Issue
[#6025](https://github.com/ziglang/zig/issues/6025) — "re-introduce the
async/await language feature which existed in the bootstrap compiler,
with the same semantics as before" — is now **closed as not planned**.
Five years without it.

**What went wrong is a design mistake a language project can make once
and cannot easily undo: the execution model was in the language.**
`async` in stage1 *meant* stackless coroutines, and the compiler had to
know how to split every frame.  When the compiler was rewritten, that
machinery was the piece that did not come across.

**What replaced it is the most directly applicable idea in this
survey.**  Zig 0.16.0 (14 April 2026 — the version this repository
pins) makes the execution model a *runtime value*: *"all input and
output functionality requires being passed an `Io` instance"*, where
`Io` is *"a lot like setting up an allocator.  You typically do it
once, in `main()`, and then pass the instance throughout the
application"*
([0.16.0 notes](https://ziglang.org/download/0.16.0/release-notes.html);
[Kelley](https://andrewkelley.me/post/zig-new-async-io-text-version.html)).
`io.async` expresses only *asynchrony* — *"the possibility for tasks to
run out of order and still be correct"* — and is infallible and
portable even to an `Io` with no concurrency at all; `io.concurrent`
demands actual concurrency and can therefore fail
([Cro, *Asynchrony is not
Concurrency*](https://kristoff.it/blog/asynchrony-is-not-concurrency/)).
The same source code runs blocking, on a thread pool, or on green
threads depending on what `main` handed down.  LWN's coverage records
the fair criticism — the `Io` parameter is coloring by another name —
alongside the reason it is the better trade: it colors one ecosystem
rather than splitting it into two
([LWN, Dec 2025](https://lwn.net/Articles/1046084/)).

**Two things Luce should take from this, and they point in opposite
directions.**  The warning: do not put an execution model in the
language, because the language is the thing you cannot revise.  The
opportunity: `CLAUDE.md` already requires that *"anything host-facing
takes an explicit `std.Io`"*, and §1.6 already makes every effect a
host-table slot.  **Luce's host table is structurally the same idea as
Zig's `Io`, one level down** — which means the "who decides how this
blocks" question already has a place to live in this design, and it is
not the language.

### 2.9 Isolates and workers — what copying costs in practice

The browser's answer is share-nothing with an explicit escape hatch.
Workers *"run in another global context"*, and *"when a message is
passed between the main thread and worker, it is copied or 'transferred'
(moved), not shared"*
([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Web_Workers_API/Using_web_workers)).
The structured clone algorithm *"clones by recursing through the input
object while maintaining a map of previously visited references, to
avoid infinitely traversing cycles"* — it handles cycles, which JSON
does not — but it refuses functions outright: *"`Function` objects
cannot be duplicated by the structured clone algorithm; attempting to
throws a `DataCloneError`"*
([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Web_Workers_API/Structured_clone_algorithm)).
**That refusal is the closure question (§5) restated as a runtime
error**, and it is one of the reasons a Luce worker model would be
cleaner than the web's: with no first-class functions there is nothing
to refuse.

Transferables are the zero-copy path, and their rule is Luce's `give`:
*"the resources are only available in one context at a time.  Following
a transfer, the original object is no longer usable"*
([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Web_Workers_API/Transferable_objects)).
Genuine sharing needs `SharedArrayBuffer` plus `Atomics`, and after
Spectre that requires cross-origin isolation — `Cross-Origin-Opener-Policy:
same-origin` plus `Cross-Origin-Embedder-Policy: require-corp` or
`credentialless`
([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Window/crossOriginIsolated));
*"shared memory and high-resolution timers were effectively disabled at
the start of 2018 in light of Spectre."*  **Shared memory turned out to
have a security cost nobody priced in when it was designed** — a fact
worth having in front of anyone weighing candidate C.

WebAssembly is the clearest illustration that the split has not been
resolved.  The threads proposal is at Phase 4 and is the only proposal
there, but it is not in the finished list and **is not part of Wasm
3.0**
([proposals](https://github.com/WebAssembly/proposals);
[Wasm 3.0](https://webassembly.org/news/2025-09-17-wasm-3.0/)); it also
defers thread lifecycle entirely — *"the responsibility of creating and
joining threads is deferred to the embedder"*
([threads
overview](https://github.com/WebAssembly/threads)).  The
shared-everything-threads proposal, still a Phase 1 draft, states the
gap plainly: *"There is no way to use threads with WasmGC programs at
all because there is no way to share reference values across
threads"*
([repo](https://github.com/WebAssembly/shared-everything-threads)).
Meanwhile the component model went the other way: *"a component
interacts with a runtime or other components only by calling its
imports and having its exports called"*, and components' memories *"are
never exported or imported; they are not shared"*
([component
model](https://component-model.bytecodealliance.org/design/components.html)).
`wasi-threads` is now labelled by its own README *"a legacy proposal,
retained for engines that can only support WASI v0.1"*
([repo](https://github.com/WebAssembly/wasi-threads)).  Luce's backend
already registers WebAssembly as a target (`08_llvm/emit.zig`); a
concurrency model that depends on shared memory would be a model that
does not reach it.

Two more data points on copying, because candidate B lives or dies on
them.  **Cloudflare Workers** run *"hundreds or thousands of isolates"*
in one runtime with *"each isolate's memory… completely isolated"*,
starting in 5 ms against 500 ms–10 s for a container, and needing about
3 MB where a Node Lambda needs 35, *"when you can share the runtime
between all of the Isolates"*
([how it works](https://developers.cloudflare.com/workers/reference/how-workers-works/);
[blog](https://blog.cloudflare.com/cloud-computing-without-containers/)).
And **CPython** arrived at the same place from the opposite direction:
PEP 684 gave each subinterpreter its own GIL in 3.12, PEP 734 landed
`concurrent.interpreters` in 3.14, and the docs make the payoff and the
price explicit — *"interpreters are sufficiently isolated that they do
not share the GIL, which means combining threads with multiple
interpreters enables full multi-core parallelism"*, while *"by default,
most objects are copied with `pickle` when they are passed to another
interpreter"*
([docs](https://docs.python.org/3/library/concurrent.interpreters.html)).
The parallel free-threading effort (PEP 703, accepted with the Steering
Council's proviso *"that we can roll back any changes that turn out to
be too disruptive"*) reached officially-supported status only in 3.14
via PEP 779, still costing *"roughly 5-10%"* single-threaded
([whatsnew 3.14](https://docs.python.org/3/whatsnew/3.14.html)).

**Two mechanisms, one runtime each, and one is far easier.**  Every
project on this list that wanted multicore without redesigning its
memory model got there by running N isolated copies, and every one that
wanted shared memory paid for years.

### 2.10 What the nine have in common

Four patterns, and they are the whole reason to read §2 before §4.

1. **Every language that permits shared mutable state either collects
   garbage or proves aliasing statically.**  Go, Erlang, Java and Swift
   collect.  Rust and Pony prove — and Pony *also* collects, because
   proving aliasing tells you when a write is safe, not when the last
   reader is done.  Luce has refused collection permanently (§1.2) and
   has no static alias tracking (§1.1).  It currently sits in the one
   cell of that table that is only habitable while nothing is shared.
2. **The two designers who said out loud why they could not have green
   threads both gave the same reason**, and it is the absence of a
   collector: Rust's async lead
   ([without.boats](https://without.boats/blog/why-async-rust/)) and, by
   construction, Java's — whose virtual-thread stacks are heap objects.
3. **The languages that shipped an execution model in the language
   regret it; the ones that shipped it as a value do not.**  Zig's 2019
   `async` died with its compiler and came back as a parameter;
   Rust's futures brought `Pin` and coloring; Java rejected
   `async`/`await` explicitly to avoid *"split[ting] the world"*.  Luce
   already has the seam these all converged on — a host table of effect
   slots.
4. **The friction lands on the programs that never asked.**  Swift's own
   steering group wrote that *"writing a single-threaded program is
   surprisingly difficult under the Swift 6 language mode"* and spent a
   release walking it back.  Luce's entire corpus is single-threaded
   programs.

---

## 3. The one page

Read the columns, not the rows.  **What it preserves** is measured
against §1; **what it breaks** names the invariant it costs;
**migration** is where the work lands in this tree; **forecloses** is
what taking it makes hard to take back.

| Model | Preserves | Breaks | Migration cost | Forecloses |
|---|---|---|---|---|
| **A. Single-threaded event loop** (Node, redis, nginx worker) | S8, no collector, no closures, the oracle, determinism — all of §1 | Nothing in the language.  One core; a slow call stalls every connection | Host slots only: sockets + one `wait`.  `abi.version` +1, appending.  No stage 4 work | Nothing.  A loop is also what a worker is |
| **B1. In-process workers, copying messages** (Erlang, isolates) | S8 *within a run*; no collector (each run's arena dies whole); no closures | Nothing in stage 4.  Adds a channel — the first thing S33's three owner kinds do not cover | Channel primitive in `libluce_rt`, cross-runtime deep copy, a scheduler, a second arm for `agree` | Shared mutable state later, because the corpus will have been written to copy |
| **B2. Out-of-process workers** (nginx, CGI, `SO_REUSEPORT`) | Everything.  Each process is one ordinary run | Nothing | One spawn slot, or none at all | Nothing; strictly the cheapest real multicore |
| **C. Reference capabilities** (Pony) | Static safety with no runtime check — the only row that gets real shared-memory parallelism | **S8** (aliasing stops being free), **S39** (`val` needs the const-ness type system it declined), and it needs a reclamation story for shared data that is neither counter nor collector — which Pony solved with a collector | The largest by far, concentrated in stage 4; six capabilities, two type operators, viewpoint adaptation | Nothing technically; practically it changes what learning Luce means |
| **D. Deterministic parallelism** (fork-join over disjoint slices) | Everything, including determinism *exactly* — the oracle needs no new arm | Nothing, if the region provably allocates and frees nothing | An analysis in stage 4 and a runtime split; no new semantics | Nothing.  Composes with every other row |
| **E. Decide nothing; write it single-threaded** | Everything | Nothing | Zero | Only Q6: a blocking socket API is hard to un-block later |
| *Surveyed and not proposed:* shared memory + a race detector (Go) | — | S8's soundness, and the detector itself would race (§2.1) | — | — |
| *Surveyed and not proposed:* `async`/`await` futures (Rust, Swift, JS) | — | Forces closures or a state-machine lowering; function coloring; `Pin`-shaped self-reference problems | A whole new lowering in stage 8 | — |
| *Surveyed and not proposed:* green/virtual threads (Go, Java, BEAM) | — | Every shipped implementation is paired with a collector; the one language without one (Rust) says that is exactly why it could not (§2.5) | — | — |

---

## 4. The candidates

### A. One thread, one loop, one new host service

**The shape.**  Nothing in the language changes.  The host grows a
socket family and one multiplexing wait, and a server is an ordinary
Luce `while` loop:

```text
let listener = try net.listen(8080)
var live = new map(long, Connection)          # per-connection state
while true:
    let ready = try net.wait(-1)              # blocks until something can move
    for handle in ready:
        if handle == listener:
            let client = try net.accept(listener)
            live[client] = Connection(...)    # a struct, not a closure
        else:
            serve(live, handle)               # read, parse, maybe write
```

**What it preserves: everything.**  S8 stays true because there is one
thread of control.  No collector.  No closures — the per-connection
state that a callback language would capture is a `struct` in a `map`,
which is the same trade `docs/MISSING.md` already took for
comparators.  The oracle is untouched: the program's prints are a
deterministic sequence given a deterministic `wait` order, so `agree`
compares exactly what it compares today.  `format_version` does not
move; `abi.version` moves once, appending slots at the end the way
version 8 and version 11 appended theirs.

**What it costs.**  One core, and the well-documented hazard that goes
with it: any single call that takes a long time stops every connection
(§2.4).  Two specific Luce shapes make that sharper than it is in Node.
`file_read` is a blocking host slot with no non-blocking form, so a
server that touches disk stalls its own loop — Node answers this with
a thread pool behind libuv, which is a host-side answer Luce could copy
without the language knowing.  And Luce has no way to yield in the
middle of a computation, so a slow `for` loop over a big list is
unpreemptable; BEAM's answer to exactly this is reduction counting
(§2.2), which requires a scheduler the language does not have.

**Where it runs out.**  At the point where one core is not enough.  The
escape from that is not inside candidate A at all — it is candidate B,
and A composes with B rather than competing with it (nginx runs N
single-threaded workers, §2.4).

**Migration cost: near zero.**  It is the largest std addition on the
roadmap and no language work at all.

**What it forecloses: nothing**, which is the strongest thing that can
be said for it.  Every other candidate can be built later *over* a
program written this way, because "the program is a loop" is also what
a worker is.

**And it is the shape §2.8's lesson recommends.**  Zig's redesign moved
the execution model out of the language and into a value handed down
from `main`; Luce's host table is already that value one level lower.
A `wait` slot leaves the choice of *how* the host waits — `epoll`,
`kqueue`, a thread pool for the file calls — entirely on the host side,
where §2.4 says all three production systems put it.

### B. Share nothing: N runs, messages that copy

**The shape.**  More than one Luce run, each with its own `Runtime`,
none of them touching the other's objects.  Two sub-shapes, and they
are very different in cost:

- **B1, in-process.**  N `luce_main`s on N OS threads, one `Runtime`
  each.  Already structurally possible (§1.4): the runtime is a
  parameter, there are no globals, and a `.lc` statically links its own
  copy of `libluce_rt`.
- **B2, out-of-process.**  N `loom` processes behind one listening
  socket, which is nginx's model and CGI's before it.  Costs the
  language *nothing at all* — one host slot to spawn, or not even that
  if a supervisor outside Luce does the spawning.

**What a message can be, precisely.**  This is where the design is
decided, and Luce's existing rules answer most of it:

- **Values travel by copying, which is already the rule.**  A scalar,
  a `string`, a plain struct: `docs/STRINGS.md` made every store site a
  real copy of the bytes, so "a value copies into the channel" adds no
  rule — it applies an existing one at one more site.
- **An object cannot travel as a handle.**  A handle is `{index,
  generation}` into the *sender's* table (§1.4), and every nested
  element is another such handle.  So sending an object is a deep walk:
  O(objects) to re-handle into the receiver's table and O(bytes) to
  re-intern its strings in the receiver's arena.  **That is Erlang's
  `!` exactly** (§2.2) — and the one exception Erlang grants itself,
  sharing large binaries by reference count, is precisely what
  `docs/MEMORY.md` forbids.  So Luce's version of Erlang's send is
  Erlang's send *without* the escape hatch: always a copy, no size
  threshold, nothing shared.
- **The verb is already in the language.**  `send(channel, give xs)`
  reads exactly like S13's give-parameter, and means the same thing:
  the name is poisoned, the object has left this scope forever.  The
  ownership surface of candidate B may be **zero new rules** — `give`
  for a move, `copy` for a duplicate, values for free.

**What it preserves.**  S8 within a run — each run is still
single-threaded, so free aliasing stays sound where it applies.  No
collector: each `Runtime` reclaims by scope exactly as today, and a run
that ends drops its whole arena (`luce_rt_close`).  **The resonance
with BEAM is exact and worth stating** (§2.2): a per-process heap that
dies whole is what Luce's per-run arena already is, and the reason
BEAM's collector is cheap is the reason Luce needs none.

**What it costs.**  A channel is a new kind of thing that is neither a
value nor a scope-owned object — it outlives both endpoints' scopes by
construction — so it is the first entity in the language that S33's
three owner kinds (a binding, a container, a statement temporary) do
not cover.  That is the real design work, and it is where a careless
answer reintroduces shared ownership by the back door.

For B1 specifically: `agree` would have to be taught to run two
runtimes and compare a *deterministic* interleaving, which means the
scheduler is part of the specification (run-to-completion handlers, a
FIFO mailbox, a fixed spawn order).  That is a requirement to write
down, not a detail.  For B2 it is easier — each process is one
ordinary run and the oracle sees what it always saw.

**What it forecloses.**  Anything that wants genuine shared mutable
state later, because programs written against copying will have been
written to copy.  That is a feature if the answer is "there is never
shared mutable state" and a trap if it is not.

**Migration cost.**  B2: one host slot, or none.  B1: a channel
primitive in `libluce_rt`, a cross-runtime deep-copy walk, a scheduler,
and a second arm for the oracle.  Neither touches stage 4's rules.

### C. Reference capabilities: extend the ownership model

**The shape.**  The ambitious one, and the one with the closest
published relative: Pony's six reference capabilities (§2.3), which
solve exactly Luce's problem — safe sharing without a borrow checker —
in a language whose `consume` is Luce's `give` almost verbatim.

**Honestly, what S1–S45 would need.**  Four things, in increasing order
of what they cost:

1. **`iso` is nearly free, because Luce has it.**  An owned name that
   nothing else aliases is Pony's `iso`, `give` is `consume`, and S13's
   both-ends rule is exactly the discipline `iso` needs at a call.
   This is the part that makes the option tempting.
2. **S8 has to stop being free.**  Pony's whole trick is that aliasing
   an `iso` does not give you another `iso` — it gives you a `tag`, a
   name you may not read through.  Luce's S8 gives an alias full read
   *and write* with nothing recorded anywhere.  So either S8 acquires a
   caveat for sendable objects, or sendable objects become a second
   kind with their own aliasing rules.  Either way **the sentence that
   keeps casual code free of memory words gets an exception**, and that
   is the single largest cost on this list.
3. **`val` needs deep immutability, which S39 deliberately declined.**
   The capability that makes Pony's model ergonomic is the shared
   immutable one, and S39 records the refusal in advance: *"`let`/`var`
   govern reassignment of the binding only — JavaScript's `const`, not
   Swift's `let`.  The alternative (let freezes contents) buys
   read-only guarantees at the cost of a const-ness type system;
   deliberately not chosen for now."*  A `val` **is** that const-ness
   type system, so taking C means re-opening S39 first.
4. **And the half that is not for sale: Pony collects.**  Its
   per-actor heaps are garbage collected and its shared objects are
   collected by ORCA (§2.3).  A `val` shared by two actors has no
   owner and therefore no scope to die at — which is the precise hole
   `share` was refused for (§1.2).  So a Luce-shaped C would have to
   invent a reclamation story for shared immutable data that is neither
   a counter nor a collector, and no published language has one.

Plus `trn`, `box`, the alias/ephemeral operators and viewpoint
adaptation — a type system substantially larger than all of
`types.Type`, which `docs/MISSING.md` describes as *"a closed union
with twenty exhaustive switches depending on it."*

**What it would buy.**  Real shared-memory parallelism with static
safety and no runtime checks — the only candidate here that does.

**Migration cost: the largest by a wide margin**, and concentrated in
stage 4, the one stage every other roadmap item also touches.

**What it forecloses.**  Nothing technically, but everything
practically: a language that has taken C is a language whose users
learn six capabilities before writing a server, and the reports on that
learning curve are not encouraging (§2.3).

### D. Deterministic parallelism, with the table frozen

**The shape nobody asked about, and the one this survey would be
incomplete without.**  Not concurrency at all — *parallelism*: a
construct that splits a loop over disjoint slices and runs them on N
cores, with no message passing, no scheduler, and no interleaving a
program can observe.

The reason it is worth naming here is a property of the runtime rather
than of the language.  `resolve` is a load and a compare against
`self.table.items` (§1.4) and mutates nothing; what mutates is
`attach` (which may reallocate the table) and `freeObject`.  So **a
region in which no object is created and none is freed is one in which
the object table is read-only**, and concurrent readers of a read-only
table race on nothing.  A parallel region with that restriction —
write only to distinct array elements, allocate nothing, free nothing
— is data-race-free by construction rather than by checking.

**What it preserves.**  S8 (there is one logical thread; the
parallelism is inside one statement).  No collector.  No closures if
the body is a loop body rather than a lambda.  Determinism *exactly* —
the result does not depend on the split, which is what makes it
oracle-safe with no new harness at all.

**What it costs.**  A real analysis proving the restriction (no
allocation in the body reaches deeper than it sounds: string
concatenation allocates, `append` allocates, `+` on strings
allocates), and a trap or a diagnostic for the cases it cannot prove.
It also does nothing whatever for a web server, which is I/O-bound.

**Where it belongs.**  Beside `docs/VECTOR.md`, not beside this memo's
occasion.  It is listed because it is the answer to "we want to use
more than one core" that costs the *language* almost nothing, and
because a ruling that says "no threads" should know that it is not also
saying "one core, forever".

### E. Do nothing yet, on purpose

Write the server single-threaded (candidate A), ship it, measure it,
and revisit with a number.  This is a real option and it is what
`docs/MISSING.md` Tier 4's one-word answer (*"async… No."*) currently
says.  Its virtue is that A forecloses nothing; its risk is that a
std library written against a blocking `net.read` is an API that a
later model has to break.

**That risk is the one thing worth deciding early even under E**: not
whether Luce gets threads, but whether the socket API is shaped so that
a multiplexed or worker-based future would not break it.

---

## 5. The closures question, stated crisply

The absence of first-class functions is fatal to some of these models
and irrelevant to others, and the line is sharper than "async needs
closures."

**A closure is needed exactly when control leaves the program and comes
back into the middle of something.**  A callback is a resumption point
plus captured state; with no closures, the resumption point must be a
named top-level `func` and the captured state must be an explicit
struct passed to it.

| model | forces closures? | why |
|---|---|---|
| A. event loop | **No** | The program *is* the loop.  Per-connection state is a `struct` in a `map`, and the resumption point is the next iteration. |
| B. workers + messages | **No** | A worker is an entry `func` name and an owned payload — the same shape `docs/MISSING.md` blesses for `sort_by`.  A mailbox handler is a named `func`, exactly as Pony's behaviours are methods rather than lambdas. |
| C. reference capabilities | **No, by itself** | Pony's `be` is a method.  Caps are a type-system feature; they force nothing about functions. |
| D. deterministic parallelism | **No** | The body is a loop body. |
| callback-style async (Node's own API shape) | **Yes** | `on_read(handle, fn)` has nowhere to put captured state. |
| `async`/`await` with futures (Rust, Swift, JS) | **Yes, effectively** | A future *is* a suspended stack frame; without closures the compiler must synthesize one, which is a whole new lowering (§2.5, §2.7). |
| coroutines/generators | **Yes, or a state-machine lowering** | Same thing said the other way: either the user writes the capture or the compiler does. |

**And the Luce-shaped observation that belongs in the ruling.**  If
async ever *is* wanted, the house already solved a structurally
identical problem once: `docs/FAILURE.md` records that *"`T!` is **not
a type** — fallibility is a function attribute"*, which gave Luce
Ok-wrapping for free and left `types.Type` untouched.  The analogous
move — suspension as a function attribute with a call-site keyword,
rather than a `Future(T)` type — is the shape this language would reach
for, and it is worth knowing that before anyone imports someone else's
answer.  It does not make the lowering cheap; it makes it *Luce's*.

---

## 6. Questions for the owner

The ruling that would settle this is not "threads: yes or no."  It is
these, roughly in the order they gate each other.

**Q1 — What is the load?**  Is the target "a few hundred concurrent
connections on one box, mostly waiting on I/O" or "saturate the
cores"?  A is sufficient for the first and structurally incapable of
the second.  Nothing else can be answered without this one.

**Q2 — Is a Luce program allowed to be more than one thing at a
time?**  This is the real question, and it is prior to every
mechanism.  "A Luce program is a single thread of control; if you want
two, run two programs" is a coherent, defensible position that the
whole memory model is currently built on — and if it is the ruling,
candidates C and B1 are closed and the work is candidate A plus
possibly B2.

**Q3 — Is S8 negotiable?**  Free untracked aliasing is what makes
casual Luce free of memory words.  Every shared-memory model in the
field either tracks aliases (Pony, Rust) or collects garbage (Erlang,
Go, Java, Swift).  Luce has refused the second, permanently.  Is it
willing to pay the first — an exception to S8 for shared objects — or
is S8 as load-bearing as it reads?

**Q4 — Must the scheduler be deterministic?**  `agree` compares printed
bytes in order and traces frame for frame (§1.5).  Under any
multi-run model, either the scheduler is deterministic by construction
(run-to-completion, FIFO, fixed spawn order) or the oracle can only
compare unordered sets, which weakens the strongest tool in the tree.
Is determinism-by-construction a requirement, or is a pinned test
scheduler enough?

**Q5 — In-process or out-of-process?**  If the answer to Q2 is
"multiple programs", B2 (N `loom` processes behind one socket) costs
the language nothing and gives real multicore today.  B1 buys cheaper
messages and a shared address space, at the price of a scheduler, a
channel primitive, and a second arm for the specs.  Is the OS allowed
to be the scheduler?

**Q6 — Does `std.network` get designed for one model or for none?**
This is the only question with a deadline.  A blocking `net.read` is
the right API for A and the wrong one for B1; a handle-plus-`wait` API
serves both.  The socket surface is being designed either way, and it
is cheaper to shape it now than to break it later.

**Q7 — Is "more than one core" a goal at all?**  If it is, candidate D
is a smaller and more Luce-shaped answer than any concurrency model,
and it belongs on the roadmap independently of this decision.

**Q8 — Is "a program that does not ask for concurrency pays nothing"
a hard rule?**  Swift's steering group concluded, in public and after
shipping, that its data-race safety mode made *"writing a
single-threaded program surprisingly difficult"* and spent a release
undoing it (§2.7).  Luce's entire corpus is such programs.  If this is
ruled a hard constraint — **no new keyword, no new annotation, no new
diagnostic in a program that never spawns anything** — it decides more
than it looks: it is compatible with A, B and D as sketched here, and
it is very hard to reconcile with C, whose capabilities appear on
ordinary signatures whether or not the program has two threads.

---

## 7. Non-goals — what this memo asks nobody to decide

- **Whether Luce gets threads.**  That is the ruling; this is the
  briefing.
- **Any syntax.**  Every fence above is `text` and every keyword in
  them is a placeholder.  A `send`/`spawn`/`parallel` spelling is a
  design memo's business, and only after a model is chosen.
- **The `std.network` API.**  Named in Q6 as the thing with a deadline,
  deliberately not sketched: it is a design memo of its own, and it
  should be written knowing the answer to Q6 rather than guessing it.
- **Reopening ARC, refcounting or GC.**  `docs/MEMORY.md` says *"Do
  not relitigate this section."*  Nothing here does; where a surveyed
  model depends on collection, that is recorded as a cost of the model,
  not as a reason to reconsider the ruling.
- **Reopening S8, S39 or `share`.**  §4C prices what reopening them
  would take.  Pricing is not proposing.
- **`docs/MISSING.md` Tier 4's "async… No."**  It stands until the
  owner moves it.  This memo exists because the owner asked what the
  options were, not because the answer changed.

---

*Gathered, not decided.  Nothing in the tree moved to write this: no
keyword, no host slot, no version number, not one line of Zig.  The
next thing that should happen to this file is a ruling on §6 — after
which it gets a **Ratified** banner like every other memo in `docs/`,
or a single line recording that the answer is "one thread of control,
and that is the design", which is equally a decision and equally worth
writing down once.*
