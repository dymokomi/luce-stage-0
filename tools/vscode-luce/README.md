# Luce language support

A repository-local extension that gives Visual Studio Code and Cursor TextMate
highlighting and basic editing behavior for `.luc` files. It has no runtime
dependency on LuciaOS: three files, no build step, no code.

- `syntaxes/luce.tmLanguage.json` — **generated**, see below.
- `language-configuration.json` — comments, brackets, folding, indentation.
  Hand-written and deliberately word-free: the indent rule is "a line that ends
  in a colon opens a block", which is true of `func`, `struct`, `if`, `elif`,
  `else`, `while`, `for` and `catch` alike and stays true of whatever opens a
  block next.
- `package.json` — what VS Code loads.

## The grammar is generated, and pinned

`syntaxes/luce.tmLanguage.json` is written by `tools/grammar.zig` from the
compiler's own tables — the lexer's keyword table, the reserved-name list, the
free-builtin table, and the five method tables — and must not be edited by
hand.

```sh
zig build grammar     # rewrite syntaxes/luce.tmLanguage.json
```

**Why.** The hand-written grammar this replaced spent a release cycle
highlighting `create_texel`, `texel_output`, `texel_evaluator` and `read_file`
— Fabric and host builtins the language had deleted — and knew nothing of
`give`, `copy`, `new`, `try`, `catch`, `none`, or of `List`, `Map`, `Array` and
`Builder`, whose place in its type list was still held by the removed `Input`
and `Output`. It listed `input`/`output` port members that no longer exist.
Nothing tied it to the language, so nothing said anything for a year.

**The pin.** `zig build test` runs
`test "the committed grammar is what the generator emits"`, which embeds this
file and compares it byte-for-byte against a fresh run of the generator. Add a
keyword, a builtin or a method to the language without regenerating and the
suite fails, naming this path. Two more tests in the same file keep the
generator honest: every keyword the lexer reserves must have a class, and every
name in `reserved_names` must be coloured exactly once — no name uncoloured, no
name claimed by two classes. A fourth reads `programs/editor.luc`, the largest
Luce program there is, and checks that every language word it actually uses has
a class.

## What is coloured

| Scope | What it covers |
| --- | --- |
| `keyword.control.luce` | `if`, `elif`, `else`, `while`, `for`, `in`, `return`, `break`, `continue` |
| `keyword.control.exception.luce` | `try`, `catch` |
| `keyword.control.import.luce` | `import`, and the module path after it |
| `keyword.operator.word.luce` | `and`, `or`, `not` |
| `keyword.other.ownership.luce` | `new`, `give`, `copy`, `free` — the words that move ownership, in a class of their own |
| `storage.type.luce` | `func`, `struct`, `let`, `var` |
| `constant.language.luce` | `true`, `false`, `none` |
| `support.type.luce` | `Int`, `Float`, `Bool`, `String`, `List`, `Map`, `Array`, `Builder`, `None` |
| `entity.name.type.luce` | every other capitalised name — the convention the language enforces for structs |
| `support.function.builtin.luce` | the pure free builtins, plus `range` |
| `support.function.builtin.host.luce` | the host-gated builtins, which need `allow_host` |
| `support.function.method.luce` | the receiver methods, **only** after a `.` |
| `entity.name.function.luce` | the name a `func` declares, and a qualified call's tail |
| `keyword.operator.optional.luce` / `.fallible.luce` | the `T?` and `T!` markers |
| `invalid.illegal.number.luce` | the numeric literals the lexer refuses |

Two decisions worth knowing about:

- **Methods are coloured only behind a dot.** `find`, `get`, `clear` and
  `values` are words a program may perfectly well use for a function of its
  own; `xs.find(1)` is the language and a bare `find(1)` is not.
- **An f-string hole is real code.** `f"total {n + 1}"` highlights the
  expression inside the braces, using the same rules as everything outside a
  string except strings and comments — which a hole cannot contain, because the
  lexer scans an f-string as one token that ends at the first unescaped quote.
  `{{` and `}}` are literal braces.

The invalid-number rules follow the lexer exactly, including the boundaries it
draws: `1.2.3` is one mistake rather than a float and an integer, `0755` is
refused because Luce has no octal literals, `1.` needs a digit after the point
while `1.foo` is member access, and a radix prefix or digit separator is one
malformed literal rather than a number glued to a word.

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
itself — the three files are loaded directly — but a change to the grammar is a
change to `tools/grammar.zig` followed by `zig build grammar`, never an edit to
the JSON.
