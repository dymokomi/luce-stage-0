# Install Luce

Luce is a small, statically typed language for programs that should be
easy to read and predictable to run. The fastest way to try it is the
released macOS Apple Silicon toolchain.

## Install on macOS

Run this command in Terminal:

```sh
curl -fsSL https://luce.luciaos.com/install/0.18/install.sh | bash
```

The installer downloads a checked release into `~/.local/luce` and adds
`~/.local/luce/bin` to your shell's startup profile. Open a new shell (or
source the profile it names), then verify the installation:

```text
luce --version
```

The release ships the `luce` compiler and `editor`, the runtime libraries, and
the Luce VS Code extension (plugin) for local VS Code, VS Code Insiders, or
Cursor installations.
If an editor has not been opened yet, it prepares the standard VS Code
extension shelf so the extension is picked up on first launch. Restart the
editor (or reload its window) after installation.
Running the command again always downloads a fresh copy and replaces the
previous installation only after the archive's checksum and contents have
been checked.

This release supports macOS on Apple Silicon (ARM64). Other platforms do
not have a published installer yet.

Your first program is only a few lines long. The [Tour](/tour/) shows the
language's shape in one sitting and points to the detailed Guide.

## Where to go next

Choose the kind of help you need below. [Tour](/tour/) is the one-page
introduction. [Guide](/guide/) is the complete language book: teaching
chapters followed by the exhaustive Language Reference. [Tools](/tools/)
covers the compiler, editor, projects, packages, tests, complete programs, and
performance. [Library](/library/) documents standard modules and maintained
packages. [Status](/status/) records what is available now.
