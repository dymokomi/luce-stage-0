# Concurrency

Luce has one concurrency primitive: `spawn` starts a named function on another
worker, and `wait()` joins it. Each worker has its own runtime and heap. Objects
are never shared between workers, so Luce does not need locks around ordinary
language values.

This is isolation, not shared-memory threading. Data crossing a worker boundary
is copied into the receiving runtime. A container graph arrives as an
independent graph with no identity shared with the sender.

## Start one worker

The worker target is a named function. `spawn` returns a `task[T]`, where `T`
is the function's return type. `wait()` joins the worker and returns its answer:

```luce run
func square(n: i64) -> i64:
    return n * n

func main():
    let work = spawn square(12)
    print(str(work.wait()))
```

```output
144
```

`wait()` observes a task once. ARC also joins an unfinished worker when its
task's last reference is released. Call `wait()` when you need the answer;
otherwise last-release cleanup joins and discards it.

## Send independent data

Scalars, strings, enums, and reference-free structs cross a worker boundary by
value. The worker receives an independent value, so later caller changes do
not race with it:

```luce run
struct Work:
    first: i64
    second: i64

func total(work: Work) -> i64:
    return work.first + work.second

func main():
    var values = Work(first = 4, second = 6)
    let task = spawn total(values)
    values.second = 20
    print(str(task.wait()))
    print(str(values.second))
```

```output
10
20
```

The worker saw the original value snapshot while the caller changed its own
struct. The boundary also has a recursive copier for permitted lists, maps,
arrays, builders, structs, unions, and optionals. It preserves aliases within
the copied graph and across separate arguments while sharing no identity with
the caller. The caller can continue using and mutating its original graph.

Classes and callable environments are different. A graph containing a class —
including a resource class such as `files.File` — a `task`, or a function
value cannot cross. Open a file in the worker that uses it, wait for child
tasks in the worker that created them, and name the function the worker
should run instead of sending a function value.

## Return a graph

A worker may build a reference graph and return it. `wait()` copies that graph
into the joiner's runtime before the worker runtime is torn down:

```luce run
func squares(n: i64) -> list[i64]:
    var made = new list[i64]
    for i in range(0, n):
        made.append(i * i)
    return made

func main():
    let work = spawn squares(4)
    var values = work.wait()
    values.append(100)
    print(f"{len(values)} {values[4]}")
```

```output
5 100
```

A result graph also cannot contain a class, `task`, or function value. A task
has one runtime on each side of its join; it does not move another live runtime
through itself.

## Handle worker errors

A fallible worker keeps its `!` in the task type. The error crosses at
`wait()`, where the parent handles it or passes it on:

```luce run
func risky(n: i64) -> i64!:
    if n < 0:
        error("negative input")
    return n

func main() -> !:
    var bad = spawn risky(-1)
    var answered: i64 = 0
    answered = bad.wait() catch reason:
        print("caught: " + reason)
    let good = spawn risky(7)
    print(str(try good.wait()))
```

```output
caught: negative input
7
```

An error is data. A trap remains a trap: an explicit wait reports the worker's
trace followed by the joining call. Completed automatic cleanup discards an
unobserved answer, error, or trap after joining.

## Run several workers

Tasks are ARC references and can be stored in ordinary aggregates. Join them in
the order in which your program needs their results:

```luce run
func square(n: i64) -> i64:
    return n * n

func main():
    var tasks = new list[task[i64]]
    for i in range(1, 5):
        tasks.append(spawn square(i))
    var total: i64 = 0
    for work in tasks:
        total += work.wait()
    print(str(total))
```

```output
30
```

Workers are OS threads, suited to a bounded amount of independent work. The
cost includes starting a thread and copying the argument and result graphs, so
measure before splitting small calculations.

## The boundary to remember

- Workers share program code and serialized host services, not Luce objects.
- Arguments are copied into the worker runtime at `spawn`.
- Results and recoverable errors are copied back at `wait()`.
- Classes (including `files.File`), `task`, and function values cannot occur
  anywhere in a crossing graph.
- A worker may spawn another worker; each task is joined exactly once.

For exact task shapes and refusals, see [`task`](/guide/reference/types/#task)
and [Memory Management](/guide/reference/memory/#m14). The [status
page](/status/) records the intentionally absent shared-memory and asynchronous
features.
