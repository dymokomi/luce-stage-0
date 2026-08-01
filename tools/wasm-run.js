// Run a Luce-compiled .wasm module (codegen_wasm) and print what it
// emits — the host side of the two imports.  Text leaves the module
// through emit_str(ptr, len), read straight from the instance's
// exported linear memory.  Used to validate the WASM backend against
// the interpreter.
//   deno run --allow-read tools/wasm-run.js FILE.wasm
const path = Deno.args[0];
const bytes = await Deno.readFile(path);
const decoder = new TextDecoder();
const out = [];
let trapped = null;
let mem = null;

const imports = {
  env: {
    emit_str: (ptr, len) => {
      const view = new Uint8Array(mem.buffer, ptr, len);
      out.push(decoder.decode(view));
    },
    trap: (code) => { trapped = code; throw new Error("luce-trap"); },
  },
};

try {
  const { instance } = await WebAssembly.instantiate(bytes, imports);
  mem = instance.exports.memory;
  instance.exports.main();
} catch (e) {
  if (e.message !== "luce-trap") throw e;
}

// print() in Luce writes whole lines; emit_str carries the text of each
// print, so join with newlines to reproduce the interpreter's stdout.
if (out.length) console.log(out.join("\n"));
if (trapped !== null) {
  console.error("TRAP " + trapped);
  Deno.exit(3);
}
