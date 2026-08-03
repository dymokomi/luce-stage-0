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

The grammar follows the strict Luce contract: `func` declarations, the one
`func main():` entry, and qualified static calls such as
`Rendering.frame(...)`.

When Luce syntax changes, keep `syntaxes/luce.tmLanguage.json` aligned with
`src/luce/02_lex/token.zig` and the reserved-name list in
`src/luce/04_semantics/declarations.zig`.
