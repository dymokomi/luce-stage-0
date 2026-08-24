# Luce language support

A repository-local extension that gives Visual Studio Code and Cursor TextMate
highlighting and brace-aware editing behavior for `.luc` files. It has no
runtime dependency on LuciaOS and no third-party package dependency or build
step.

- `syntaxes/luce.tmLanguage.json` — **generated**, see below.
- `language-configuration.json` — comments, brackets, folding, indentation.
  Hand-written and deliberately word-free: the indent rule recognizes a line
  ending in a colon, which covers every ordinary layout block.
- `extension.js` — a dependency-free on-type correction for colons inside
  grouping delimiters, where Luce suspends layout, and a folding provider for
  `# mark:` sections (below).
- `package.json` — what VS Code loads, plus the defaults below.

Only `.luc` is claimed. A `.lc` is a compiled artifact and a `.lcm` a serialized
module — both are binary, and an editor that offered to open one as text would
be offering the wrong thing.

## The grammar is generated, and pinned

`syntaxes/luce.tmLanguage.json` is written by `tools/grammar.zig` from the
compiler's own tables — the lexer's keyword table and token kinds, the
reserved-name list, the free-builtin table, and the receiver-method tables — and
must not be edited by hand.

```sh
zig build grammar     # rewrite syntaxes/luce.tmLanguage.json
```

**Why.** The hand-written grammar this replaced had no mechanical relationship
to the lexer, type vocabulary, builtins, or receiver methods. It therefore
kept highlighting removed words while missing implemented ones across several
language revisions. A generated grammar makes that class of drift a failed
test on the change that introduced it rather than a documentation archaeology
task months later.

**The pin.** `zig build test` runs
`test "the committed grammar is what the generator emits"`, which embeds this
file and compares it byte-for-byte against a fresh run of the generator. Add a
keyword, a builtin or a method to the language without regenerating and the
suite fails, naming this path. Structural tests in the same file keep the
generator honest: every keyword the lexer reserves must have a class; every
name in `reserved_names` must be coloured exactly once — no name uncoloured, no
name claimed by two classes; every *symbol* token kind must have a row in the
generator's spelling table, and every row's text must lex back to the kind it
claims; and no spelling may be written before a longer one it opens with, which
is what makes `<<=` a compound assignment rather than a shift and a stray `=`.
The f-string rule must recursively enter nested strings and balanced braces. A
corpus guard also reads `examples/editor/editor.luc`, the largest Luce program
there is, and checks that every language word it actually uses has a class.

## What is coloured

| Scope | What it covers |
| --- | --- |
| `keyword.control.luce` | `if`, `elif`, `else`, `while`, `for`, `in`, `return`, `break`, `continue`, `match` |
| `keyword.control.exception.luce` | `try`, `catch` |
| `keyword.control.import.luce` | `import`, and the module path after it — `std.strings` as readily as a sibling `geometry` |
| `keyword.control.raise.luce` / `.trap.luce` | `error` and `trap`, the two ways a program stops — **coloured red**, see below |
| `keyword.operator.word.luce` | `and`, `or`, `not`, `is` |
| `keyword.other.ownership.luce` | `new` and `spawn`, the two words that create a reference-bearing runtime object |
| `storage.type.luce` | `func`, `struct`, `class`, `init`, `deinit`, `interface`, `alias`, `enum`, `union`, `const`, `let`, `var` |
| `storage.modifier.luce` | `pub`, `static`, `weak`, `mutating` |
| `variable.language.luce` | `self`, the receiver supplied by the language |
| `constant.language.luce` | `true`, `false`, `none` |
| `support.type.luce` | the builtin type names |
| `entity.name.type.luce` | every other capitalised name — the convention the language enforces for structs |
| `support.function.builtin.luce` | the pure free builtins, plus `range` |
| `support.function.builtin.host.luce` | the host-gated builtins, which need `allow_host` |
| `support.function.method.luce` | the receiver methods, **only** after a `.` |
| `entity.name.function.luce` | the name a `func` declares, and a qualified call's tail |
| `constant.numeric.integer.luce` / `.float.luce` / `.hex.luce` / `.binary.luce` | `1_000_000`, `1.5e-3`, `0xFF_FF`, `0b1010_1010` |
| `keyword.operator.bitwise.luce` | `&`, `\|`, `^`, `~`, `<<`, `>>` (docs/BITWISE.md) |
| `keyword.operator.assignment.luce` | `=` and every compound form, `<<=` and `//=` included |
| `keyword.operator.optional.luce` / `.fallible.luce` | the `T?` and `T!` markers |
| `punctuation.section.braces.*.luce` | `{` and `}` around runtime and constant map literals |
| `invalid.illegal.number.luce` | the numeric literals the lexer refuses |
| `invalid.illegal.name.luce` | a word that opens with an underscore, which is not a name |

Three decisions worth knowing about:

- **Methods are coloured only behind a dot.** `find`, `get`, `clear` and
  `values` are words a program may perfectly well use for a function of its
  own; `xs.find(1)` is the language and a bare `find(1)` is not.
- **An f-string hole is real code.** `f"total {n + 1}"` highlights the
  expression inside the braces, using the same rules as everything outside a
  string. Nested plain strings, nested f-strings, and map braces recursively
  enter the same string and balanced-brace regions, so an inner quote or `}`
  cannot end the outer hole early. `{{` and `}}` are literal braces.
- **Symbols are written longest first.** The operator rules come out of one
  table sorted by spelling length, so `<<=` is tried before `<<`, `<<` before
  `<`, and `==` before `=`. That order is the whole reason a compound
  assignment does not read as a comparison with something after it, and a test
  states it rather than trusting the order the table happens to be in.

The invalid-number rules follow the lexer exactly, including the boundaries it
draws: `1.2.3` is one mistake rather than a float and an integer, `0755` is
refused because Luce has no octal literals, `1.` needs a digit after the point
while `1.foo` is member access, and a base with no digits (`0x`), a digit that
does not belong to it (`0b12`), a misplaced separator (`1_`, `1__0`) or a unit
suffix (`12ab`) is one malformed literal rather than a number glued to a word.

## The defaults it sets

`contributes.configurationDefaults` carries the language's own rules rather
than indentation guesses:

- **`error` and `trap` are red**, through a `textMateRules` entry on their two
  scopes. They are the two ways a Luce program stops — one raises and can be
  caught, one ends the run — and a reader scanning a file wants to see every
  such place at a glance. The rule sits on the scopes rather than in a theme so
  it holds in whichever theme you use; a theme's own colour for
  `keyword.control` is what you would fall back to if you removed it.
- **Four spaces, spaces only, no detection.** A Luce block opens exactly four
  columns deeper than the one containing it and a tab is refused outright by
  the lexer, so an editor guessing indentation from the file can only guess
  wrong.
- **Brace-aware on-type formatting.** The word-free `:\s*$` rule supplies the
  normal four spaces after a layout block. When the colon is inside `()`, `[]`,
  or `{}`, `extension.js` scans the source while ignoring comments and nested
  strings and removes that block indent. `editor.formatOnType` is enabled for
  Luce by default so split map entries and grouped expressions follow the same
  layout-suspension rule as the lexer.

These are defaults: a setting of your own in `settings.json` still wins.

## Package and install

Package the extension outside the repository so the generated VSIX does not
become a source artifact:

```sh
cd tools/vscode-luce
npm_config_registry=https://registry.npmjs.org \
    npx --yes @vscode/vsce package --out /tmp/luce-language.vsix
```

Install it for the current user in Cursor:

```sh
cursor --install-extension /tmp/luce-language.vsix --force
```

Or in Visual Studio Code:

```sh
code --install-extension /tmp/luce-language.vsix --force
```

Reload the editor window afterwards. The workspace recommends the extension by
its identifier, `luciaos.luce-language`.

## Development

Open `tools/vscode-luce` as an extension-development project and press `F5` to
launch an Extension Development Host. There is no build step for the extension
itself. Run `npm test` for the pure indentation scanner. A change to the grammar
is a change to `tools/grammar.zig` followed by `zig build grammar`, never an edit
to the JSON.

## Section marks

A comment of the form `# mark: title` opens a foldable section. It runs from
the mark line to just above the next `# mark:` (at any indentation) or to the
end of the file, so a whole section collapses to its title line:

```luce
# mark: parsing
func lex(...): ...
func parse(...): ...

# mark: evaluation
func eval(...): ...
```

The match is case-insensitive and tolerant of spacing — any indent before `#`,
any run of spaces or tabs between `#`, `mark`, and the colon (`   #  MARK : …`).
A `# mark:` only opens a section when the comment is the first thing on the
line; one written after code, or inside a string, is left alone.

A mark line is also **painted bright and bold** — amber on a dark editor, a
saturated magenta on a light one — so a section title reads over the muted grey
the theme gives ordinary comments. Both folding and the accent are provided by
`extension.js`; the compiler ignores the comment like any other.

**Fold or unfold every section at once** with *Luce: Fold All Section Marks*
(`⌘K ⌘M` / `Ctrl+K Ctrl+M`) and *Luce: Unfold All Section Marks*
(`⌘K ⇧M` / `Ctrl+K Ctrl+Shift+M`), or **fold just the section the cursor is in**
with *Luce: Fold Current Section Mark* (`⌘K ⌘.` / `Ctrl+K Ctrl+.`) — the
enclosing section, not the innermost indentation block VS Code's own
fold-at-cursor takes. These collapse only the `# mark:` regions, leaving the
ordinary indentation folds where they are; VS Code's built-in *Fold All
Regions* (`⌘K ⌘8`) does the same, since mark folds are region folds.
