// Node check for generic.wasm: the wasm interpreter against the JS evaluator,
// the generic Van der Pol solve against ../vdp/ref.json, and a harmonic
// oscillator against the exact solution.
// Run with: node examples/generic/run.mjs   (after compile.jl)
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseSystem, evalBytecode, makeSolver } from "./parser.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const bytes = readFileSync(join(here, "generic.wasm"));
const vdpRef = JSON.parse(readFileSync(join(here, "..", "vdp", "ref.json"), "utf8"));

const module = await WebAssembly.compile(bytes, { builtins: ["js-string"] });
const imports = {};
for (const { module: m, name, kind } of WebAssembly.Module.imports(module)) {
  if (m.startsWith("wasm:")) continue;
  imports[m] ??= {};
  if (kind === "function") imports[m][name] = () => {};
  else console.warn(`unstubbed non-function import ${m}.${name} (${kind})`);
}
const { exports: ex } = await WebAssembly.instantiate(module, imports);
const solver = makeSolver(ex);

let ok = true;

// interpreter: wasm vs JS
const exprs = [
  "dx = y\ndy = mu*(1 - x^2)*y - x",
  "dx = s*(y - x); dy = x*(r - z) - y; dz = x*y - b*z",
  "dx = sin(t)*x + cos(w*t) - exp(-k*t) + log(1 + x^2) + sqrt(abs(x))",
  "dx = min(x, 1) + max(x, -1) + tanh(x) + atan(x) + sinh(x) - cosh(x) + tan(x/4)",
  "dx = x^0.5 + x^-1 + x^3 - 2^3^2",
];
let seed = 7;
const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff) * 4 - 2;
let worst = 0;
for (const text of exprs) {
  const prog = parseSystem(text);
  for (let trial = 0; trial < 20; trial++) {
    const u = prog.states.map(() => Math.abs(rnd()) + 0.1);
    const p = prog.params.map(() => rnd() || 0.7);
    const t = Math.abs(rnd());
    for (let k = 1; k <= prog.states.length; k++) {
      const w = solver.evalExpr(prog, k, u, p, t);
      const j = evalBytecode(prog, k, u, p, t);
      const d = Math.abs(w - j) / Math.max(1, Math.abs(j));
      worst = Math.max(worst, d);
      if (!(d <= 1e-12)) {
        ok = false;
        console.log(`interp mismatch in "${text}" eq ${k}: wasm=${w} js=${j}`);
      }
    }
  }
}
console.log(`interpreter: worst relative diff wasm vs js = ${worst.toExponential(2)}`);

// generic Van der Pol vs hand-compiled reference
const vdp = parseSystem("dx = y\ndy = mu*(1 - x^2)*y - x");
const sol = solver.solve(vdp, [10.0], [2.0, 0.0], 0.0, 30.0, 0.01, 1e-8);
const last = sol.nsteps - 1;
console.log(`nsteps    generic=${sol.nsteps}  ref=${vdpRef.nsteps}`);
if (sol.nsteps !== vdpRef.nsteps) {
  ok = false;
  console.log(`*** STEP COUNT MISMATCH: interpreted RHS diverged from compiled RHS ***`);
}
for (const [k, key] of [[0, "final_u1"], [1, "final_u2"]]) {
  const d = Math.abs(sol.u[k][last] - vdpRef[key]);
  console.log(`${key}  generic=${sol.u[k][last]}  ref=${vdpRef[key]}  |diff|=${d}`);
  if (!(d <= 1e-8)) ok = false;
}

// harmonic oscillator vs exact
const osc = parseSystem("dx = y\ndy = -x");
const os = solver.solve(osc, [], [1.0, 0.0], 0.0, 10.0, 0.01, 1e-10);
const oe = [Math.cos(10), -Math.sin(10)];
for (let k = 0; k < 2; k++) {
  const d = Math.abs(os.u[k][os.nsteps - 1] - oe[k]);
  console.log(`osc[${k}]  wasm=${os.u[k][os.nsteps - 1]}  exact=${oe[k]}  |diff|=${d}`);
  if (!(d <= 1e-7)) ok = false;
}

console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
