# std.gpu

`std.gpu` is a small, backend-neutral drawing surface. It lets Luce code clear
a surface, fill rectangles, and present a frame without exposing Metal,
Vulkan, AppKit, or a native handle. It is the rendering half of the low-level
window boundary; [`std.ui`](/library/ui/) creates the window and surface.

Use this module when direct pixel geometry is the right abstraction. It is
not a widget toolkit, scene graph, retained view tree, or shader API.

```text
import std.gpu
```

## Select and inspect the backend

```text
gpu.backend() -> gpu.Backend
```

`gpu.backend()` reports one of:

| Member | Meaning |
|---|---|
| `gpu.Backend.metal` | the host draws with Metal |
| `gpu.Backend.vulkan` | the host draws with Vulkan |
| `gpu.Backend.headless` | the host supplies the surface contract without a hardware GPU backend |

The enum is an observation, not a switch applications should normally branch
on. The drawing API has the same meaning for every backend. A host with no
graphics channel traps `host_unavailable`; it does not report `headless`,
because `headless` is still a real provided backend.

The released macOS host selects Metal when its device, queue, and pipeline are
available. Otherwise it uses a CPU-backed window and reports `headless`.
Vulkan is the reserved backend value for Windows and Linux hosts; those
published hosts do not exist yet.

## Obtain a surface

A program does not construct `gpu.Surface` directly. Ask a UI window for one:

```text
import std.ui

let window = try ui.open("Canvas", 640, 480)
let surface = try window.surface()
```

`Surface` is a value wrapper around an ARC resource reference. Copying the
wrapper shares the native surface and keeps it alive. Releasing its last
strong reference closes the native resource. Keep the originating window
alive for at least as long as every surface obtained from it.

## Surface size

```text
surface.width() -> i64!
surface.height() -> i64!
```

The dimensions are backend pixels. On the current macOS host they are the
dimensions requested when the window opened. A later resizable-window/event
API may make these measurements change; code should ask the surface instead
of treating its original request as permanent geometry.

## Draw a frame

```text
surface.clear(red, green, blue, alpha = 255) -> !
surface.fill_rect(x, y, width, height, red, green, blue, alpha = 255) -> !
surface.present() -> !
```

The origin is the top-left pixel. `x` increases right and `y` increases down.
Rectangle width and height must be positive. Geometry outside the surface is
clipped by the current macOS backend. Color components are integers from 0
through 255; alpha defaults to fully opaque.

A frame normally follows three steps:

1. `clear` chooses the background and discards rectangles queued for the
   previous frame.
2. One or more `fill_rect` calls add geometry in call order.
3. `present` submits the completed frame and begins no implicit animation.

```text
import std.ui

func draw(surface: gpu.Surface) -> !:
    try surface.clear(18, 22, 30)
    try surface.fill_rect(20, 20, 120, 80, 90, 160, 240)
    try surface.fill_rect(52, 44, 56, 32, 245, 245, 245, 220)
    try surface.present()

func main() -> !:
    let window = try ui.open("Luce", 640, 480)
    let surface = try window.surface()
    try draw(surface)
```

This example requires a graphics host and is shown rather than executed by
the documentation builder. The released macOS standalone runtime and `loom`
provide that host.

## Failure and lifetime

Size, drawing, and presentation are fallible because the provided backend can
refuse an otherwise valid request. Invalid color components, non-positive
rectangle extents, resource exhaustion, a closed native object, or a failed
presentation becomes the ordinary error channel. Handle it with `try` or
`catch`.

A missing callback, forged resource kind, or host with no graphics channel is
a trap, because the program is running against a host that cannot satisfy the
API it invoked. [Error Handling](/guide/errors/) explains that distinction.

The current surface exposes only clear, filled rectangles, size, and present.
There are no textures, paths, text, blending controls, command buffers,
custom shaders, readback, or GPU compute in this API. Higher-level drawing
and native UI packages should build on this stable seam without leaking a
vendor handle into Luce source.
