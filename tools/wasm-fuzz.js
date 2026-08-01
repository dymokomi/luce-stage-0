// Generate a random, type-correct scalar-core Luce program from a seed
// — the differential fuzzer's input.  Deterministic per seed so a
// mismatch is reproducible.  Everything it emits stays inside the wasm
// backend's scalar core (Int/Bool/Float, functions, control flow, the
// checked conversions and math intrinsics) and prints Int results, so
// the interpreter and the wasm module have an identical, float-format-
// free observable.
//
//   deno run tools/wasm-fuzz.js SEED > prog.luc
const seed = parseInt(Deno.args[0] ?? "1", 10) >>> 0;
let state = (seed ^ 0x9e3779b9) >>> 0;
function rnd() { // xorshift32
  state ^= state << 13; state >>>= 0;
  state ^= state >>> 17;
  state ^= state << 5; state >>>= 0;
  return state;
}
const pick = (n) => rnd() % n;
const choice = (xs) => xs[pick(xs.length)];

let out = "";
const line = (indent, text) => { out += "    ".repeat(indent) + text + "\n"; };

// A small pool of helper functions taking Int params, returning Int, so
// calls (and occasionally recursion) get exercised.  Bodies are simple
// and depend only on their parameters.
const helpers = [];
const helperCount = 1 + pick(3);
for (let h = 0; h < helperCount; h++) {
  const arity = 1 + pick(2);
  const params = [];
  for (let p = 0; p < arity; p++) params.push("p" + p);
  helpers.push({ name: "helper" + h, params });
}

// -- expression generators, typed --------------------------------------------

function intExpr(depth, ints, loopVars) {
  const atoms = () => {
    const opts = [() => String(pick(20))];
    if (ints.length) opts.push(() => choice(ints));
    if (loopVars.length) opts.push(() => choice(loopVars));
    return choice(opts)();
  };
  if (depth <= 0) return atoms();
  const k = pick(10);
  if (k < 3) return atoms();
  if (k === 3) return "(" + intExpr(depth - 1, ints, loopVars) + " + " + intExpr(depth - 1, ints, loopVars) + ")";
  if (k === 4) return "(" + intExpr(depth - 1, ints, loopVars) + " - " + intExpr(depth - 1, ints, loopVars) + ")";
  if (k === 5) return "(" + intExpr(depth - 1, ints, loopVars) + " * " + String(1 + pick(6)) + ")";
  if (k === 6) return "(" + intExpr(depth - 1, ints, loopVars) + " / " + String(1 + pick(9)) + ")"; // nonzero divisor
  if (k === 7) return "(" + intExpr(depth - 1, ints, loopVars) + " % " + String(1 + pick(9)) + ")";
  if (k === 8) {
    const fn = choice(["min", "max"]);
    return fn + "(" + intExpr(depth - 1, ints, loopVars) + ", " + intExpr(depth - 1, ints, loopVars) + ")";
  }
  // a call or a clamp or an Int(float)
  const kind = pick(3);
  if (kind === 0) {
    const fn = choice(helpers);
    const args = fn.params.map(() => intExpr(depth - 1, ints, loopVars));
    return fn.name + "(" + args.join(", ") + ")";
  }
  if (kind === 1) {
    return "clamp(" + intExpr(depth - 1, ints, loopVars) + ", 0, " + String(5 + pick(40)) + ")";
  }
  return "Int(" + floatExpr(depth - 1, ints, loopVars) + ")";
}

function floatExpr(depth, ints, loopVars) {
  const atom = () => {
    const opts = [() => (pick(100) / 10).toFixed(1)];
    if (ints.length) opts.push(() => "Float(" + choice(ints) + ")");
    return choice(opts)();
  };
  if (depth <= 0) return atom();
  const k = pick(8);
  if (k < 2) return atom();
  if (k === 2) return "(" + floatExpr(depth - 1, ints, loopVars) + " + " + floatExpr(depth - 1, ints, loopVars) + ")";
  if (k === 3) return "(" + floatExpr(depth - 1, ints, loopVars) + " - " + floatExpr(depth - 1, ints, loopVars) + ")";
  if (k === 4) return "(" + floatExpr(depth - 1, ints, loopVars) + " * " + (1 + pick(30) / 10).toFixed(1) + ")";
  if (k === 5) return "(" + floatExpr(depth - 1, ints, loopVars) + " / " + (1 + pick(30) / 10).toFixed(1) + ")"; // nonzero
  if (k === 6) return "sqrt(abs(" + floatExpr(depth - 1, ints, loopVars) + "))";
  return choice(["floor", "ceil", "abs"]) + "(" + floatExpr(depth - 1, ints, loopVars) + ")";
}

// -- statement generation ----------------------------------------------------

function block(indent, ints, loopVars, budget) {
  let stmts = 1 + pick(3);
  let emitted = 0;
  for (let s = 0; s < stmts && budget.n > 0; s++) {
    budget.n--;
    const k = pick(10);
    if (k < 4 && ints.length) {
      line(indent, choice(ints) + " = " + intExpr(2, ints, loopVars));
      emitted++;
    } else if (k < 6 && budget.n > 2) {
      const v = "i" + budget.n;
      const lo = pick(4), hi = lo + 1 + pick(5);
      line(indent, "for " + v + " in range(" + lo + ", " + hi + "):");
      const inner = block(indent + 1, ints, loopVars.concat([v]), budget);
      if (!inner) line(indent + 1, "print(str(0))");
      emitted++;
    } else if (k < 8 && ints.length) {
      line(indent, "if " + intExpr(1, ints, loopVars) + " % 2 == 0:");
      if (!block(indent + 1, ints, loopVars, budget)) line(indent + 1, "print(str(1))");
      line(indent, "else:");
      if (!block(indent + 1, ints, loopVars, budget)) line(indent + 1, "print(str(2))");
      emitted++;
    } else {
      line(indent, "print(str(" + intExpr(2, ints, loopVars) + "))");
      emitted++;
    }
  }
  return emitted;
}

// -- emit --------------------------------------------------------------------

for (const fn of helpers) {
  out += "func " + fn.name + "(" + fn.params.map((p) => p + ": Int").join(", ") + ") -> Int:\n";
  // A simple body over the parameters, sometimes self-recursive with a
  // guard so it terminates.
  if (pick(3) === 0 && fn.params.length >= 1) {
    line(1, "if " + fn.params[0] + " <= 0:");
    line(2, "return 0");
    line(1, "return " + fn.params[0] + " % 7 + " + fn.name + "(" + fn.params[0] + " - 1" +
      fn.params.slice(1).map(() => ", 0").join("") + ")");
  } else {
    line(1, "return " + intExpr(2, fn.params, []));
  }
  out += "\n";
}

out += "func main():\n";
const ints = [];
const intCount = 2 + pick(3);
for (let v = 0; v < intCount; v++) {
  const name = "a" + v;
  line(1, "var " + name + " = " + pick(20));
  ints.push(name);
}
block(1, ints, [], { n: 20 });
for (const v of ints) line(1, "print(str(" + v + "))");

Deno.stdout.writeSync(new TextEncoder().encode(out));
