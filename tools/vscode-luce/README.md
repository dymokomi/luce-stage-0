# Luce language support

This repository-local extension gives Cursor and Visual Studio Code TextMate
highlighting and basic editing behavior for `.luc` files. It has no runtime
dependency on LuciaOS.

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

Or install it in Visual Studio Code:

```sh
code --install-extension /tmp/luce-language.vsix --force
```

Reload the editor window after installation. The workspace recommends the
extension by its identifier, `luciaos.luce-language`.

## Development

Open `tools/vscode-luce` as an extension-development project and press `F5` in
VS Code or Cursor to launch an Extension Development Host. There is no build
step: `package.json`, `language-configuration.json`, and the TextMate grammar
are loaded directly.

The grammar follows the strict Luce contract: `func` declarations,
`func main():` scripts, `func evaluate(input: Input, output: Output):`
evaluators, compiler-generated `Input`/`Output` frame types, and qualified
static calls such as `Rendering.frame(...)`.

When Luce syntax changes, keep
`syntaxes/luce.tmLanguage.json` aligned with `luce/token.zig` and the builtin
list in `luce/analyzer.zig`. The highlighted hosted builtins are implemented:
`script_directory() -> Bytes` obtains a one-run grant for the executing
script's directory, and the general `read_file(Bytes, String) -> String` reads
through an explicit capability. Ordinary evaluators receive that Bytes value
through an Input Port; the terminal's `allow-read` command can issue a
session-only grant. `bootstrap/editor.luc` uses the script grant to load the
readable stored evaluator from `bootstrap/editor_view.luc`.
