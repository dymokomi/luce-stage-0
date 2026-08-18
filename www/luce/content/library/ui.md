# std.ui

`std.ui` is Luce's low-level native window boundary. It opens a window and
provides the [`std.gpu.Surface`](/library/gpu/) used to draw into that window.
The module deliberately stops there: it does not define buttons, text fields,
layout, application state, or a hidden event loop.

```text
import std.ui
```

Use `std.ui` for experiments at the operating-system seam or as the substrate
of a higher-level package. Most applications should eventually use that
higher-level package rather than own window lifecycle and drawing directly.

## Open a window

```text
new ui.Window(title: str, width: i64, height: i64) -> ui.Window!
```

Construction takes a UTF-8 title and dimensions in backend pixels. Width and height
must be positive. The current macOS host accepts each dimension through
16,384 pixels and may refuse a request because of native resource exhaustion
or window-system failure. Those conditions arrive as an ordinary error.

```text
func main() -> !:
    let window = try new ui.Window("Hello", 800, 600)
```

`Window` is a class owning the native window. Assigning or
passing it retains the same native window; it does not create a second window.
The native window closes when the last strong wrapper is released. There is
no manual `close` operation.

## Get the drawing surface

```text
window.surface() -> gpu.Surface!
```

Each successful call creates a surface associated with the window. The surface
retains the host-side drawing state, so it remains valid if the `Window` value
is returned from or released before the surface. Drawing is explicit:

```text
import std.ui

func main() -> !:
    let window = try new ui.Window("Hello", 800, 600)
    let surface = try window.surface()
    try surface.clear(0, 0, 0)
    try surface.fill_rect(40, 40, 240, 120, 70, 130, 220)
    try surface.present()
```

`std.ui` imports `std.gpu`, so the surface type and methods are available from
the returned value. Import `std.gpu` yourself when you need to name
`gpu.Surface` or inspect `gpu.backend()`.

## Platform and host boundary

The released macOS ARM64 toolchain provides the graphics channel in both
standalone executables and `loom`. It creates an AppKit window, uses Metal
when available, and falls back to a CPU-backed layer when Metal setup is not
available. Native objects and Objective-C types remain behind the host ABI.

A runtime with no graphics channel traps `host_unavailable`. A provided
channel that cannot complete an individual operation returns a fallible I/O
error. This fail-closed behavior is intentional: an apparent `Window` that
never reached the operating system would make successful source lie.

Window and surface references cannot cross a worker boundary. Create and use
them in the runtime that owns the host channel. ARC cleanup occurs in that
runtime when the final strong reference disappears.

## Current scope

Opening and drawing are implemented; native window events are not yet exposed
through `std.ui`. The library has no application loop, close notification,
resize event, keyboard/mouse event, focus API, menus, clipboard, accessibility,
or controls. A short program that returns immediately also releases its
window immediately.

This narrow surface is useful because it fixes one abstraction boundary
without prematurely fixing a UI framework. A future declarative native UI
package can own the application loop and present components while continuing
to use `std.ui` for windows and `std.gpu` for drawing.

For the drawing contract, read [`std.gpu`](/library/gpu/). For automatic
resource cleanup and worker isolation, read [Memory and
ARC](/guide/memory/). For a complete declarative terminal framework available
today, read [`termui`](/library/termui/).
