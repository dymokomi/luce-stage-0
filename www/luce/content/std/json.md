# std.json

JSON, in pure Luce. Parse text into a value, ask a value what it is
with `match`, build values directly, write one back. Nothing here is a
builtin, nothing here imports anything — not even `std.strings` — and
nothing here touches the host: `parse` takes a string and answers a
`Json`, and where the string came from is the caller's business.

```
import std.json
```

Written against **RFC 8259**, and every rule in the source names the
clause it implements: §2 the structural characters and the four
whitespace bytes, §3 the three literal names, §4 objects, §5 arrays,
§6 numbers, §7 strings and their escapes, §8.1 encoding, §8.2 unpaired
surrogates, §9 nesting. ECMA-404 is cited where the two documents
leave a reader a choice. The specification is mostly **refusals** — a
parser is defined by what it will not take — and its fixtures are
Nicolas Seriot's JSONTestSuite (*Parsing JSON is a Minefield*, 2016):
the `y_` rows every parser must accept, the `n_` rows every parser
must refuse, and the `i_` rows real parsers disagree about.

## A JSON value is a union

RFC 8259 says a value is one of six things, and two of the six contain
more values. That is the whole type:

```text
union Json:
    null
    boolean(value: bool)
    integer(value: long)
    real(value: double)
    text(value: string)
    array(items: list(Json))
    object(fields: map(string, Json))
```

Seven members for six kinds, because JSON's one number type arrives
here as the two Luce has — see [numbers](#numbers) below. `null` is
first, so it is also the zero: what a `var j: json.Json` starts at,
and what makes `list(json.Json)` constructible at all.

`match` is the only door. There is no field access on a union value
and no tag test, so asking a number for its members is not a checked
error — it is a program that does not compile.

```luce run
import std.json

func label(held: json.Json) -> string:
    match held:
        null:
            return "null"
        boolean(value):
            return "boolean " + string(value)
        integer(value):
            return "integer " + string(value)
        real(value):
            return "real " + string(value)
        text(value):
            return "text " + value
        array(items):
            return "array of " + string(len(items))
        object(fields):
            return "object of " + string(len(fields))

func main() -> !:
    let doc = try json.parse("[null, true, 7, 7.5, \"s\", [1], {\"a\": 1}]")
    match doc:
        array(items):
            for item in items:
                print(label(item))
        else:
            trap("a parsed array is an array")
```

```output
null
boolean true
integer 7
real 7.5
text s
array of 1
object of 1
```

There is no `else` in `label`, so the day an eighth member is added,
that function stops compiling and names it.

## Reading

| Signature | Notes |
|---|---|
| `json.parse(content: string) -> Json!` | the whole grammar, or an error naming the byte and the problem |
| `json.quote(content: string) -> string` | text as a JSON string literal, the escaping done right |
| `j.is_null() -> bool` | true for JSON's `null`, which is a value that is *there* |
| `j.as_bool() -> bool?` | absent for every other member |
| `j.as_long() -> long?` | absent unless the number was written whole |
| `j.as_double() -> double?` | either number member; a whole one widens |
| `j.as_text() -> string?` | the string, escapes already spent |
| `j.count() -> long` | members or elements; 0 for a leaf |
| `j.member(name: string) -> Json?` | an object's member **as a copy**, or absent |
| `j.element(index: long) -> Json` | an element or a positioned member **as a copy**; past the end traps |
| `j.write() -> string` | the value as JSON with nothing between the tokens |
| `j.pretty(spaces: long) -> string` | the same, indented |

The walking form copies nothing: `match` hands you the `map` or the
`list` itself, and reading through that binding is a borrow.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("{\"host\": \"localhost\", \"port\": 8080, \"debug\": false}")
    match doc:
        object(fields):
            print(fields["host"].as_text() else "?")
            print(string(fields["port"].as_long() else 0))
            print(string(fields["debug"].as_bool() else true))
        else:
            trap("a config file is an object")
```

```output
localhost
8080
false
```

`member` and `element` are the other half of that pair, for a caller
who wants to **keep** what it found. They answer a copy, and they have
to: a value read out of a container has an owner already
([S17](/ref/ownership/#s17), [S22](/ref/ownership/#s22)), so the only
thing a function can hand back is one of its own. For a leaf that is a
number or a string; for a subtree it is the subtree.

```luce run
import std.json

func child(value: json.Json, name: string) -> json.Json:
    let found = value.member(name)
    if found != none:
        return found
    trap("no member named " + name)

func main() -> !:
    let doc = try json.parse("{\"server\": {\"host\": \"localhost\", \"ports\": [80, 443]}}")
    let server = child(doc, "server")
    print(child(server, "host").as_text() else "?")
    print(string(child(server, "ports").count()))
    print(string(child(server, "ports").element(1).as_long() else 0))
    print(string(doc.member("missing") == none))
```

```output
localhost
2
443
true
```

There is no `has`. It is a reserved name in Luce — it is `m.has(k)`,
the map method — so `j.member(name) != none` is the membership
question for a caller holding a value, and `fields.has(name)` is it
for a walk that already matched.

## Building

The map and the list *are* the builder, so ownership is taken once, at
the outermost value. Every inner value is fresh and silent
([S20](/ref/ownership/#s20)); the one `give` is on the last line,
where a named object moves into a value that outlives the name
([S24](/ref/ownership/#s24)).

```luce run
import std.json

func main():
    var fields = new map(string, json.Json)
    fields["name"] = json.Json.text(value = "luce")
    fields["version"] = json.Json.integer(value = 2)
    fields["ratio"] = json.Json.real(value = 0.5)
    fields["tags"] = json.Json.array(items = [json.Json.text(value = "lang")])
    fields["nothing"] = json.Json.null
    let doc = json.Json.object(fields = give fields)
    print(doc.write())
    print(doc.pretty(2))
```

```output
{"name":"luce","version":2,"ratio":0.5,"tags":["lang"],"nothing":null}
{
  "name": "luce",
  "version": 2,
  "ratio": 0.5,
  "tags": [
    "lang"
  ],
  "nothing": null
}
```

Editing works the same way from the other end: an arm's payload
binding **aliases** what the scrutinee owns, so mutating the list or
the map it names mutates the tree — no verb, no copy, no second owner.

```luce run
import std.json

func bump(value: json.Json):
    match value:
        object(fields):
            if fields.has("port"):
                let held = fields["port"].as_long() else 0
                fields["port"] = json.Json.integer(value = held + 1)
            for name, entry in fields:
                bump(entry)
        array(items):
            for item in items:
                bump(item)
        else:
            return

func main() -> !:
    let doc = try json.parse("{\"servers\":[{\"port\":80},{\"port\":8080}],\"port\":1}")
    bump(doc)
    print(doc.write())
```

```output
{"servers":[{"port":81},{"port":8081}],"port":2}
```

**Ownership** is scope ownership with nothing new in it. A `Json`
carries objects, so it takes `give` and `copy` where any carrying
value does, and the binding that received it frees it — recursively,
through the containers. There is no arena, no collector, and no
`deinit` to remember.

## Numbers

JSON has one number type and Luce has two, so the **notation is the
member**: `42` is `Json.integer` and `4.2`, `42.0` and `4.2e1` are all
`Json.real`. A language with no implicit narrowing cannot hand a
`long` out of a `double` without inventing or discarding information,
so the split is where it has to be — and it is the split Zig's
`std.json`, serde_json, Jackson and System.Text.Json all make.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("[42, 42.0, 4.2e1, 9223372036854775808]")
    print(string(doc.element(0)) + " " + string(doc.element(0).as_long() else -1))
    print(string(doc.element(1)) + " " + string(doc.element(1).as_long() == none))
    print(string(doc.element(2)) + " " + string(doc.element(2).as_double() else 0.0))
    # Too large for a long, so it is a real — which is where its
    # precision honestly is.
    print(string(doc.element(3)) + " " + string(doc.element(3).as_long() == none))
```

```output
integer 42
real true
real 42
real true
```

`as_long` therefore reads the notation and not the value, exactly as
it always did — but the rule is now the member the value *is*, checked
by the compiler, instead of a re-reading of the text.

A number past what a `double` can hold is **refused**, at the byte.
§6 lets an implementation limit the range it accepts, and the eager
alternative would be storing an infinity — which is not JSON, so it
could never be written back.

```luce run
import std.json

func size(text: string) -> long!:
    let doc = try json.parse(text)
    return doc.count()

func refusal(text: string) -> string:
    var count: long = 0
    count = size(text) catch reason:
        return reason
    return "accepted"

func main():
    print(refusal("[1e308]"))
    print(refusal("[1e999]"))
```

```output
accepted
json: the number at byte 1 is past what a double can hold
```

## Writing

`write` is a **re-encoding of the value**, not an echo of the text it
was parsed from: the value is what survived that parse, and the bytes
are not kept. What it promises instead is the property that matters —
parsing what `write` produced gives an equal value, and writing that
gives identical text.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("[1e3, 42.0, -0, \"\\u0041\", \"a\\/b\"]")
    let once = doc.write()
    print(once)
    let again = try json.parse(once)
    print(string(again.write() == once))
    print(json.quote("say \"hi\""))
    print(json.quote("line\nbreak"))
    print(json.quote("caf" + chr(233)))
```

```output
[1000.0,42.0,0,"A","a/b"]
true
"say \"hi\""
"line\nbreak"
"café"
```

An escape with a shorter spelling gets it, a `\/` loses the solidus
escape it never needed, and a `real` is written with the point that
keeps it a `real` — so `42.0` stays a real across the round trip
rather than coming back an integer. `json.quote` escapes the quote,
the backslash and the control characters, and nothing else: the
solidus may be escaped and need not be, so it is not, and text outside
ASCII goes out as UTF-8, which is what §8.1 asks for.

An object is a `map(string, Json)`, so a **duplicate member name**
resolves to the last one written, in the place the first one claimed —
what JavaScript, Python and Go all do — and both are not kept: a
mapping with two entries under one name is not a mapping.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("{\"a\": 1, \"b\": 2, \"a\": 3}")
    print(string(doc.count()))
    print(doc.write())
```

```output
2
{"a":3,"b":2}
```

## What it refuses

```luce run
import std.json

func size(text: string) -> long!:
    let doc = try json.parse(text)
    return doc.count()

func report(text: string):
    let count = size(text) catch -1
    if count < 0:
        print("refused  " + text)
    else:
        print("accepted " + text)

func main():
    report("{\"a\": 1}")
    report("{\"a\": 1,}")
    report("[.5]")
    report("[01]")
    report("[1, 2")
    report("{} {}")
    report("[\"\\ud834\"]")
    report("['single']")
```

```output
accepted {"a": 1}
refused  {"a": 1,}
refused  [.5]
refused  [01]
refused  [1, 2
refused  {} {}
refused  ["\ud834"]
refused  ['single']
```

Every refusal is an error carrying a byte offset and a sentence —
`json: a number may not have a leading zero, at byte 1`. `parse`
answers `Json!` rather than `Json?` for exactly that reason: there are
many distinct ways for a document to be wrong, and the one it met is
worth carrying.

Three of those rows are choices other parsers make differently:

- **An unpaired surrogate escape is refused** (§8.2 warns about them;
  ECMA-404 permits the code unit). A Luce string is UTF-8 and there is
  no UTF-8 for half a pair, so the alternatives were refusing and
  quietly substituting U+FFFD for what the document said. A
  well-formed pair — `\ud834\udd1e` — is one codepoint, 𝄞, and is
  read as one.
- **Nesting is bounded at 64** (§9 lets a parser set a limit). A tree
  is walked by recursion at both ends: this module's reader and writer
  take one frame a level, and so does every caller that reads what
  they answer. loom lets a program nest 128 calls before it traps
  `call_depth_exceeded`, so the bound is half of that — a document
  this module accepts can be parsed, walked and written from a call
  stack already sixty deep. A 10,000-deep array is an error with a
  name, not a machine falling over.
- **`NaN` and `Infinity` are not JSON.** §6 gives one number grammar
  and there are no names in it, so they are refused like any other
  unknown word — and a `Json.real` built by hand out of one traps on
  the way out, because there is no text that would read back as what
  it was given.

## Reading a file

Three calls, and this module makes none of them.

```text
let bytes = try files.read_bytes(path)
let text = strings.from_bytes(bytes) else ""
let doc = try json.parse(text)
```

The encoding question every other JSON parser has to answer (§8.1) is
already answered by the time `parse` is called: the input is a Luce
string, so it is valid UTF-8 by construction. What is left is the
grammar, and that is all this module checks.
