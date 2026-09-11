// Shared wasm plumbing for every example, in Node and in the browser.

// Compile and instantiate a SciMLWasm module. The compiled code uses the
// standardised wasm:js-string builtins; every other import is a no-op stub.
export async function instantiate(bytes) {
  const module = await WebAssembly.compile(bytes, { builtins: ["js-string"] });
  const imports = {};
  for (const { module: m, name, kind } of WebAssembly.Module.imports(module)) {
    if (m.startsWith("wasm:")) continue;
    imports[m] ??= {};
    if (kind === "function") imports[m][name] = () => {};
    else console.warn(`unstubbed non-function import ${m}.${name} (${kind})`);
  }
  const { exports } = await WebAssembly.instantiate(module, imports);
  return exports;
}

// Read a flattened solver result into columns. Rows are [t, u...] when
// `tcol` is true and [u...] otherwise, `n` state components either way.
export function readFlat(ex, sol, n, { tcol = true, dt = 1 } = {}) {
  const stride = tcol ? n + 1 : n;
  const rows = ex.vlen(sol) / stride;
  const t = new Float64Array(rows);
  const u = Array.from({ length: n }, () => new Float64Array(rows));
  for (let i = 0; i < rows; i++) {
    const base = stride * i;
    t[i] = tcol ? ex.vget(sol, base + 1) : i * dt;
    for (let j = 0; j < n; j++) u[j][i] = ex.vget(sol, base + (tcol ? 2 : 1) + j);
  }
  return { t, u, rows };
}

// A tiny pass/fail recorder so the Node checks read the same way.
export function checker() {
  let ok = true;
  return {
    get ok() { return ok; },
    // Report a value against a reference; `tol === null` prints without asserting.
    close(label, got, want, tol = 1e-8) {
      const d = Math.abs(got - want);
      const note = tol === null ? "  (info only)" : "";
      console.log(`${label}  wasm=${got}  ref=${want}  |diff|=${d}${note}`);
      if (tol !== null && !(d <= tol)) ok = false;
    },
    equal(label, got, want, message) {
      console.log(`${label}  wasm=${got}  ref=${want}`);
      if (got !== want) {
        ok = false;
        if (message) console.log(`*** ${message} ***`);
      }
    },
    fail(message) {
      ok = false;
      console.log(message);
    },
    finish() {
      console.log(ok ? "PASS" : "FAIL");
      return ok ? 0 : 1;
    },
  };
}
