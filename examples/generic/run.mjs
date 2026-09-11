// Checks generic.wasm: the wasm bytecode interpreter against the JS reference
// evaluator, then each solver against the hand-compiled examples it must
// reproduce. Run with: node examples/generic/run.mjs   (after compile.jl)
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { instantiate, checker } from "../common/wasm.mjs";
import { parseSystem, evalBytecode, makeSolver } from "./parser.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const readRef = (name) => JSON.parse(readFileSync(join(here, "..", name, "ref.json"), "utf8"));
const vdpRef = readRef("vdp");
const roberRef = readRef("rober");

const ex = await instantiate(readFileSync(join(here, "generic.wasm")));
const solver = makeSolver(ex);
const c = checker();

// interpreter: wasm vs JS on random inputs
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
      if (!(d <= 1e-12)) c.fail(`interp mismatch in "${text}" eq ${k}: wasm=${w} js=${j}`);
    }
  }
}
console.log(`interpreter: worst relative diff wasm vs js = ${worst.toExponential(2)}`);

// SimpleATsit5 on typed Van der Pol must reproduce the compiled ../vdp
const vdp = parseSystem("dx = y\ndy = mu*(1 - x^2)*y - x");
const vs = solver.solve(vdp, [10.0], [2.0, 0.0], 0.0, 30.0, 0.01, { abstol: 1e-8, reltol: 1e-8 });
c.equal("atsit5 rows", vs.nsteps, vdpRef.rows, "interpreted RHS diverged from compiled RHS");
for (let k = 0; k < 2; k++) c.close(`atsit5 u${k + 1}`, vs.u[k][vs.nsteps - 1], vdpRef.final[k]);

// Rosenbrock23 on typed Robertson must reproduce the compiled ../rober
const rober = parseSystem("dy1 = -k1*y1 + k3*y2*y3\ndy2 = k1*y1 - k2*y2^2 - k3*y2*y3\ndy3 = k2*y2^2");
const kv = { k1: 0.04, k2: 3e7, k3: 1e4 };
const rs = solver.solve(rober, rober.params.map((n) => kv[n]), [1.0, 0.0, 0.0], 0.0, 1e5, 1e-6,
                        { abstol: 1e-8, reltol: 1e-6, method: "rb23" });
c.equal("rb23 rows  ", rs.nsteps, roberRef.rows, "bytecode Rosenbrock23 diverged from compiled RHS");
for (let k = 0; k < 3; k++) c.close(`rb23 y${k + 1}`, rs.u[k][rs.nsteps - 1], roberRef.final[k]);

// oracle: harmonic oscillator against its exact solution
const osc = parseSystem("dx = y\ndy = -x");
const os = solver.solve(osc, [], [1.0, 0.0], 0.0, 10.0, 0.01, { abstol: 1e-10, reltol: 1e-10 });
const oe = [Math.cos(10), -Math.sin(10)];
for (let k = 0; k < 2; k++) c.close(`osc[${k}]`, os.u[k][os.nsteps - 1], oe[k], 1e-7);

process.exit(c.finish());
