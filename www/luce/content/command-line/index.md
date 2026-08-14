# Command Line Tool

The command-line tools are the practical edge of Luce. Install one release,
write `.luc` files, compile executables, run tests, and use the editor with
the same compiler. You do not need GitHub access or a separate runtime
installation.

## Install the release

On macOS with Apple Silicon:

```sh
curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
```

The installer places `luce`, `loom`, `editor`, and their runtime libraries in
`~/.local/luce`, adds the bin directory to your shell's path, and installs the
Luce VS Code extension for VS Code, VS Code Insiders, and Cursor. Running the
command again downloads and verifies a fresh release before replacing the old
one.

## Choose a tool

- [Build and run Luce programs](/command-line/build/) — compile a `.luc` file
  into an executable, a loadable `.lc`, or an object file; run `loom` when you
  need the loadable form.
- [Editor and VS Code](/command-line/editor/) — use the shipped editor or
  local VS Code with Luce syntax support and the same build loop.
- [Organize a project and make a package](/command-line/packages/) — create a
  direct source package, version it, and understand the installed store.
- [Testing](/command-line/testing/) — write `test_*` functions and run them
  predictably with `luce test`.

The [Guide](/guide/) explains the language itself. The [Library](/library/)
documents the modules that ship with it. [Status](/status/) records platform
and feature boundaries.
