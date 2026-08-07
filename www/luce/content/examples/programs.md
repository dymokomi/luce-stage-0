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
Luce syntax highlighting — 445 lines, written entirely in Luce. Its
source ships embedded in the `loom` binary, so `loom edit` always
works, and a test in the repository compiles the embedded copy so it
can never rot.

```sh
build/loom edit notes.txt          # Ctrl-S saves, Ctrl-Q quits
build/loom run programs/life.lc
```

The editor is also the honest example of what Luce still lacks: its
key handling is one `elif` chain of fifteen string comparisons with no
final `else`, and its keyword tables are forty-six `word == "…"`
comparisons — a hash set written as a truth table, because there are
no sets and no tagged unions. The [status page](/status/) counts them.
