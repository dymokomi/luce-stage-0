# Concurrency and workers

Luce's concurrency model is deliberately small: `spawn` starts a function on
another worker, and `wait()` joins it. Each worker has its own runtime, heap,
and scopes. There are no shared mutable objects, locks, atomics, channels, or
`async`/`await` syntax to coordinate.

That is not a missing layer to work around. Ownership is the boundary between
workers. Values copy; an object can cross only when you explicitly move it
with `give` or duplicate it with `copy`; a `file` or another `task` stays in
the runtime that created it. This makes multi-threaded code read like ordinary
Luce code while making races unrepresentable.

## Start one worker

The worker target is a named, capture-free function. `spawn` returns a
scope-owned `task(T)`, where `T` is the function's return type. `wait()` joins
the worker and consumes the task:

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

The task is not a second copy of the worker's result. There is one worker and
one joiner, so a task cannot be copied or waited on twice. If a task reaches
the end of its owning scope without an explicit `wait()`, scope cleanup joins
it for you.

## Move work into the worker

Plain values cross the boundary by value. A list, map, array, or builder is an
owned object, so a worker parameter must say what happens to it. Use `give` to
move the object to the worker:

```luce run
func total(values: give list(long)) -> long:
    var sum: long = 0
    for value in values:
        sum = sum + value
    return sum

func main():
    var mine: list(long) = [1, 2, 3, 4]
    let t = spawn total(give mine)
    print(string(t.wait()))
```

```output
10
```

After `give mine`, the caller no longer owns or uses `mine`. The worker owns
the list while it runs, and the result crosses back through `wait()` when the
worker returns. If the caller needs both copies, write `copy mine` before the
spawn and pass the copy instead.

## Return owned results

A worker may return a resource-free object. The returned object becomes owned
by the scope that receives `wait()`'s result:

```luce run
func squares(n: long) -> list(long):
    var made = new list(long)
    for i in range(0, n):
        made.append(i * i)
    return made

func main():
    let t = spawn squares(4)
    var values = t.wait()
    values.append(100)
    print(string(len(values)))
    print(string(values[4]))
```

```output
5
100
```

The return type cannot contain a `file` or `task`, directly or through a
container. Those resources have one runtime owner and cannot be smuggled
across a worker boundary. Open files in the worker that uses them, or send
plain data and let the parent perform the host operation.

## Handle worker errors

A fallible worker keeps its `!` in the task type. `wait()` returns the same
fallible result, so the parent chooses whether to catch it or let it continue:

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

An error is data that can cross the join. A trap is still a trap: the runtime
reports the worker's trace when the parent joins it. See [Traps are bugs,
errors are news](/guides/failure/) for the rule that separates those outcomes.

## Run several workers

For independent work, keep the tasks in an owning list and join each one:

```luce run
func square(n: long) -> long:
    return n * n

func main():
    var tasks = new list(task(long))
    for i in range(1, 5):
        tasks.append(spawn square(i))
    var total: long = 0
    for task in tasks:
        total = total + task.wait()
    print(string(total))
```

```output
30
```

The list owns each task and cleanup joins any task that the loop did not
consume. Keep the worker function small and pass independent chunks of data;
if every worker immediately waits on another worker, the program is just a
more complicated serial program.

## Choose the boundary deliberately

Workers are useful when the work is independent and the data boundary is
clear: parsing separate files, transforming separate ranges, or performing
CPU-heavy calculations. They are not a substitute for a shared state model.

- Keep host effects at one side of the boundary when their order matters.
- Move an object exactly once, or copy it deliberately when both sides need a
  value.
- Join tasks at the point where their result is needed; scope cleanup remains
  the safety net, not the normal coordination strategy.
- Measure before adding workers. A small task can cost more to start and join
  than the work it performs.

The [Workers chapter in Learn](/learn/threads/) walks through the ownership
refusals in detail. The [type reference](/reference/types/#task) and
[ownership reference](/reference/ownership/) give the complete rules. Typed
channels and shared-memory synchronization are not part of the current
language; the [status page](/status/) records that boundary.
