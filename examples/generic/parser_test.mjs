// Parser-only check: bytecode from parseSystem evaluated by the JS evaluator
// must agree with direct JS evaluation. Run with: node examples/generic/parser_test.mjs
import { parseSystem, evalBytecode, OP } from "./parser.mjs";

let failures = 0;
const check = (cond, msg) => { if (!cond) { failures++; console.log("FAIL:", msg); } };
const close = (a, b, tol = 1e-12) => Math.abs(a - b) <= tol * Math.max(1, Math.abs(a), Math.abs(b));

// random-input agreement with direct JS
const cases = [
  { text: "dx = y\ndy = mu*(1 - x^2)*y - x",
    direct: (u, p, t) => [u[1], p[0] * (1 - u[0] ** 2) * u[1] - u[0]] },
  { text: "dx = s*(y - x); dy = x*(r - z) - y; dz = x*y - b*z",
    direct: (u, p, t) => [p[0] * (u[1] - u[0]), u[0] * (p[1] - u[2]) - u[1], u[0] * u[1] - p[2] * u[2]] },
  { text: "x' = -x^3 + 2*x^2 - x/3 + 0.5",
    direct: (u) => [-(u[0] ** 3) + 2 * u[0] ** 2 - u[0] / 3 + 0.5] },
  { text: "dx = 2^3^2 * x",  // right-assoc: 2^(3^2) = 512
    direct: (u) => [512 * u[0]] },
  { text: "dx = -x^2",       // -(x^2)
    direct: (u) => [-(u[0] ** 2)] },
  { text: "dx = (-x)^2",
    direct: (u) => [u[0] ** 2] },
  { text: "dx = sin(t)*x + cos(w*t) - exp(-k*t) + log(1 + x^2) + sqrt(abs(x))",
    direct: (u, p, t) => [Math.sin(t) * u[0] + Math.cos(p[0] * t) - Math.exp(-p[1] * t) + Math.log(1 + u[0] ** 2) + Math.sqrt(Math.abs(u[0]))] },
  { text: "dx = min(x, 1) + max(x, -1) + tanh(x) + atan(x) + pi*e",
    direct: (u) => [Math.min(u[0], 1) + Math.max(u[0], -1) + Math.tanh(u[0]) + Math.atan(u[0]) + Math.PI * Math.E] },
  { text: "dx = x**2 - 1e-3*x + 2.5E2",
    direct: (u) => [u[0] ** 2 - 1e-3 * u[0] + 250] },
  { text: "dx = a - b - c",   // left-assoc
    direct: (u, p) => [p[0] - p[1] - p[2]] },
  { text: "dx = a / b / c",
    direct: (u, p) => [p[0] / p[1] / p[2]] },
  { text: "dx = x^0.5 + x^-1",  // non-integer and negative-integer exponents
    direct: (u) => [Math.pow(u[0], 0.5) + 1 / u[0]] },
];

let seed = 12345;
const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff) * 4 - 2;

for (const c of cases) {
  const prog = parseSystem(c.text);
  for (let trial = 0; trial < 50; trial++) {
    const u = prog.states.map(() => Math.abs(rnd()) + 0.1); // positive: keeps log/sqrt/x^0.5 real
    const p = prog.params.map(() => rnd() || 0.7);
    const t = Math.abs(rnd());
    const want = c.direct(u, p, t);
    for (let k = 1; k <= prog.states.length; k++) {
      const got = evalBytecode(prog, k, u, p, t);
      check(close(got, want[k - 1]), `${c.text.split("\n")[k - 1]}  got=${got} want=${want[k - 1]}`);
    }
  }
}

// structure
const vdp = parseSystem("dx = y\ndy = mu*(1 - x^2)*y - x");
check(vdp.states.join() === "x,y", "vdp states");
check(vdp.params.join() === "mu", "vdp params");
check(vdp.starts[0] === 1, "first start is 1");
check(vdp.code[vdp.starts[1] - 2] === OP.END, "equation 1 ends with END");
check(vdp.code[vdp.code.length - 1] === OP.END, "last equation ends with END");

const lor = parseSystem("dx = s*(y - x)\ndy = x*(r - z) - y\ndz = x*y - b*z");
check(lor.params.join() === "s,r,b", `lorenz params in order of appearance: ${lor.params}`);
check(lor.consts.length === 0, "lorenz has no numeric constants");

const dedupe = parseSystem("dx = 2*x + 2*y + 3\ndy = 3*x");
check(dedupe.consts.length === 2, `consts deduplicated: ${Array.from(dedupe.consts)}`);

// errors
const mustFail = (text, why) => {
  try { parseSystem(text); failures++; console.log("FAIL: accepted", JSON.stringify(text), "-", why); }
  catch (e) { /* expected */ }
};
mustFail("x = y", "no derivative marker");
mustFail("dx = y +", "dangling operator");
mustFail("dx = foo(x)", "unknown function");
mustFail("dx = (x", "unbalanced paren");
mustFail("dx = x\ndx = y", "duplicate state");
mustFail("dt = 1", "t as a state");
mustFail("dx = x $ y", "bad character");
mustFail(Array.from({ length: 9 }, (_, i) => `du${i} = 1`).join("\n"), "too many states");

console.log(failures === 0 ? "PASS" : `FAIL (${failures})`);
process.exit(failures === 0 ? 0 : 1);
