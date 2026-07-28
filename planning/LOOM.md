# LuciaOS

## The Loom architecture

> **A persistent computer made of connected things.**
>
> **Loom does not begin by making the computer intelligent. It begins by making the computer coherent.**

---

## The idea

The computer has accumulated many useful forms—files, folders, applications, windows, services—but none of them needs to be its ground truth.

A file binds information to one container. A folder gives it one official location. An application encloses information, capability, and interface inside a boundary chosen by its maker. Moving work between these forms means copying, importing, exporting, synchronizing, or asking one application to understand another.

LuciaOS places something simpler beneath them: a persistent **Fabric** of identity-bearing **Texels** connected by typed **Fibers**.

A Texel can hold information or compute it. A Fiber connects one Texel's Output Port to another Texel's Input Port. The same Texel can participate in many contexts without being copied or moved. It can be renamed without losing identity, presented in several ways at once, and given a capability without receiving ambient access to the rest of the computer.

Files, folders, documents, applications, workspaces, searches, and services can still exist. They become useful forms made from the Fabric rather than rival containers imposed beneath it.

The result is not a graph-shaped imitation of today's desktop. It is a different starting point:

- information has identity before it has a location;
- relationships are durable parts of the work;
- computation lives beside the information it transforms;
- interfaces are computations over the same persistent material;
- capability arrives through explicit connections;
- the boundaries of an application no longer determine the boundaries of a person's work.

> **Connecting is filing.**

To put something somewhere is to connect it into a context. To place it somewhere else is to make another connection. Organization accumulates without one context erasing another.

---

## Why Lucia

**LuciaOS** is the operating system. **Loom** is the trusted engine at its center.

The name *Lucia* is traditionally associated with the Latin *lux*: light. The metaphor is not cloth laid over a conventional computer. It is closer to fiber optics raised into an information architecture.

Light travels through Fibers. Fibers form the Fabric. Loom holds it coherent, and Lucia brings it into View.

---

## The small vocabulary

The user-visible model has seven ideas:

- **LuciaOS** — the complete computing environment.
- **Loom** — the trusted local engine that stores, connects, evaluates, and protects the Fabric.
- **Fabric** — the persistent computational medium available to a Loom.
- **Texel** — the only independently identified element in the Fabric.
- **Port** — a named, typed interface on a Texel. An **Input Port** (`InputPort`) receives a connection; an **Output Port** (`OutputPort`) offers a value.
- **Fiber** — a connection from an Output Port to an Input Port.
- **View** — a Texel whose computation produces a user interface.

That is the architecture a person and a programmer should need to grasp.

Loom will contain indexes, schedulers, transactions, checkpoints, caches, storage pages, drivers, and security machinery. Those are implementation obligations, not additional materials from which the computer is made. Likewise, sharing protocols, package formats, history systems, and compatibility layers can be built around Loom without becoming new universal primitives.

The machinery may grow. The ontology should not.

---

## Texels

A Texel is atomic in identity, not necessarily small in content.

It is the smallest part of the Fabric that can be independently named, connected, revised, presented, or shared. A Texel may represent a number, a paragraph, an image, a document, a camera, a function, a database, a running simulation, or an entire legacy application. These things do not have identical behavior. What they share is a coherent envelope through which they participate in the Fabric.

A Texel has:

- a stable **identity**;
- optional **content** or a reference to it;
- zero or more **Input Ports**;
- zero or more **Output Ports**;
- an optional **evaluator** that computes outputs from inputs.

Identity is independent of name, path, machine, and presentation. Names and paths belong to the contexts and Views through which a Texel is reached. A Texel can therefore appear in several places, take different names in each, and remain the same thing.

Only Texels carry identity in the Fabric. A Fiber is simply a connection. If a relationship needs its own authorship, properties, behavior, or history, it is represented by a Texel with Ports of its own.

### Content is opaque

The Fabric does not require everything to be decomposed into tiny pieces.

> **Make a Texel of what the Fabric must independently address. Keep the rest as content.**

An image should not become millions of Texels merely because it contains millions of pixels. Its pixels may remain one opaque or chunked value handled by an image engine. A database does not become one Texel per row unless those rows genuinely need independent identity in the wider Fabric. A paragraph may remain inside a document until it needs to be cited, arranged, or computed independently.

This is both a conceptual and a performance boundary. The Fabric expresses meaningful identity and composition; specialized representations handle dense internal data.

Large content lives out of line behind stable value references. Collections remain compact typed values until their members need independent identity. A Texel is not required to be a heavyweight runtime object: Loom may represent millions of them in dense tables, load them lazily, and compile connected computations into efficient batches.

The visible model stays uniform without forcing every workload into one physical representation.

---

## Ports and Fibers

A Fiber connects one Output Port to one Input Port.

An Output Port may feed many Input Ports. An Input Port has at most one active source. Collections, streams, tables, and images pass as typed values; multiplicity does not require a growing field of Ports.

`InputPort` and `OutputPort` are distinct structures in code because they own different state:

- an `InputPort` owns its incoming Fiber binding;
- an `OutputPort` owns its current value reference, revision, and computed-cache state.

An Output Port does not own a durable list of its consumers. Loom may build that reverse index for evaluation and invalidation, but it is disposable machinery rather than part of the Fabric.

Ports are named and typed. A connection is valid only when the offered and expected value types are compatible. An Output Port can yield a value, declare that no value is available yet, or report a structured error. These outcomes travel through the same evaluation model instead of being hidden as process-global state.

Fibers make dependency explicit. A Texel computes from what arrives at its Input Ports; it cannot wander through the Fabric by guessing identities or paths. Sensitive operations require an explicit capability value at an Input Port. The Fiber carries that capability to the Texel, while Loom enforces what the capability permits.

This gives composition and authority the same visible shape without pretending that a connection alone defines every security policy.

---

## Pull and computation

Evaluation in Loom is demand-driven.

When an Output Port is demanded, Loom checks whether its cached value is valid for the current revisions of its inputs. If it is, Loom returns it. If it is not, Loom pulls the required upstream outputs, runs the Texel's evaluator, and caches the result.

The direction of demand is opposite to the direction of value:

```text
demand:   View  →  Texel  →  source
value:    View  ←  Texel  ←  source
```

Nothing recomputes merely because it exists. Work happens because a View, a local service, or an explicit request needs an output. A change invalidates only the dependent results that can no longer be trusted.

The first Loom can require ordinary computation to be acyclic. Recurrence enters through an explicit **State** or **Delay** Texel whose previous value becomes a later input. This keeps evaluation deterministic while still allowing counters, feedback, animation, long-running work, and state machines to emerge as visible structures.

Loom defines the scheduling and cache contract, not one universal execution engine. An evaluator may be portable code, a native implementation, a database query, a GPU pipeline, or a call into a specialized runtime. Connected subgraphs may be fused or compiled. Real-time audio and video may exchange buffer handles rather than journal every sample.

One Fabric does not mean one implementation strategy.

---

## State and effects

The current Fabric is durable. A change to several Texels and Fibers becomes visible atomically: either the coherent new state exists or the previous state does.

How Loom provides this—journal records, checkpoints, page versions, or another storage design—is internal. A short recovery log may be necessary; an unlimited user-visible history is not. Undo windows, named versions, archives, provenance, and collaborative history are services that retain additional state deliberately. They can be enabled where valuable and absent where wasteful.

Durable state and external effects are different.

A pure evaluator may be repeated without changing the world. Sending a message, writing a legacy file, charging a card, printing a page, or commanding a device may not. LuciaOS therefore represents an attempted effect as data:

1. a Texel computes an **effect intent**;
2. Loom verifies an explicit connected capability;
3. a trusted boundary performs the effect once;
4. its result returns as a new observation.

This boundary prevents cache invalidation, recovery, or repeated evaluation from accidentally repeating an external action.

The same pattern admits the world into the Fabric. A keyboard, clock, camera, network client, filesystem bridge, or sensor is represented by a boundary Texel whose outputs are observations. Loom does not need to pretend that the outside world is pure; it only needs to make the crossing explicit.

---

## Views

A View is an ordinary Texel whose computation produces an interface.

It receives source material, interaction, and local state through Input Ports. It offers a renderable interface and the results of interaction through Output Ports. Demanding the interface pulls exactly the computation necessary to present it.

The same material can therefore be viewed as prose, a timeline, a table, a map, a conversation, or an editable graph without being imported into six applications. Each View is a persistent, connectable program over the same Texels.

Views do not render themselves directly onto unowned screens. LuciaOS includes a small trusted shell that:

- asks a View for its interface output;
- composites approved surfaces;
- routes pointer, keyboard, focus, and accessibility input;
- presents trusted permission and identity prompts;
- turns action outputs into explicitly authorized effects.

The shell is trusted machinery, not a second user-visible substrate.

Focus, zoom, sorting, selection, and layout may remain disposable View cache. When such state should survive or be shared, it becomes content in a connected Texel. A View can thus keep one implementation while different people or contexts connect different sources and state.

A file browser, desktop, application window, and command line can all be Views. They remain familiar ways of working without regaining authority over the underlying identity of the material they show.

---

## Complexity emerges above Loom

The small substrate is useful because larger forms can be expressed as recurring structures rather than added as new primitives.

An **arrangement** is a Texel whose inputs name or order other Texels. It can behave like a document outline, folder, playlist, project, or workspace. The same Texel may be connected into many arrangements without being copied.

A **service** is a durable connected computation whose outputs are demanded by a local rule or schedule. Indexing, backup, automation, and synchronization can be services without giving every Texel a second service ontology.

A **package** is a signed bundle of Texels, evaluators, Views, defaults, and requested capabilities. It gives people a practical unit to install and remove. Packages may feel like applications, but they do not become sovereign containers for a person's data.

A **Braid** is an exchange layer through which Looms make authorized Fabric material available and pull it into local state. It can add addressing, relays, signatures, encryption, synchronization, and offline delivery. None of that is required for a Texel and two Fibers to work correctly on one machine.

Like FidoNet, a Braid is recipient-driven. A sender makes material available; the receiving Loom decides when and where to poll, what to accept, and how much resource to spend. Arrival still does not command attention. A View or local rule must pull received material into presentation, and only the recipient's policy may turn it into an interruption.

An **agent** is a constellation of Texels and capabilities that perceives through connected inputs, maintains context in the Fabric, and proposes or performs actions through explicit effect boundaries. It can become remarkably capable without forcing Loom itself to become an agent.

These forms may become substantial systems. Their complexity is allowed to emerge because they all meet the same small substrate at clear Ports.

---

## Familiar computing at the boundary

LuciaOS must make the new model easier to adopt, not demand that every valid old technique be rewritten as a graph.

One boundary pattern is enough: project a region of the Fabric into the environment an existing tool expects, run the tool with limited capabilities, and bring its meaningful results back through Ports.

- A compiler may receive a temporary directory and emit an artifact.
- An image editor may receive a file or pixel buffer and return a revised value.
- A database Texel may wrap a specialized database engine and expose typed queries and results.
- A browser View may contain a mature browser engine.
- A command-line tool may receive standard input, output, arguments, and a projected filesystem.
- A GPU or audio runtime may process opaque buffers under its own scheduling rules.

Loom needs to know the identity of the participating Texels, the values and capabilities crossing their Ports, and the revisions of their results. It does not need to absorb the internal ontology of every tool.

Files remain useful as portable byte artifacts. Folders remain useful tree-shaped Views and projections. Applications remain useful distribution and trust bundles. LuciaOS changes their constitutional role: they are interfaces at the edge of the Fabric, not the ground truth inside it.

---

## What becomes newly possible

Because identity, relationship, computation, and presentation share one persistent medium:

- one piece of material can participate in many works without copies becoming unrelated;
- organization can be layered instead of forced into one hierarchy;
- a new View can reinterpret existing work immediately, without migration;
- capabilities can be connected narrowly to the computation that needs them;
- automations can operate on the same durable structures a person sees;
- provenance and live references can survive movement between contexts;
- an agent can encounter the person's actual computational world rather than a pile of application silos and screen pixels.

The last point is where the architecture may eventually approach the computer imagined in *Her*. Such a computer needs continuity, perception, memory, action, and an interface that can adapt to the moment. In LuciaOS:

- boundary Texels provide perception;
- the persistent Fabric provides memory and context;
- Fibers express association and dependency;
- demand from Views and local services provides attention;
- evaluators transform material and connected structures;
- Views provide expression;
- effect intents provide action.

That future does not require a larger Loom. It requires richer structures living coherently on top of it.

---

## Performance is part of the model

The Fabric can remain fast if implementations preserve a few hard rules:

1. **Identity follows meaning, not storage units.** Do not create a Texel per pixel, byte, sample, row, or cell by default.
2. **Large values stay out of line.** Ports pass references to immutable blocks, buffers, streams, or engine-owned values.
3. **Collections stay compact.** Members become Texels only when they need independent identity outside the collection.
4. **Caches are disposable and separately budgeted.** Durable state never depends on retaining a computed cache.
5. **Evaluation is incremental and demand-driven.** Unobserved work remains unevaluated.
6. **Subgraphs may be batched, fused, or compiled.** The conceptual graph does not require one function call per Fiber.
7. **Specialized runtimes remain welcome.** Databases, browsers, GPUs, and real-time media engines do what they are good at.
8. **Transient data stays transient.** A video frame or audio buffer is not durable Fabric history unless deliberately captured.

These rules are not escape clauses. They follow from the distinction between the Fabric's meaningful structure and the machinery that implements it.

---

## The first LuciaOS

The first version should prove the new substrate, not pre-build the mature operating system around it.

It is:

- for one person on one machine;
- durable current state, with only a short recovery window;
- typed Input Ports and Output Ports;
- one active Fiber per Input Port and fan-out from Output Ports;
- demand-driven, cached, acyclic pure computation;
- explicit State or Delay Texels where time is required;
- explicit capabilities and effect boundaries;
- opaque large content;
- one excellent View runtime and trusted shell;
- one excellent tree-and-file projection for existing tools.

It does not yet require:

- general multi-person collaboration;
- a universal synchronization or conflict-resolution framework;
- permanent history for every change;
- a global package ecosystem;
- replacement browser, database, GPU, or media engines;
- an agent.

The proof should let a person create durable material, connect it into several contexts, compute over it, present it through two genuinely different Views, edit it through either View, restart the system without losing identity, and use one existing tool through a projected file boundary.

If this feels simpler than moving the same work among files and applications—and remains fast under a realistically large Fabric—Loom has established its foundation.

---

## Principles

1. **A persistent computer made of connected things.**
2. **One coherent substrate; many semantic and execution strategies.**
3. **Identity is never position.**
4. **Only Texels carry identity. Fibers connect Output Ports to Input Ports.**
5. **Make structure of what the Fabric must address; keep the rest as content.**
6. **Connecting is filing.**
7. **A View is a Texel. Interface is computation over the Fabric.**
8. **Computation pulls values; it does not receive ambient access.**
9. **Current state is durable. History is an explicit service.**
10. **Pure evaluation and external effects are separate.**
11. **Specialized machinery may accelerate or contain a Texel without changing the Fabric's meaning.**
12. **The core remains small enough to understand, implement, and trust.**

Loom does not replace every machine inside the computer. It gives them one coherent material on which to work.
