// Checks vdp.wasm against ref.json: same accepted-step count, same final
// state and same interpolated value as the native solve.
// Run with: node examples/vdp/run.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { instantiate, readFlat, checker } from "../common/wasm.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const ref = JSON.parse(readFileSync(join(here, "ref.json"), "utf8"));
const ex = await instantiate(readFileSync(join(here, "vdp.wasm")));
const c = checker();

const { u, rows } = readFlat(ex, ex.solve_vdp(10, 30, 1e-8), 2);
c.equal("rows    ", rows, ref.rows, "STEP COUNT MISMATCH: adaptivity diverged");
for (let k = 0; k < 2; k++) c.close(`final_u${k + 1}`, u[k][rows - 1], ref.final[k]);
c.close("interp_u1(17.3)", ex.interp_vdp(10, 30, 1e-8, 17.3), ref.interp_u1_at_17p3);

process.exit(c.finish());
