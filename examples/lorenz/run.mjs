// Phase 0: load lorenz.wasm in Node and compare against the native ref.json.
// Run with: node examples/lorenz/run.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const bytes = readFileSync(join(here, "lorenz.wasm"));
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

// Oracle: harmonic oscillator vs exact (cos t, -sin t). This decides PASS/FAIL.
const osc = ex.solve_osc(0.01, 10);
const oscW = [ex.vget(osc, 1), ex.vget(osc, 2)];
const oscExact = [Math.cos(10), -Math.sin(10)];
for (let k = 0; k < 2; k++) {
  const d = Math.abs(oscW[k] - oscExact[k]);
  console.log(`osc[${k}]  wasm=${oscW[k]}  exact=${oscExact[k]}  |diff|=${d}`);
  if (!(d <= 1e-8)) ok = false;
}

// Lorenz: length must match; values printed with |diff| for information only
// (chaotic system, ULP-level drift between native and wasm is expected).
const sol = ex.solve_lorenz(10, 28, 8 / 3, 0.01, 20);
const len = ex.vlen(sol);
const last3 = [len - 2, len - 1, len].map((i) => ex.vget(sol, i));
console.log(`length  wasm=${len}  native=${ref.length}`);
if (len !== ref.length) ok = false;
for (let k = 0; k < 3; k++) {
  const d = Math.abs(last3[k] - ref.last3[k]);
  console.log(`last3[${k}]  wasm=${last3[k]}  native=${ref.last3[k]}  |diff|=${d}  (info only)`);
}
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
