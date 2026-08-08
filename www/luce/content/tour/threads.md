# Workers

A **worker** runs one of your functions on a thread of its own,
against a runtime of its own — its own heap, its own scopes, its own
call-depth budget. Nothing a worker touches is reachable from anywhere
else, and nothing anywhere else is reachable from a worker.

That is the whole design, and it is not a new set of rules. It is the
[ownership rules](/tour/ownership/) you already know, applied at one
more boundary: **the ownership model is the concurrency model.** Races
are not detected here, they are unrepresentable.

```luce run
func square(n: long) -> long:
    return n * n

func main():
    let t = spawn square(12)
    print(string(t.wait()))
```

```output
144
```

`spawn f(...)` does not call `f`. It hands `f` and its arguments to a
worker and answers a **`task`** — a handle on the worker, which your
scope owns exactly as it owns a list.

## Waiting

`t.wait()` joins the worker and moves its answer to you, once. The
answer is yours from then on: a list a worker built is a list you own,
and you may append to it.

```luce run
func build(n: long) -> list(long):
    var made = new list(long)
    for i in range(0, n):
        made.append(i * i)
    return made

func main():
    let t = spawn build(4)
    var squares = t.wait()
    squares.append(100)
    print(string(len(squares)))
    print(string(squares[4]))
```

```output
5
100
```

A task is consumed by its wait. Asking twice is refused the way a
second `give` is refused — there is one answer and you have it.

## Arguments cross a boundary

This is the one place a `spawn` differs from a call, and it follows
from the first paragraph: a worker has a heap of its own, so it cannot
*borrow* anything of yours. Every object argument must be moved or
duplicated, and the function has to say so in its signature.

```luce run
func total(values: give list(long)) -> long:
    var sum: long = 0
    for v in values:
        sum = sum + v
    return sum

func main():
    var mine: list(long) = [1, 2, 3, 4]
    let t = spawn total(give mine)
    print(string(t.wait()))
```

```output
10
```

`give` means what it always means: `mine` is poisoned from that line
on, and there is nothing left behind for two threads to disagree
about. `copy mine` hands the worker a duplicate and keeps yours. A
fresh object — a literal, a call's result — needs no verb at all,
because nobody owned it.

Values are values everywhere: numbers, strings, enums, plain structs
and function values all copy across, and you keep your own. A worker
may receive a function value as an ordinary parameter or return one to
the joiner; `spawn` itself still names a declared function call rather
than calling through a local value.

A function whose object parameter is an ordinary borrow cannot be
spawned at all, and the compiler says why:

```luce fail
func total(values: list(long)) -> long:
    return len(values)

func main():
    var mine: list(long) = [1, 2]
    let t = spawn total(give mine)
```

```output
luce: compile failed
main.luc:6:13: total borrows values, and a worker cannot borrow from another runtime; declare it 'give list(long)' [THREADS.md D2] [luce.sema.own]
        let t = spawn total(give mine)
                ^~~~~~~~~~~~~~~~~~~~~~
```

## The scope joins

A task is a scope-owned resource, so releasing one **waits for it**.
That makes structured concurrency a consequence rather than a
discipline: an orphan thread is as unrepresentable as a leaked list.

- the end of the scope that owns the task joins it
- `free(t)` joins it early
- `return t` hands the wait to your caller
- a task nobody waited on is joined all the same, and its answer is
  discarded

```luce run
func announce(n: long) -> long:
    print("worker " + string(n))
    return n

func main():
    let t = spawn announce(1)
    let answered = t.wait()
    print("main " + string(answered))
```

```output
worker 1
main 1
```

Effects from workers are **serialized**: the host's services are
called from one thread at a time, so a `print` from a worker arrives
as a whole line and no host has to be written for threads. A program
that never spawns pays nothing for that — there is no lock in it at
all.

## When a worker fails

Failure crosses the join, and which kind it was decides how.

An **error** is news, so it travels as data. A worker whose function
is `-> T!` gives you a `task(T!)`, and `t.wait()` is a site that says
`try` or `catch` — the words and the place come across whole.

```luce run
func risky(n: long) -> long!:
    if n < 0:
        error("negative input")
    return n

func main() -> !:
    var bad = spawn risky(-1)
    var answered: long = 0
    answered = bad.wait() catch reason:
        print("caught: " + reason)
    let good = spawn risky(7)
    print(string(try good.wait()))
```

```output
caught: negative input
7
```

A **trap** is a bug, and traps are final in every thread. One in a
worker surfaces at the join, carrying the worker's own call trace in
front of yours, and stops the program.

## Many workers

Tasks are ordinary values, so a list of them is an ordinary list, and
joining them in order is an ordinary loop.

```luce run
func square(n: long) -> long:
    return n * n

func main():
    var tasks = new list(task(long))
    for i in range(1, 5):
        tasks.append(spawn square(i))
    var total: long = 0
    for t in tasks:
        total = total + t.wait()
    print(string(total))
```

```output
30
```

## What is not here

There are no locks, no atomics, no shared mutable state, no condition
variables, no thread identifiers, no priorities, and no `async`/`await`
colouring. None of them exists in Luce, and none of them is coming:
their jobs are done by moving ownership, or they do not exist here at
all.

Workers are operating-system threads, so the honest number is
thousands, not millions. Typed channels — pipes whose `send(give x)`
moves an object from one worker to another — are the next piece, and
they build on the boundary this chapter describes.
