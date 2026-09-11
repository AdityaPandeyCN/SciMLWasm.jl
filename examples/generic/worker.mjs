// Runs the wasm solver off the main thread so a stiff problem handed to the
// explicit solver cannot freeze the page; the page terminates the worker when
// a solve exceeds its time budget.
import { makeSolver } from "./parser.mjs";
import { instantiate } from "../common/wasm.mjs";

let solver = null;

async function init() {
  const bytes = await fetch("generic.wasm").then((r) => r.arrayBuffer());
  solver = makeSolver(await instantiate(bytes));
  return bytes.byteLength;
}

const ready = init();

self.onmessage = async (e) => {
  const { id, prog, pvals, u0, t0, tend, dt0, opts } = e.data;
  try {
    await ready;
    const t1 = performance.now();
    const sol = solver.solve(prog, pvals, u0, t0, tend, dt0, opts);
    const ms = performance.now() - t1;
    self.postMessage({ id, ok: true, t: sol.t, u: sol.u, nsteps: sol.nsteps, ms },
                     [sol.t.buffer, ...sol.u.map((a) => a.buffer)]);
  } catch (err) {
    self.postMessage({ id, ok: false, error: String(err && err.stack || err) });
  }
};

ready.then((bytes) => self.postMessage({ ready: true, bytes }),
           (err) => self.postMessage({ ready: false, error: String(err && err.stack || err) }));
