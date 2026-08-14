# Workers

`spawn` runs a function on a worker thread. The worker has its own runtime,
heap, scopes, and call-depth budget. It cannot borrow objects from the
spawning runtime; ownership and value rules determine what may cross.

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

`spawn` returns a scope-owned `task`. A task is not copyable.

## Waiting

`wait()` joins the worker and transfers a resource-free result to the caller.
It can be called once:

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

## Arguments across runtimes

Values copy across the boundary. An object graph must be moved with `give`
or duplicated with `copy`; a worker function must declare an object
parameter as `give` because a borrow cannot point into another runtime:

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

Resources and graphs containing a `file` or `task` stay in the runtime that
created them:

```luce fail
func inspect(opened: give file) -> long:
    return 1

func main():
    var opened: file
    let t = spawn inspect(give opened)
```

```output
luce: compile failed
main.luc:6:13: parameter opened of inspect is file, which carries a file or task; a resource stays in the Runtime that created it and cannot cross a worker boundary [THREADS.md D1, D2] [luce.sema.own]
        let t = spawn inspect(give opened)
                ^~~~~~~~~~~~~~~~~~~~~~~~~~
```

A borrowed object parameter is also refused as a worker target:

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

## Scope joins

Because a task is a resource, releasing it waits for its worker. Scope exit,
`free(t)`, or returning the task to the caller all preserve this join rule.

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

Worker effects are serialized by the host. A program that never spawns does
not pay for worker coordination.

## Errors from a worker

An error crosses `wait()` as a fallible result. A trap remains a trap and is
reported at the join with the worker's trace.

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

## Several workers

Tasks can be stored in a resource-owning list and joined in a loop:

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

There are no shared mutable objects, locks, atomics, condition variables,
thread identifiers, or `async`/`await` syntax in this model. Typed channels
are a separate future design; see the [status page](/status/) for current
availability. For design patterns and advice on choosing worker boundaries,
continue with [Concurrency and workers](/guide/concurrency/). Next: [Where to
go next](../next/).
