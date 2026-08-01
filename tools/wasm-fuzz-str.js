// Generate a random, type-correct Luce program exercising the string
// runtime — the string differential fuzzer's input.  Deterministic per
// seed.  Everything it emits stays inside the wasm backend's current
// scope (scalars + strings; no heap), and prints strings and Ints, so
// the interpreter and the wasm module share an exact observable (no
// str(Float), which is deferred).  Traps (out-of-range slices, bad
// codepoints, unparseable ints) are expected and must agree.
//
//   deno run tools/wasm-fuzz-str.js SEED > prog.luc
const seed = parseInt(Deno.args[0] ?? "1", 10) >>> 0;
let state = (seed ^ 0x85ebca6b) >>> 0;
function rnd() {
  state ^= state << 13; state >>>= 0;
  state ^= state >>> 17;
  state ^= state << 5; state >>>= 0;
  return state;
}
const pick = (n) => rnd() % n;
const choice = (xs) => xs[pick(xs.length)];

let out = "";
const line = (indent, text) => { out += "    ".repeat(indent) + text + "\n"; };

// A short ASCII string literal (letters, digits, a little punctuation) —
// no backslashes or quotes, so it needs no escaping and every index is a
// UTF-8 boundary.
function literal() {
  const alphabet = "abcXYZ0123 _.,";
  let n = pick(6);
  let s = "";
  for (let i = 0; i < n; i++) s += alphabet[pick(alphabet.length)];
  return '"' + s + '"';
}

// A helper turning an Int into a String, for calls across functions.
const helper = "tag";

function intExpr(depth, ints, strs) {
  const atoms = () => {
    const opts = [() => String(pick(30)), () => "len(" + strExpr(0, ints, strs) + ")"];
    if (ints.length) opts.push(() => choice(ints));
    return choice(opts)();
  };
  if (depth <= 0) return atoms();
  const k = pick(12);
  if (k < 3) return atoms();
  if (k === 3) return "(" + intExpr(depth - 1, ints, strs) + " + " + intExpr(depth - 1, ints, strs) + ")";
  if (k === 4) return "(" + intExpr(depth - 1, ints, strs) + " - " + intExpr(depth - 1, ints, strs) + ")";
  if (k === 5) return "(" + intExpr(depth - 1, ints, strs) + " * " + String(1 + pick(4)) + ")";
  if (k === 6) return "(" + intExpr(depth - 1, ints, strs) + " % " + String(1 + pick(9)) + ")";
  if (k === 7) { // byte_at with an index that may or may not be in range
    const s = strExpr(0, ints, strs);
    return "(" + s + ").byte_at(" + intExpr(depth - 1, ints, strs) + ")";
  }
  if (k === 8) return "(" + s2(strs) + ").find_byte(" + String(97 + pick(26)) + ", 0)";
  if (k === 9) return "ord(" + strExpr(depth - 1, ints, strs) + ")"; // may trap on empty/bad
  if (k === 10) return "parse_int(" + strExpr(depth - 1, ints, strs) + ")"; // may trap
  // comparison as 0/1 via an if is awkward; fold into a boolean-to-int
  return "len(" + strExpr(depth - 1, ints, strs) + ")";
}

function s2(strs) {
  return strs.length ? choice(strs) : literal();
}

function strExpr(depth, ints, strs) {
  const atom = () => {
    const opts = [literal];
    if (strs.length) opts.push(() => choice(strs));
    return choice(opts)();
  };
  if (depth <= 0) return atom();
  const k = pick(10);
  if (k < 3) return atom();
  if (k === 3) return "(" + strExpr(depth - 1, ints, strs) + " + " + strExpr(depth - 1, ints, strs) + ")";
  if (k === 4) return "str(" + intExpr(depth - 1, ints, strs) + ")";
  if (k === 5) return "str(" + boolExpr(depth - 1, ints, strs) + ")";
  if (k === 6) return "chr(" + choice(["65", "233", "128512", String(pick(200))]) + ")";
  if (k === 7) { // slice; bounds may or may not hold (both engines agree)
    const s = s2(strs);
    const lo = pick(4);
    return "(" + s + ")[" + lo + ":" + (lo + pick(5)) + "]";
  }
  return helper + "(" + intExpr(depth - 1, ints, strs) + ")";
}

function boolExpr(depth, ints, strs) {
  const k = pick(3);
  const op = choice(["==", "!=", "<", "<=", ">", ">="]);
  if (k === 0) return "(" + strExpr(0, ints, strs) + " " + op + " " + strExpr(0, ints, strs) + ")";
  return "(" + intExpr(0, ints, strs) + " " + op + " " + intExpr(0, ints, strs) + ")";
}

// `ints` are readable (loop variables included); `muts` are the subset
// that may be reassigned (loop variables are let-bound, so never here).
function block(indent, ints, muts, strs, budget) {
  let stmts = 1 + pick(3);
  let emitted = 0;
  for (let s = 0; s < stmts && budget.n > 0; s++) {
    budget.n--;
    const k = pick(12);
    if (k < 3 && strs.length) {
      line(indent, choice(strs) + " = " + strExpr(2, ints, strs));
    } else if (k < 5 && muts.length) {
      line(indent, choice(muts) + " = " + intExpr(2, ints, strs));
    } else if (k < 7 && budget.n > 2) {
      const v = "iv" + budget.n;
      const lo = pick(3), hi = lo + 1 + pick(4);
      line(indent, "for " + v + " in range(" + lo + ", " + hi + "):");
      block(indent + 1, ints.concat([v]), muts, strs, budget);
    } else if (k < 9) {
      line(indent, "if " + boolExpr(1, ints, strs) + ":");
      block(indent + 1, ints, muts, strs, budget);
      line(indent, "else:");
      block(indent + 1, ints, muts, strs, budget);
    } else if (k < 11) {
      line(indent, "print(" + strExpr(2, ints, strs) + ")");
    } else {
      line(indent, "print(str(" + intExpr(2, ints, strs) + "))");
    }
    emitted++;
  }
  // Luce forbids an empty suite: always leave at least one statement.
  if (emitted === 0) line(indent, "print(str(0))");
}

// A helper that maps Int -> String, sometimes recursive with a guard.
out += "func " + helper + "(n: Int) -> String:\n";
line(1, "if n <= 0:");
line(2, 'return "z"');
line(1, 'return "n" + str(n % 100) + ' + helper + "(n - 7)");
out += "\n";

out += "func main():\n";
const strs = [];
const ints = [];
for (let v = 0; v < 2 + pick(2); v++) {
  const name = "sv" + v;
  line(1, "var " + name + " = " + literal());
  strs.push(name);
}
for (let v = 0; v < 2 + pick(2); v++) {
  const name = "av" + v;
  line(1, "var " + name + " = " + pick(30));
  ints.push(name);
}
block(1, ints, ints.slice(), strs, { n: 22 });
for (const v of strs) line(1, "print(" + v + ")");
for (const v of ints) line(1, "print(str(" + v + "))");

Deno.stdout.writeSync(new TextEncoder().encode(out));
