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
[`os.run`](/library/os/) data. The error channel carries what it
always carries: the world refusing — an unreachable host, a reset
connection, a reply that is not HTTP.

## Fetch

```text
http.get(url: str) -> http.Response ! http.HttpError
http.post(url: str, body: list[u8], content_type: str) -> http.Response ! http.HttpError
```

The URL is `http://host[:port]/path`; the port defaults to 80 and a
missing path means `/`. `https` is refused with an honest sentence —
TLS is a planned addition over platform TLS, and pretending otherwise
would be worse than saying so.

Each call is one exchange on one connection: the request goes out with
`Connection: close`, and the end of the reply is the end of the
stream. A `post` carries its body with the `Content-Type` it was
handed and the `Content-Length` it measured.

## A client

```text
http.Client(base: str = "")
client.header(name: str, value: str)
client.get(path: str) -> http.Response ! http.HttpError
client.post(path: str, body: list[u8], content_type: str) -> http.Response ! http.HttpError
```

A `Client` carries what every request repeats: the base each path is
joined onto, and the headers sent with every exchange.

```text
var api = http.Client("http://127.0.0.1:8080")
api.header("authorization", "Bearer " + token)
let answer = try api.get("/status")
```

A client with no base takes whole URLs, which makes it exactly the
free functions plus default headers. Each request still dials its own
connection and closes it — `Client` adds no keep-alive pool, and says
so rather than pretending.

## The answer

```text
struct Response:
    status: i64
    headers: map[str, str]
    body: bytes

    func ok() -> bool
    func text() -> str?
    func json() -> json.Json ! json.Malformed
```

`status` is the number the server said. `headers` holds each header
name lowercased, with the last value winning — the flat map a program
actually asks, not a model of every duplicate-header corner. `body` is
the decoded bytes: a chunked reply is de-chunked, so what the program
reads is what the server meant.

`ok()` is the one predicate almost every caller writes: 200 through
299\. `text()` answers the body as UTF-8 text, or absent when it is
not — the parse shape. `json()` answers the body as a
[`json.Json`](/library/json/) document, and a body that is not text or
not JSON fails with `json`'s own
[`Malformed`](/library/json/#input-limits-and-refusals) union, passed
through whole — the json module is the authority on why a document is
wrong, and its position payload is worth keeping.

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
    let door = try network.Listener(18641)
    let guest = try door.accept()
    var request = array[u8](2048)
    let heard = try guest.read(request)
    if heard <= 0:
        error("the guest said nothing")
    var reply = "HTTP/1.1 200 OK" + crlf
    reply = reply + "Content-Type: text/plain" + crlf
    reply = reply + "Content-Length: 9" + crlf + crlf
    reply = reply + "from luce"
    var wire = strings.to_bytes(reply)
    var buffer = array[u8](2048)
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
        headers = map[str, str](),
        body = bytes(list[u8]()),
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

func try_once() -> http.Response ! http.HttpError:
    return try http.get("http://127.0.0.1:18641/")

func main() -> !:
    let server = spawn serve_one()
    let page = try fetch()
    print(str(page.status))
    var held = list[u8]()
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

The request path fails with one union:

```text
union HttpError:
    unsupported(reason: str)
    bad_url(reason: str, url: str)
    protocol(reason: str)
    io(reason: str)
```

`unsupported` is the honest https refusal. `bad_url` is an address
this module cannot read — not-http, no host, a port that is not a
number — with the address in its own payload. `protocol` is a reply
that is not HTTP: a malformed status line, headers that never finish,
a broken chunk. `io` wraps the transport refusing — `std.network` and
`std.io` fail with the host's own `str` sentence, and the exchange
catches it and re-raises `HttpError.io`, so the conversion is visible
where it happens. `match` reads the members apart; `http.describe`
renders the one-line sentence.

| Signature | Result |
|---|---|
| `http.describe(failed: HttpError) -> str` | the refusal as one sentence |

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
