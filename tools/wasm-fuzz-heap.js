// Generate a random, type-correct Luce program exercising the object
// heap phase B1 — Lists of Int/String and Builders, with the ownership
// that comes from creating, returning, borrowing, and reassigning them.
// Deterministic per seed; everything stays in the wasm backend's B1
// scope, and prints Ints and Strings, so the interpreter and the wasm
// module share an exact observable.  Traps (out-of-range index, empty
// pop) are expected and must agree.
//
//   deno run tools/wasm-fuzz-heap.js SEED > prog.luc
const seed = parseInt(Deno.args[0] ?? "1", 10) >>> 0;
let state = (seed ^ 0xc2b2ae35) >>> 0;
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

function strLit() {
  const alphabet = "abcXYZ 12.";
  let n = pick(5);
  let s = "";
  for (let i = 0; i < n; i++) s += alphabet[pick(alphabet.length)];
  return '"' + s + '"';
}

function intExpr(depth, ctx) {
  const opts = [() => String(pick(20))];
  if (ctx.ints.length) opts.push(() => choice(ctx.ints));
  if (ctx.loop.length) opts.push(() => choice(ctx.loop));
  if (ctx.ilists.length) opts.push(() => "len(" + choice(ctx.ilists) + ")");
  if (depth > 0 && ctx.ilists.length) {
    opts.push(() => choice(ctx.ilists) + "[" + String(pick(4)) + "]"); // may OOB (agrees)
    opts.push(() => choice(ctx.ilists) + ".find(" + intExpr(depth - 1, ctx) + ")");
  }
  if (depth > 0) {
    opts.push(() => "(" + intExpr(depth - 1, ctx) + " + " + intExpr(depth - 1, ctx) + ")");
    opts.push(() => "(" + intExpr(depth - 1, ctx) + " * " + String(1 + pick(4)) + ")");
  }
  return choice(opts)();
}

function strExpr(depth, ctx) {
  const opts = [strLit];
  if (ctx.strs.length) opts.push(() => choice(ctx.strs));
  if (depth > 0) {
    opts.push(() => "str(" + intExpr(depth - 1, ctx) + ")");
    opts.push(() => "(" + strExpr(depth - 1, ctx) + " + " + strExpr(depth - 1, ctx) + ")");
  }
  if (ctx.slists.length && depth > 0) {
    opts.push(() => choice(ctx.slists) + "[" + String(pick(4)) + "]"); // may OOB
  }
  return choice(opts)();
}

// `in_loop` forbids structural list mutation (append/insert/remove/
// sort/clear): mutating a list while any loop iterates it — or even a
// bounded loop growing one without end — is a genuine infinite loop
// both engines share, which would hang the harness rather than test it.
function stmt(indent, ctx, budget, in_loop) {
  budget.n--;
  const k = pick(16);
  if (!in_loop && k < 3 && ctx.ilists.length) {
    line(indent, choice(ctx.ilists) + ".append(" + intExpr(1, ctx) + ")");
  } else if (!in_loop && k < 5 && ctx.slists.length) {
    line(indent, choice(ctx.slists) + ".append(" + strExpr(1, ctx) + ")");
  } else if (!in_loop && k < 6 && ctx.builders.length) {
    line(indent, choice(ctx.builders) + ".append_ascii(" + String(65 + pick(26)) + ")");
  } else if (!in_loop && k < 7 && ctx.ilists.length) {
    line(indent, choice(ctx.ilists) + ".sort()");
  } else if (!in_loop && k < 8 && ctx.ilists.length) {
    line(indent, choice(ctx.ilists) + ".reverse()");
  } else if (!in_loop && k < 9 && ctx.ilists.length) {
    line(indent, "if len(" + choice(ctx.ilists) + ") > 0:");
    line(indent + 1, choice(ctx.ilists) + ".remove(0)");
  } else if (k < 10 && ctx.muts.length) {
    line(indent, choice(ctx.muts) + " = " + intExpr(2, ctx));
  } else if (k < 12 && budget.n > 2 && ctx.ilists.length) {
    const v = "iw" + budget.n;
    line(indent, "for " + v + " in " + choice(ctx.ilists) + ":");
    stmt(indent + 1, { ...ctx, loop: ctx.loop.concat([v]) }, budget, true);
  } else if (k < 13 && budget.n > 2) {
    const v = "iv" + budget.n;
    line(indent, "for " + v + " in range(0, " + (1 + pick(4)) + "):");
    stmt(indent + 1, { ...ctx, loop: ctx.loop.concat([v]) }, budget, true);
  } else if (k < 14 && ctx.slists.length) {
    line(indent, "for w" + budget.n + " in " + choice(ctx.slists) + ":");
    line(indent + 1, "print(w" + budget.n + ")");
  } else if (k < 15) {
    line(indent, "print(str(" + intExpr(2, ctx) + "))");
  } else {
    line(indent, "print(" + strExpr(2, ctx) + ")");
  }
}

// A helper that builds and returns a List(Int) — exercises return-move.
out += "func build(n: Int) -> List(Int):\n";
line(1, "var r = new List(Int)");
line(1, "var i = 0");
line(1, "while i < n:");
line(2, "r.append(i * i)");
line(2, "i = i + 1");
line(1, "return r");
out += "\n";
// A helper that borrows a List(Int).
out += "func total(xs: List(Int)) -> Int:\n";
line(1, "var t = 0");
line(1, "for x in xs:");
line(2, "t = t + x");
line(1, "return t");
out += "\n";

out += "func main():\n";
const ctx = { ints: [], muts: [], strs: [], loop: [], ilists: [], slists: [], builders: [] };
for (let v = 0; v < 2 + pick(2); v++) {
  const name = "il" + v;
  line(1, "var " + name + " = build(" + pick(6) + ")"); // owns a returned list
  ctx.ilists.push(name);
}
for (let v = 0; v < 1 + pick(2); v++) {
  const name = "sl" + v;
  line(1, "var " + name + " = new List(String)");
  ctx.slists.push(name);
}
for (let v = 0; v < 1 + pick(2); v++) {
  const name = "bd" + v;
  line(1, "var " + name + " = new Builder()");
  ctx.builders.push(name);
}
for (let v = 0; v < 2; v++) {
  const name = "a" + v;
  line(1, "var " + name + " = " + pick(20));
  ctx.ints.push(name);
  ctx.muts.push(name);
}
const budget = { n: 24 };
while (budget.n > 0) stmt(1, ctx, budget, false);
for (const l of ctx.ilists) line(1, "print(str(total(" + l + ")))");
for (const l of ctx.ilists) line(1, "print(str(len(" + l + ")))");
for (const b of ctx.builders) line(1, "print(str(" + b + "))");

Deno.stdout.writeSync(new TextEncoder().encode(out));
