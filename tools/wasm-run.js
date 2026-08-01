// Run a Luce-compiled .wasm module (codegen_wasm milestone 0) and
// print what it emits — the host side of the two imports.  Used to
// validate the WASM backend against the interpreter.
//   deno run --allow-read tools/wasm-run.js FILE.wasm
const path = Deno.args[0];
const bytes = await Deno.readFile(path);
const out = [];
let trapped = null;
const imports = {
  env: {
    emit_i64: (n) => { out.push(n.toString()); },
    trap: (code) => { trapped = code; throw new Error("luce-trap"); },
  },
};
try {
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  instance.exports.main();
} catch (e) {
  if (e.message !== "luce-trap") throw e;
}
if (trapped !== null) {
  console.log(out.join("\n"));
  console.error("TRAP " + trapped);
  Deno.exit(3);
}
console.log(out.join("\n"));
