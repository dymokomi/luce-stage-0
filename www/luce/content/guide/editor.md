# Editor Support

Luce ships with two ways to edit programs locally:

- `editor`, a small terminal editor written in Luce;
- the Luce VS Code extension, also picked up by VS Code Insiders and Cursor.

Both use the installed `luce` compiler. There is no second language service
or hidden compiler to keep in sync.

## The shipped editor

Open a source file from a terminal:

```text
editor hello.luc
```

The editor keeps the source file beside the executable it builds. Ctrl-B saves
the current file, compiles a standalone executable with a `.run` suffix, and
runs it in the output pane. Ctrl-S saves without running; Ctrl-Q quits. When
the editor was opened from Finder or another launcher, it still finds the
compiler installed beside it rather than depending on the launcher's shell
profile.

## VS Code, Insiders, and Cursor

The macOS installer copies the Luce extension into the local extension shelf.
Restart the editor, or reload its window, after installing so syntax
highlighting is active. The extension is intentionally small: it provides
Luce's real keyword, type, builtin, method, comment, string, and number
vocabulary without pretending that unsupported language-server features
exist.

Use the integrated terminal for the same build loop:

```text
luce build hello.luc
./hello
```

[Command-Line Tools](/guide/command-line/) explains output shapes, debug and
release builds, and `loom`. The [Guide](/guide/) explains the language and
the [Library](/library/) explains its modules.
