// Checks lorenz.wasm against ref.json. The harmonic oscillator decides
// PASS/FAIL against its exact solution; Lorenz is chaotic, so only its row
// count is asserted and its values are printed for information.
// Run with: node examples/lorenz/run.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { instantiate, readFlat, checker } from "../common/wasm.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const ref = JSON.parse(readFileSync(join(here, "ref.json"), "utf8"));
const ex = await instantiate(readFileSync(join(here, "lorenz.wasm")));
const c = checker();

const osc = ex.solve_osc(0.01, 10);
const exact = [Math.cos(10), -Math.sin(10)];
for (let k = 0; k < 2; k++) c.close(`osc[${k}]`, ex.vget(osc, k + 1), exact[k]);

const sol = ex.solve_lorenz(10, 28, 8 / 3, 0.01, 20);
const { u, rows } = readFlat(ex, sol, 3, { tcol: false, dt: 0.01 });
c.equal("rows  ", rows, ref.rows, "STEP COUNT MISMATCH");
for (let k = 0; k < 3; k++) c.close(`final[${k}]`, u[k][rows - 1], ref.final[k], null);

process.exit(c.finish());
