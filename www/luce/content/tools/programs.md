# Complete Programs

The repository's `examples/` directory contains programs that use Luce
as a normal user would. The samples on this page include those source
files directly, so the documentation and the programs cannot silently
drift apart.

## sort

Sorting, searching and joining a `list[i64]`.

```luce run include=examples/sort/sort.luc
```

```output
-40 -3 0 1 7 8 13 42 77 99
```

## stats — two files

`stats.luc` imports `mathx.luc` as a sibling module. Both compile into
one program and one `.lc`.

It is a small example of [access control](/guide/reference/modules/):
`mathx.sorted` is marked `private`, because it exists for `median` and
for nothing else. `stats.luc` reaches `mean`, `extremes`, `median` and
`deviation`, and reaching `sorted` would be `luce.sema.private`.

```luce module include=examples/stats/mathx.luc
```

```luce run include=examples/stats/stats.luc args=3 1 4 1 5 9 2.6
```

```output
count   7
lowest  1
highest 9
mean    3.6571428571428575
median  3
stddev  2.567298270198316
```

## calc — a recursive-descent parser

Structs as parser state, recursion, checked integer arithmetic, and
the worked example for errors: every way this parser can be defeated
is a way the *user* defeated it, so it raises rather than traps.

```luce run include=examples/calc/calc.luc args="2 + 3 * (10 - 4)"
```

```output
2 + 3 * (10 - 4) = 20
```

## bf — a Brainfuck interpreter

The byte tape is a real `array`, output accumulates in a `builder`,
and `chr()` maps cell values to text.

```luce run include=examples/bf/bf.luc
```

```output
Hello World!
```

## dice — the standard library at work

Deterministic randomness from a seed with no globals, a histogram, and
a file written at the end. `main() -> !` hands what the disk said to
loom.

```luce run include=examples/dice/dice.luc args=7 12
```

```output
12 rolls from seed 7: 2 1 3 2 2 5 3 4 5 1 2 3
total 33, mean 2.75
1: ##
2: ####
3: ###
4: #
5: ##
6: 
rolls written to dice_rolls.txt
```

## wordcount

`map`, `list`, `builder`, file reading and command-line arguments
together.

```luce module file=input.txt
the quick brown fox
jumps over the lazy dog
the fox and the dog and the fox
```

```luce run include=examples/wordcount/wordcount.luc args=input.txt 4
```

```output
9 distinct words in input.txt
  5  the
  3  fox
  2  dog
  2  and
```

## zipper — a real ZIP archive, in and out

The standard library's [`zip`](/library/zip/) module handles the format —
the central directory, DEFLATE and CRC-32. `zipper.luc` connects that
module to files with `main(args)`, `std.files` and `std.paths`.

Names out of an archive are not trusted. An entry may be called
`../../etc/passwd`, and an extractor that joins that to the target
directory and writes what comes out is the bug called zip-slip.
`safe_name` is the one gate every extracted path goes through, and the
`zip` half goes through it too: zipper will not author an archive it
would refuse to extract.

```luce module file=zipper.luc include=examples/zipper/zipper.luc
```

Two files to put in one:

```luce module file=notes.txt
the archive is a container, not a compressor
the compressor is a stream, not a container
```

```luce module file=poem.txt
so much depends
upon a red wheel barrow
glazed with rain water
```

```console
$ luce build zipper.luc --emit=library -o zipper.lc
zipper.luc -> zipper.lc
$ loom run zipper.lc zip papers.zip notes.txt poem.txt
          89  notes.txt
          63  poem.txt
2 files (152 bytes) into papers.zip, 331 bytes
$ loom run zipper.lc list papers.zip
2 entries in papers.zip, 331 bytes
  deflated         89        60  notes.txt
  stored           63        63  poem.txt
$ mkdir -p opened
$ loom run zipper.lc unzip papers.zip opened
          89  opened/notes.txt
          63  opened/poem.txt
2 files extracted into opened
$ cat opened/poem.txt
so much depends
upon a red wheel barrow
glazed with rain water
```

The notes deflate and the poem does not — `Writer.add` offers every
entry to DEFLATE and keeps whichever of the two is smaller, so an
entry never grows by being compressed.

That archive is an ordinary ZIP file: `unzip -t` accepts it, and an
archive Info-ZIP wrote reads back through zipper byte for byte. The
repository proves both — the unconditional half against archives
Info-ZIP wrote that are embedded in the test suite, and the other half
against the system's own `zip` and `unzip` wherever the machine
running the tests has them.

## adventure — a game in five files

`adventure` is a multi-file program. `adventure.luc` coordinates the turn — read a
line, act on it, say what happened — and it imports four modules that
each know one thing:

```text
adventure.luc   the loop, and the only file that talks to the world
  command.luc   what the typing means: a verb, a noun, and the
                synonym tables, all private
  story.luc     what the game is about: eight rooms, seven doors,
                six things, built through world's factories with
                named arguments
    world.luc   what a room, a way and a thing are — three flat
                tables of value structs inside one Realm, every
                field private but the names
  journal.luc   what a save file is: one struct, `text` and `read`
                inverses across it, and `!` all the way down
```

It demonstrates several features together: private
fields with public [factories](/guide/reference/modules/), `T?` narrowed in
the command loop, an [error](/guide/reference/failure/) chain three files deep
caught once at the top, reference values shared across module calls, and
`exit(0)` when the player types `quit`.

It is interactive, so the page cannot play it for you. Run it from a
terminal and provide commands on standard input.

```sh
loom run examples/adventure/adventure.lc          # a new game
loom run examples/adventure/adventure.lc rescue   # resume rescue.sav
```

## The ones that need a terminal

Two programs need a real terminal screen and are not run in a static
page:

`examples/life/life.luc` is Conway's Life on the terminal grid.

`examples/editor/editor.luc` is a full-screen editor with
movement, editing, scrolling, line numbers, a status bar, a file pane,
an output pane and Luce syntax highlighting. It draws through the
`termui` package, which manages the terminal cell grid and input events.
The build installs it as an ordinary program.

```sh
editor notes.txt                   # Ctrl-S saves, Ctrl-Q quits
loom run examples/life/life.lc
```

Ctrl-B saves the current file, compiles it as a standalone executable, and
runs it. The output appears in the editor's output pane. The editor locates
the installed compiler beside itself, so this also works when it was opened
from Finder or another launcher that did not load your interactive-shell PATH.

The editor translates terminal key names to an `Intent` enum at the
host boundary, then dispatches with an exhaustive `match`. Its keyword
and builtin tables are immutable maps. This keeps input decoding and
editor behavior separate; the [status page](/status/) records the
remaining tooling work.

## lsp — the language server, in Luce

`lsp` is the Luce language server: a Luce program speaking the Language
Server Protocol over standard input and output. Five files split the
problem the way the protocol does:

```text
lsp.luc          the loop, and the only file that talks to the world
frames.luc       Content-Length framing over std.io byte streams
server.luc       what each LSP method means; documents live here
diagnostics.luc  the compiler's JSON answer becomes publishDiagnostics
positions.luc    scalar columns become 0-based UTF-16 characters
```

It stands on the pieces the toolchain grew for it: `os.stdin()` and
`os.stdout()` carry the protocol, and every changed buffer is fed to
`luce query diagnostics -` through `os.run`'s standard-input feed — so
an editor sees the compiler's own diagnostics for text it has not
saved. The compiler sits behind a one-method `Compiler` interface, so
the server's tests script it.

```sh
luce build examples/lsp/lsp.luc -o luce-lsp
# point an LSP client at the binary; it announces full-document sync
```
