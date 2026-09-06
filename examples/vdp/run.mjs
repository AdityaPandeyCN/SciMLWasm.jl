// Rung 1: load vdp.wasm in Node and compare adaptive SimpleATsit5 against ref.json.
// Run with: node examples/vdp/run.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const bytes = readFileSync(join(here, "vdp.wasm"));
const ref = JSON.parse(readFileSync(join(here, "ref.json"), "utf8"));

const module = await WebAssembly.compile(bytes, { builtins: ["js-string"] });

// No-op stubs for every non-builtin import (e.g. the "io" module).
const imports = {};
for (const { module: m, name, kind } of WebAssembly.Module.imports(module)) {
  if (m.startsWith("wasm:")) continue;
  imports[m] ??= {};
  if (kind === "function") imports[m][name] = () => {};
  else console.warn(`unstubbed non-function import ${m}.${name} (${kind})`);
}

const { exports: ex } = await WebAssembly.instantiate(module, imports);

let ok = true;

const sol = ex.solve_vdp(10, 30, 1e-8);
const len = ex.vlen(sol);
const nsteps = len / 3;
const final = [ex.vget(sol, len - 1), ex.vget(sol, len)];

console.log(`nsteps    wasm=${nsteps}  native=${ref.nsteps}`);
if (nsteps !== ref.nsteps) {
  ok = false;
  console.log(`*** STEP COUNT MISMATCH: adaptivity diverged (wasm ${nsteps} vs native ${ref.nsteps}) ***`);
}
const natives = [ref.final_u1, ref.final_u2];
for (let k = 0; k < 2; k++) {
  const d = Math.abs(final[k] - natives[k]);
  console.log(`final_u${k + 1}  wasm=${final[k]}  native=${natives[k]}  |diff|=${d}`);
  if (!(d <= 1e-8)) ok = false;
}

// Dense output: interpolant at t = 17.3 vs native.
const iw = ex.interp_vdp(10, 30, 1e-8, 17.3);
const idiff = Math.abs(iw - ref.interp_u1_at_17p3);
console.log(`interp_u1(17.3)  wasm=${iw}  native=${ref.interp_u1_at_17p3}  |diff|=${idiff}`);
if (!(idiff <= 1e-8)) ok = false;

console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
