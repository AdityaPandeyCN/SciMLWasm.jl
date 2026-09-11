// Checks rober.wasm against ref.json: same accepted-step count and same final
// state as the native Rosenbrock23 solve, with mass conservation reported.
// Run with: node examples/rober/run.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { instantiate, readFlat, checker } from "../common/wasm.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const ref = JSON.parse(readFileSync(join(here, "ref.json"), "utf8"));
const ex = await instantiate(readFileSync(join(here, "rober.wasm")));
const c = checker();

const t0 = performance.now();
const sol = ex.solve_rober(0.04, 3e7, 1e4, 1e5, 1e-6, 1e-8);
console.log(`solve_rober(0.04, 3e7, 1e4, 1e5, 1e-6, 1e-8) in ${(performance.now() - t0).toFixed(1)} ms`);

const { u, rows } = readFlat(ex, sol, 3);
c.equal("rows", rows, ref.rows, "STEP COUNT MISMATCH: adaptivity diverged");
const final = [0, 1, 2].map((k) => u[k][rows - 1]);
for (let k = 0; k < 3; k++) c.close(`y${k + 1}`, final[k], ref.final[k]);
console.log(`mass  ${final[0] + final[1] + final[2]}`);

process.exit(c.finish());
