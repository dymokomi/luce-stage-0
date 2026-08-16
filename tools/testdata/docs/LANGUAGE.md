# A current document with a stale sentence in it

`tools/spelling.zig` reads the prose of a current document as well as
its code, because a reference page that says `func main(args:
List(String))` in a sentence is a lie told with more authority than a
comment.

The line above is the fixture's one violation, and it is in prose
rather than in a fence — which is the whole point of the scope this
file exercises.
