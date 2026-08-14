# std.gpu

`std.gpu` is the low-level drawing surface shared by `std.ui` and future UI
packages. It does not expose Metal, Vulkan, or a window-system handle. The
host chooses a backend and owns the native implementation; Luce owns the
`Surface` value and releases it with its scope.

The macOS `loom` host selects Metal when the device and shader pipeline are
available. If Metal is unavailable, it uses a CPU-backed window while keeping
the same surface API. Other hosts may leave the channel unavailable; a call
there traps with `host_unavailable` rather than pretending to draw.

## Backend

`gpu.backend()` reports one of `Backend.metal`, `Backend.vulkan`, or
`Backend.headless`. The host wire values are 0, 1, and 2 respectively.

## Surface

`Surface` is created by `Window.surface()`; `Surface.from_handle` is the
internal ownership handoff used by `std.ui`.

| Function | Meaning |
|---|---|
| `surface.width()` | Width in backend pixels. |
| `surface.height()` | Height in backend pixels. |
| `surface.clear(red, green, blue, alpha = 255)` | Replace every pixel with an RGBA colour. |
| `surface.fill_rect(x, y, width, height, red, green, blue, alpha = 255)` | Fill a rectangle. |
| `surface.present()` | Submit the completed surface to its window. |

All operations that ask the host are fallible. A refused operation is an
error; a missing or malformed callback is a trap. Coordinates and colours
are `long` so the boundary does not silently narrow a platform value.

```text
import std.ui

func main() -> !:
    let window = try ui.open("Luce", 640, 480)
    let surface = try window.surface()
    try surface.clear(18, 22, 30)
    try surface.fill_rect(20, 20, 120, 80, 90, 160, 240)
    try surface.present()
```

The example needs a host with a graphics backend. The installed macOS `loom`
provides one; other hosts may refuse it until their backend is available.
