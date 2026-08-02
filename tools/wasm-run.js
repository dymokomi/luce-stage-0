// Run a Luce-compiled .wasm module (codegen_wasm) — the host side of
// the import boundary.  Text leaves through emit_str(ptr, len), read
// straight from exported memory; trap(code) records a Luce trap code.
// Program arguments follow the module path; strings entering the module
// use the two-call protocol (the module asks for a length, allocates,
// and the host copies bytes in).
//   deno run --allow-read --allow-write tools/wasm-run.js FILE.wasm [args...]
const path = Deno.args[0];
const args = Deno.args.slice(1);
const bytes = await Deno.readFile(path);
const decoder = new TextDecoder();
const encoder = new TextEncoder();
const out = [];
let trapped = null;
let mem = null;

const readString = (ptr, len) => decoder.decode(new Uint8Array(mem.buffer, ptr, len));
const writeBytes = (dest, data) => new Uint8Array(mem.buffer, dest, data.length).set(data);

// file_len caches the read so file_copy hands over exactly those bytes.
const file_cache = new Map();

const imports = {
  env: {
    emit_str: (ptr, len) => { out.push(readString(ptr, len)); },
    trap: (code) => { trapped = code; throw new Error("luce-trap"); },
    arg_count: () => BigInt(args.length),
    arg_len: (index) => {
      const i = Number(index);
      return i < args.length ? BigInt(encoder.encode(args[i]).length) : -1n;
    },
    arg_copy: (index, dest) => { writeBytes(dest, encoder.encode(args[Number(index)])); },
    file_len: (ptr, len) => {
      const name = readString(ptr, len);
      try {
        const data = Deno.readFileSync(name);
        file_cache.set(name, data);
        return BigInt(data.length);
      } catch {
        return -1n;
      }
    },
    file_copy: (ptr, len, dest) => { writeBytes(dest, file_cache.get(readString(ptr, len))); },
    file_write: (ptr, len, data_ptr, data_len) => {
      try {
        Deno.writeFileSync(readString(ptr, len), new Uint8Array(mem.buffer, data_ptr, data_len).slice());
        return 1;
      } catch {
        return 0;
      }
    },
    file_exists: (ptr, len) => {
      try {
        Deno.statSync(readString(ptr, len));
        return 1;
      } catch {
        return 0;
      }
    },
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
