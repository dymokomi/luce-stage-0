# The Luce standard library

Std modules are ordinary Luce source **embedded in the compiler** —
the way Zig ships `lib/std` with its compiler, minus the install
path.  Wherever the compiler runs (the `luce` CLI, loom, a test),
`import math` just works.  Std names are a **reserved namespace**:
they resolve before the file loader, so a sibling `math.luc` is never
consulted.

Being ordinary modules, std code obeys every language rule — the
ownership model, the checked arithmetic, and the host gate:
`import files` inside a host-less evaluator is a compile error,
because file access genuinely does not exist there.

Sources live in `src/luce/std/*.luc`; the table that embeds them is
in `src/luce/compile.zig`; the suite proving them is
`src/luce/std_spec.zig` (math) plus a hosted test beside `TestHost`
in `interpreter.zig` (files).

Naming follows the language's own style: modules are short lower-case
nouns, functions are short verbs read *with* the module prefix —
`files.read(path)`, `math.seed(42)` — so bare names stay short
without colliding.

---

## math

Pure Luce over the checked builtins (`sqrt floor ceil abs min max
clamp` stay builtins; math adds what they lack).  Series are
range-reduced: `exp`/`ln` hold to ~1e-14 relative, trig to ~1e-12
absolute.

```luce
import math

math.pi   math.tau   math.e            # constants (folded)

math.round(x)          # half away from zero: round(-2.5) == -3.0
math.exp(x)            # e^x; overflow -> inf, underflow -> 0.0
math.ln(x)             # natural log; x <= 0 traps
math.log2(x)  math.log10(x)
math.pow(x, y)         # x^y; negative x needs whole y (else trap),
                       # 0^negative traps, 0^0 == 1
math.ipow(base, n)     # Int power by squaring; checked (overflow
                       # traps); negative n traps
math.sin(x)  math.cos(x)  math.tan(x)  # radians, any magnitude
```

**Randomness** is a Lehmer/MINSTD generator whose state lives in a
`List(Int)` the caller owns — mutation through a borrow is ordinary
Luce, so there are no hidden globals and every stream is
deterministic from its seed:

```luce
var rng = math.seed(42)          # any Int seed
let f = math.random(rng)         # Float in (0, 1)
let roll = math.random_int(rng, 1, 7)   # Int in [low, high)
```

Period 2^31 − 2; games and shuffles, never secrets.

## files

A thin, honest layer over the host's file builtins (host-gated; loom
resolves paths relative to the current directory):

```luce
import files

files.exists(path)               # Bool
files.read(path)                 # String; missing file traps
                                 # file_read_failed — guard with exists
files.write(path, text)          # Bool; false on failure
files.read_lines(path)           # List(String), newlines stripped; a
                                 # trailing final newline adds no
                                 # phantom empty line
files.write_lines(path, lines)   # joined with newlines, ends with one;
                                 # an empty list writes an empty file
```

---

## Adding a module

1. Write `src/luce/std/NAME.luc` — ordinary Luce, documented with
   `#` comments in the header.
2. Add one row to `std_modules` in `src/luce/compile.zig`.
3. Prove it in `std_spec.zig` (pure) or beside `TestHost` (hosted),
   the way math and files are.
4. Document it here.

Deliberate constraints, until the language grows the features:
no module state (top-level `let` is constant — the RNG's List-state
pattern is the idiom for mutable state), and error handling is traps
plus guard functions until Phase 3 (optionals + errors) lands — std
signatures will be revisited then.
