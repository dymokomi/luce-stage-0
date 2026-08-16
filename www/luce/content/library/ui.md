# std.ui

`std.ui` is the low-level window boundary. It creates a `Window` and turns
that window into the `std.gpu.Surface` used for drawing. It intentionally does
not contain widgets, layout, event loops, or application state; those belong
in a package built above these two narrow modules.

The host keeps the native window handle behind the runtime. `Window` and its
drawing surface are shared resource references. ARC releases each native
resource at its last strong reference; [Memory and ARC](/guide/memory/)
explains the common lifetime rule.

## Opening a window

Call `ui.open` when the application is ready to create a native window.

```text
ui.open(title: str, width: i64, height: i64) -> Window!
```

The dimensions are backend pixels. A host may refuse creation, which arrives
as an ordinary error. If the host has no graphics channel, the call traps
with `host_unavailable`.

The macOS `loom` installed by the toolchain provides this service. It opens an
AppKit window and keeps its native handle behind the Luce resource; the
surface uses Metal when available and a CPU-backed fallback otherwise.

## Getting a drawing surface

```text
window.surface() -> gpu.Surface!
```

Use the returned surface with [`std.gpu`](/library/gpu/). The surface belongs
to the caller; keep the window alive for as long as the host requires it.

```text
import std.ui

func main() -> !:
    let window = try ui.open("Hello", 800, 600)
    let surface = try window.surface()
    try surface.clear(0, 0, 0)
    try surface.present()
```

The program must keep running if it needs to receive events or show a window;
this small API does not provide an event loop. On hosts without a graphics
backend, `ui.open` reports `host_unavailable`.
