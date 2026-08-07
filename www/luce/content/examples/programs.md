# The bundled programs

`programs/` in the repository is Luce's userland. These pages show the
real files, compiled and run from their own source when this site is
built — so if one of them changes, this page changes with it, or the
build stops.

## sort

Sorting, searching and joining a real `list(long)`.

```luce run include=programs/sort.luc
```

```output
-40 -3 0 1 7 8 13 42 77 99
```

## stats — two files

`stats.luc` imports `mathx.luc` as a sibling module. Both compile into
one program and one `.lc`.

It is also the tree's worked example of [visibility](/tour/visibility/):
`mathx.sorted` is marked `private`, because it exists for `median` and
for nothing else. `stats.luc` reaches `mean`, `extremes`, `median` and
`deviation`, and reaching `sorted` would be `luce.sema.private`.

```luce module include=programs/mathx.luc
```

```luce run include=programs/stats.luc args=3 1 4 1 5 9 2.6
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

```luce run include=programs/calc.luc args="2 + 3 * (10 - 4)"
```

```output
2 + 3 * (10 - 4) = 20
```

## bf — a Brainfuck interpreter

The byte tape is a real `array`, output accumulates in a `builder`,
and `chr()` maps cell values to text.

```luce run include=programs/bf.luc
```

```output
Hello World!
```

## dice — the standard library at work

Deterministic randomness from a seed with no globals, a histogram, and
a file written at the end. `main() -> !` hands what the disk said to
loom.

```luce run include=programs/dice.luc args=7 12
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

`map`, `list`, `builder`, file reading and arguments together.

```luce module file=input.txt
the quick brown fox
jumps over the lazy dog
the fox and the dog and the fox
```

```luce run include=programs/wordcount.luc args=input.txt 4
```

```output
9 distinct words in input.txt
  5  the
  3  fox
  2  dog
  2  and
```

## zipper — a real ZIP archive, in and out

The standard library's [`zip`](/std/zip/) module is the format —
the central directory, DEFLATE both ways, the CRC-32 — and it takes
bytes and answers bytes, deliberately. `zipper.luc` is the two hundred
lines between that and a disk: `main(args)`, `std.files`'s byte path,
and `std.paths` for the joining.

Names out of an archive are not trusted. An entry may be called
`../../etc/passwd`, and an extractor that joins that to the target
directory and writes what comes out is the bug called zip-slip.
`safe_name` is the one gate every extracted path goes through, and the
`zip` half goes through it too: zipper will not author an archive it
would refuse to extract.

```luce module file=zipper.luc include=programs/zipper.luc
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
$ luce build zipper.luc -o zipper.lc
zipper.luc -> zipper.lc
$ loom run zipper.lc zip papers.zip notes.txt poem.txt
          89  notes.txt
          63  poem.txt
2 files (152 bytes) into papers.zip, 331 bytes
$ loom run zipper.lc list papers.zip
2 entries in papers.zip, 331 bytes
  deflated         89        60  notes.txt
  stored           63        63  poem.txt
$ mkdir opened
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

The largest program in the tree, and the one written to be read as a
*project* rather than a file. `adventure.luc` is the turn — read a
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

It is the tree's worked example of several things at once: private
fields with public [factories](/tour/visibility/), `T?` narrowed in
the command loop, a [failure](/ref/failure/) chain three files deep
caught once at the top, `give` and `copy` where a list crosses a
module boundary, and `exit(0)` when the player types `quit`.

It cannot be shown running on this page, because a page has no
keyboard — but it is played entirely through standard input, which is
how its specification in the repository drives a whole playthrough on
both engines and compares every byte of it.

```sh
build/loom run programs/adventure.lc          # a new game
build/loom run programs/adventure.lc rescue   # resume rescue.sav
```

## The ones that need a terminal

Two programs cannot be shown here, because they draw on a real screen.

`programs/life.luc` is Conway's Life on the terminal grid.

`programs/editor.luc` is the flagship: a full-screen editor with
movement, editing, scrolling, line numbers, a status bar and per-line
Luce syntax highlighting — 612 lines, written entirely in Luce. Its
source ships embedded in the `loom` binary, so `loom edit` always
works, and a test in the repository compiles the embedded copy so it
can never rot, while another drives it through every key it handles
and compares the whole terminal transcript, byte for byte, on both
engines.

```sh
build/loom edit notes.txt          # Ctrl-S saves, Ctrl-Q quits
build/loom run programs/life.lc
```

The editor used to be the honest example of what Luce still lacked:
key handling as one `elif` chain of fifteen string comparisons with no
final `else`, and keyword tables as forty-six `word == "…"`
comparisons. Enums took the first two — a keystroke becomes an
`Intent` once, at the edge, and a `match` with an arm for every member
decides what it does — and the truth tables became two space-fenced
string constants searched with `strings.find`. What is left is the
last of it: that is a *search*, and a frozen set would make it a
lookup. The [status page](/status/) says where that stands.
