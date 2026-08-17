# std.http

`std.http` is the HTTP/1.1 client, written in ordinary Luce over
[`std.network`](/library/network/) the way `std.zip` is written over
bytes: the transport moves them, this module says what they mean.

```text
import std.http
```

**A status code is data, never an error.** A 404 is the server
answering, and the answer arrives in `Response.status` for the program
to read — the same rule that makes a non-zero exit from
[`os.shell.run`](/library/os/) data. The error channel carries what it
always carries: the world refusing — an unreachable host, a reset
connection, a reply that is not HTTP.

## Fetch

```text
http.get(url: str) -> http.Response!
http.post(url: str, body: list[u8], content_type: str) -> http.Response!
```

The URL is `http://host[:port]/path`; the port defaults to 80 and a
missing path means `/`. `https` is refused with an honest sentence —
TLS is a planned addition over platform TLS, and pretending otherwise
would be worse than saying so.

Each call is one exchange on one connection: the request goes out with
`Connection: close`, and the end of the reply is the end of the
stream. A `post` carries its body with the `Content-Type` it was
handed and the `Content-Length` it measured.

## The answer

```text
struct Response:
    status: i64
    headers: map[str, str]
    body: bytes
```

`status` is the number the server said. `headers` holds each header
name lowercased, with the last value winning — the flat map a program
actually asks, not a model of every duplicate-header corner. `body` is
the decoded bytes: a chunked reply is de-chunked, so what the program
reads is what the server meant.

## A server and its client, in one program

`std.http` and `std.network` meet in the middle: a worker serves one
request over the transport while the main program fetches it. This is
a whole HTTP conversation with no other software involved — and a
preview of the shape `std.server` will grow from.

```luce run
import std.http
import std.network
import std.os
import std.strings

func serve_one() -> !:
    let crlf = str(char(13)) + "\n"
    let door = try network.listen(18641)
    let guest = try door.accept()
    var request = new array[u8](2048)
    let heard = try guest.read(request)
    if heard <= 0:
        error("the guest said nothing")
    var reply = "HTTP/1.1 200 OK" + crlf
    reply = reply + "Content-Type: text/plain" + crlf
    reply = reply + "Content-Length: 9" + crlf + crlf
    reply = reply + "from luce"
    var wire = strings.to_bytes(reply)
    var buffer = new array[u8](2048)
    var at: i64 = 0
    while at < len(wire):
        buffer[at] = wire[at]
        at += 1
    var sent: i64 = 0
    while sent < len(wire):
        let landed = try guest.write(buffer, len(wire))
        if landed <= 0:
            error("the reply made no progress")
        sent += landed
    try guest.flush()

func fetch() -> http.Response!:
    let not_yet = http.Response(
        status = 0,
        headers = new map[str, str],
        body = bytes(new list[u8]),
    )
    var tries = 0
    while true:
        let page = try_once() catch not_yet
        if page.status != 0:
            return page
        tries += 1
        if tries > 50:
            error("the server never came up")
        os.sleep_ms(10)

func try_once() -> http.Response!:
    return try http.get("http://127.0.0.1:18641/")

func main() -> !:
    let server = spawn serve_one()
    let page = try fetch()
    print(str(page.status))
    var held = new list[u8]
    for b in page.body:
        held.append(b)
    let text = strings.from_bytes(held)
    if text == none:
        print("not text")
        return
    print(text)
    try server.wait()
```

```output
200
from luce
```

The retry loop is the honest part: the worker owns its listener — a
resource never crosses a worker boundary — so the client cannot know
the door is open except by knocking.

## Errors

Transport refusals travel unchanged from `std.network`: `io_failed`
with the reason. This module adds only the sentences the protocol
earns — `not an HTTP reply`, `not a chunk size`, `the reply never
finished its headers` — each carried in the ordinary error channel and
caught with `catch` like every other.

## Deliberately absent

- **Keep-alive and pooling.** One request, one connection: nothing to
  manage, nothing to leak. A pool earns its place when something
  measures the need.
- **Redirect following.** A 3xx arrives as data with its `location`
  header; following it is three lines a program writes on purpose.
- **TLS.** Planned over platform TLS; until then `https` is refused
  with the reason.
- **A request-building surface.** `get` and `post` are the shipped
  verbs; more arrive when something real asks for them.
