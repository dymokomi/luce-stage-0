# Editor Support

The released macOS and Linux toolchains ship two local editing choices:

- `editor`, a terminal editor written in Luce with the maintained `termui`
  package;
- the Luce extension for VS Code, VS Code Insiders, and Cursor.

Both follow the compiler's current syntax. Neither contains a second parser
or type checker whose language rules can drift away from `luce`.

## Open the terminal editor

Pass one or more source paths:

```text
editor hello.luc
editor main.luc geometry.luc tests/geometry_test.luc
```

An unreadable path opens as a new empty buffer, so creating a file and editing
an existing file use the same command. The status line shows the current path,
dirty state, line and scalar column. The editor handles UTF-8 text boundaries
rather than treating a multi-byte character as several cursor positions.

The main keys are:

| Key | Action |
|---|---|
| Ctrl-S | save the current buffer |
| Ctrl-B | save, build a native executable, and run it |
| Ctrl-F | open search; Enter advances and Escape closes it |
| Ctrl-Z / Ctrl-Y | undo / redo |
| Ctrl-A | select all |
| Ctrl-C / Ctrl-X / Ctrl-V | copy / cut / paste; without a selection, copy and cut take the whole line |
| Shift + movement | extend the selection (arrows, Home, End, Page Up/Down) |
| Alt/Ctrl + Left/Right | jump by word; with Shift, extend by word |
| Alt/Ctrl + Backspace | erase the word behind the cursor |
| Ctrl-E | show or hide the file pane |
| Ctrl-O | show or hide the output pane |
| Ctrl-W | move focus to the next visible pane |
| Escape | drop the selection and return focus to the source pane |
| Ctrl-Q | quit; press again to discard unsaved work |

Arrow keys, Home, End, Page Up, Page Down, Backspace, Delete, Enter, and Tab
perform their ordinary source-editing actions. Enter preserves the current
indent and adds one four-space level after a line that opens a block.
Typing over a selection replaces it. A copy lands on the system
clipboard through the terminal (OSC 52), and a paste from the system
clipboard arrives as one edit and one undo step (bracketed paste).

## The language server in the margin

Opening a `.luc` file starts the toolchain's language server,
`luce-lsp`, held as a child for the life of the session. As the buffer
changes, the editor sends it the unsaved text and the compiler's own
diagnostics come back: a diagnosed line's number turns red in the
gutter, and when the cursor stands on one, the status line says the
compiler's sentence for it. The pump runs on the loop's idle tick — a
keystroke never waits on a diagnostic — and a machine without
`luce-lsp` on the path simply leaves the margin quiet. The server
command is data in the editor's source; any LSP server plugs into the
same client.

## Build and run inside the editor

Ctrl-B writes the file, compiles a standalone executable with a `.run` suffix,
runs it, and opens the output pane. Compiler diagnostics and program output
remain visible there until the next build. The command uses the installed
`luce` binary beside the editor executable, so launching from Finder or
another process with a minimal `/bin/sh` environment does not depend on an
interactive shell's `PATH`.

This is the same native pipeline as:

```text
luce build hello.luc -o hello.run
./hello.run
```

The editor intentionally does not invent a separate “run” language mode.
Checks, ARC, host access, traps, and diagnostics are the compiler and runtime's
normal behavior.

## Files, panes, and recovery

The optional file pane lists the current directory and opens the selected
source path. The output pane holds build diagnostics and program output.
Ctrl-W cycles only through panes that are visible; Escape always gets back to
the source.

While a buffer is dirty, the editor periodically writes `FILE.draft` beside
the source by writing a temporary and renaming it into place. After a crash or
interrupted terminal session, reopening the file recovers a different draft
as unsaved work. Ctrl-Z returns to the on-disk version; Ctrl-S accepts the
recovery and removes the draft. A clean save also removes it.

Drafts are a recovery aid, not version control. They are deliberately stored
beside the file so the relationship is visible and recovery remains local.

## VS Code, Insiders, and Cursor

The one-command installer copies the dependency-free Luce extension
into the per-user extension shelf used by local VS Code, VS Code Insiders, or
Cursor. Reload the editor window after installing or updating Luce.

The extension claims `.luc` source files and provides:

- syntax highlighting generated from the compiler's own keyword, type,
  builtin, method, literal, and operator tables;
- four-space, spaces-only indentation;
- comment, bracket, folding, and block rules; and
- brace-aware indentation after a colon inside `()`, `[]`, or `{}`, where
  Luce suspends layout.

It does not claim `.lc` or `.lcm`, which are binary artifacts. It also does
not advertise completion, hover, navigation, refactoring, or diagnostics: no
Luce language server exists yet. Use the integrated terminal for the real
compiler workflow:

```text
luce build hello.luc
./hello
luce test
```

## If an editor does not find Luce

Open a new terminal after installation, or source the profile named by the
installer. `command -v luce` should then point inside
`~/.local/luce/bin`. Running the installer again replaces the toolchain and
repairs its single PATH entry without duplicating it.

The terminal editor's Ctrl-B path is independent of that shell lookup because
the editor finds the sibling compiler. VS Code's integrated terminal inherits
the environment with which the application was launched; restart the
application after an install if an already-open terminal still has the old
PATH.

[The luce and loom Commands](/tools/command-line/) explains build artifacts
and modes. [Testing](/tools/testing/) covers `luce test`, and
[`termui`](/library/termui/) documents the declarative package used to build
the terminal editor itself.
