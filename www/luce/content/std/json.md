# std.json

JSON, in pure Luce. Parse a document, walk it, read the leaves, and
print it back out. Nothing here is a builtin, nothing here imports
anything — not even `std.strings` — and nothing here touches the host:
`parse` takes a string and answers a document, and where the string
came from is the caller's business.

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

## Reading a document

| Signature | Notes |
|---|---|
| `json.parse(content: string) -> Document!` | the whole grammar, or an error naming the byte and the problem |
| `json.quote(content: string) -> string` | text as a JSON string literal, the escaping done right |

```luce run
import std.json

func child(doc: json.Document, node: json.Node, name: string) -> json.Node:
    let found = doc.get(node, name)
    if found != none:
        return found
    trap("no member named " + name)

func main() -> !:
    let doc = try json.parse("{\"host\": \"localhost\", \"port\": 8080, \"debug\": false}")
    let root = doc.root()
    print(child(doc, root, "host").as_text() else "?")
    print(string(child(doc, root, "port").as_long() else 0))
    print(string(child(doc, root, "debug").as_bool() else true))
```

```output
localhost
8080
false
```

Reaching a member is two steps, because `get` answers `Node?` and a
method needs a `Node`. That `child` is a *function* is the whole point
of the design below: a node returns from one.

## The document, and the nodes in it

`Document` owns the parse. Every navigating call is a method on it,
and takes the node to navigate from.

| Signature | Notes |
|---|---|
| `doc.root() -> Node` | the one top-level value |
| `doc.get(node: Node, name: string) -> Node?` | an object's member by name, or absent — for a name that is not there and for a value that is not an object |
| `doc.at(node: Node, index: long) -> Node` | an element by position; past the end traps, because `count()` is right there |
| `doc.items(node: Node) -> list(Node)` | every member or element, in order; a fresh list the caller owns |
| `doc.keys(node: Node) -> list(string)` | every member name, decoded, in order |
| `doc.write(node: Node) -> string` | the value as JSON with nothing between the tokens |
| `doc.pretty(node: Node, spaces: long) -> string` | the same, indented |

A `Node` is one value in that document. It answers what it is and what
it was written as, and unpacks itself when asked.

| Signature | Notes |
|---|---|
| `node.kind() -> Kind` | `object`, `array`, `text`, `number`, `boolean` or `null` |
| `node.count() -> long` | members or elements; 0 for every leaf |
| `node.key() -> string` | its member name, decoded; `""` when it is not a member |
| `node.raw() -> string` | its text exactly as written; `""` for a container |
| `node.is_null() -> bool` | true for JSON's `null`, which is a value that is *there* |
| `node.as_bool() -> bool?` | absent for every other kind |
| `node.as_long() -> long?` | absent for every other kind, for a number written with a fraction or an exponent, and for one too large to hold |
| `node.as_double() -> double?` | absent for every other kind and for a magnitude past a double |
| `node.as_text() -> string?` | the escapes decoded (§7); absent for every other kind |

`Kind` is an enum, so a `match` over it needs no `else` — and the day
a seventh kind of JSON value is invented, every one of these stops
compiling until it says what to do.

```luce run
import std.json

func describe(node: json.Node) -> string:
    match node.kind():
        object:
            return "object of " + string(node.count())
        array:
            return "array of " + string(node.count())
        text:
            return "text " + (node.as_text() else "")
        number:
            return "number " + node.raw()
        boolean:
            return "boolean " + string(node.as_bool() else false)
        null:
            return "null"

func main() -> !:
    let doc = try json.parse("[1, \"two\", true, null, [3], {\"a\": 4}]")
    for item in doc.items(doc.root()):
        print(describe(item))
```

```output
number 1
text two
boolean true
null
array of 1
object of 1
```

There is no `has`. It is a reserved name in Luce — it is `m.has(k)`,
the map method — so `doc.get(node, name) != none` is the membership
question, and it is the same one call.

## Lazy, in simdjson's sense

A parse walks the text once, checks that every byte of it is
grammatical, and records where each value begins and ends. It does not
turn `1e3` into a double or a `\ud834\udd1e` into 𝄞 until somebody
asks. A document read for one field pays for one field, and `raw()` is
always exactly what the author wrote — which is also why `write` can
put the same bytes back.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("{\"ratio\": 1.500, \"huge\": 1e999, \"count\": 42}")
    let root = doc.root()
    let ratio = doc.at(root, 0)
    print(ratio.key() + " was written " + ratio.raw())
    print(string(ratio.as_double() else 0.0))
    print(string(ratio.as_long() == none))
    print(string(doc.at(root, 1).as_double() == none))
    print(string(doc.at(root, 2).as_long() else 0))
```

```output
ratio was written 1.500
1.5
true
true
42
```

Two of those answers are decisions worth reading twice. **`as_long`
reads the notation, not the value**: `42` is a whole number and
`42.0`, `4.2` and `4.2e1` are not, so they answer absence and are read
with `as_double`. Truncating would drop information without saying so.
And **a number too big for the machine parses and then reads as
absent**: `1e999` is grammatical — RFC 8259 §6 sets no bound and says
so — but no double holds it, and absence is the same answer
`parse_float` gives.

## A document is flat, and a node points into it

`Document` owns one `list(Node)` holding every value in document
order. A `Node` is a plain value — a kind, two spans of text, three
numbers — so it copies for nothing, returns from any function, and
needs no ownership verb anywhere. Each node records the index one past
its own subtree, which is simdjson's tape: a container's first child
is the node after it, and any value's next sibling is that index.

That is why navigation is a method on the *document*: a node on its
own does not know where the rest of the document lives.

The shape is what the language allows rather than a preference. A
nested tree — a `Node` holding `list(Node)` children — cannot answer
`get(name) -> Node?` at all, because returning an object-carrying
struct read out of a container is refused
([S17](/ref/ownership/#s17), [S22](/ref/ownership/#s22)), and
returning a `copy` of one would deep-copy the whole subtree on every
field access. Flat costs one heap object for a document of any size,
and the reading path allocates only what it hands back.

**Ownership**: the binding that receives the document owns it, and the
end of that scope frees it — one list, however large the document. A
node owns nothing at all. A node belongs to the document it came from;
handing one to a *different* document reads whatever that document
holds at the same index, so keep the pair together the way you would a
slice and the thing it slices.

## Writing

`write` is not a byte-for-byte echo: the whitespace a document arrived
with is not kept. Every *token* is the one that was read, though —
escapes and number notation and all — so `parse → write → parse →
write` is a fixed point, and a document that arrived minified comes
back identical.

```luce run
import std.json

func main() -> !:
    let doc = try json.parse("{ \"a\" : [1, 2] , \"b\" : {} }")
    print(doc.write(doc.root()))
    print(doc.pretty(doc.root(), 2))
    print(json.quote("say \"hi\""))
    print(json.quote("line\nbreak"))
    print(json.quote("caf" + chr(233)))
    let dup = try json.parse("{\"a\": 1, \"a\": 2}")
    let found = dup.get(dup.root(), "a")
    if found != none:
        print(string(found.as_long() else 0))
    print(string(dup.root().count()))
    print(dup.write(dup.root()))
```

```output
{"a":[1,2],"b":{}}
{
  "a": [
    1,
    2
  ],
  "b": {}
}
"say \"hi\""
"line\nbreak"
"café"
2
2
{"a":1,"a":2}
```

The last three lines are the **duplicate name** decision. RFC 8259 §4
says names SHOULD be unique and that the behaviour when they are not
is unpredictable; every mainstream parser keeps the last one, and so
does `get`. The document is not edited to match — `count`, `items` and
`keys` still show every member as written, because a reader who wants
to know that a document repeats itself should be able to find out.

`json.quote` escapes the quote, the backslash and the control
characters, and nothing else: the solidus may be escaped and need not
be, so it is not, and text outside ASCII goes out as UTF-8, which is
what §8.1 asks for. It is the door for a program that builds JSON of
its own out of a builder rather than parsing any.

## What it refuses

```luce run
import std.json

func size(text: string) -> long!:
    let doc = try json.parse(text)
    return doc.root().count()

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
answers `Document!` rather than `Document?` for exactly that reason:
there are many distinct ways for a document to be wrong, and the one
it met is worth carrying.

Three of those rows are choices other parsers make differently:

- **An unpaired surrogate escape is refused** (§8.2 warns about them;
  ECMA-404 permits the code unit). A Luce string is UTF-8 and there is
  no UTF-8 for half a pair, so the alternatives were refusing and
  quietly substituting U+FFFD for what the document said. A
  well-formed pair — `\ud834\udd1e` — is one codepoint, 𝄞, and is
  read as one.
- **Nesting is bounded at 128** (§9 lets a parser set a limit). The
  parse is iterative and would not care, but a document is *walked* by
  callers, and loom lets a Luce program nest 128 calls before it traps
  `call_depth_exceeded` — so accepting a deeper document would hand a
  caller a tree no recursive function of theirs could walk. serde_json
  arrived at the same number from the other direction. A 10,000-deep
  array is an error with a name, not a machine falling over.
- **`NaN` and `Infinity` are not JSON.** §6 gives one number grammar
  and there are no names in it, so they are refused like any other
  unknown word.

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
