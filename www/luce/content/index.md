# Install Luce

Luce is a small, statically typed language for programs that should be
easy to read and predictable to run. The fastest way to try it is the
released toolchain for macOS or Linux.

## Install

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

The release ships the `luce` compiler, `loom`, the terminal `editor`, runtime
libraries, TermUI, and the Luce VS Code extension for local VS Code, VS Code
Insiders, or Cursor installations.
If an editor has not been opened yet, it prepares the standard VS Code
extension shelf so the extension is picked up on first launch. Restart the
editor (or reload its window) after installation.
Running the command again always downloads a fresh copy and replaces the
previous installation only after the archive's checksum and contents have
been checked.

The same command selects the right archive for macOS 15 or newer on Apple
Silicon, or for glibc Linux 2.28+ on x86-64 or ARM64. Luce asks the system C
driver (`cc`) to finish native links. The installer checks the operating-system
version and linker before replacing anything and, when the linker is missing,
prints the exact Xcode, Debian/Ubuntu, Fedora/RHEL, or Arch command that supplies
it. Linux with musl and macOS on Intel are not released yet.

The language, compiler, terminal editor, TermUI, and non-graphical standard
library run on all three released targets. `std.ui` and `std.gpu` still have a
Metal host only on macOS; Linux reports that boundary instead of pretending a
window opened.

Your first program is only a few lines long. The [Tour](/tour/) shows the
language's shape in one sitting and points to the detailed Guide.

## Where to go next

Choose the kind of help you need below. [Tour](/tour/) is the one-page
introduction. [Guide](/guide/) is the complete language book: teaching
chapters followed by the exhaustive Language Reference. [Tools](/tools/)
covers the compiler, editor, projects, packages, tests, complete programs, and
performance. [Library](/library/) documents standard modules and maintained
packages. [Status](/status/) records what is available now.
