// Parses a system of first-order ODEs into bytecode for SciMLWasm's stack
// machine. Opcodes must match src/SciMLWasm.jl.
//
// One equation per line (or separated by ';'), as `dx = ...` or `x' = ...`:
//
//   dx = y
//   dy = mu*(1 - x^2)*y - x
//
// States are numbered in order of appearance. Any identifier on the right
// that is not a state, `t`, a function, or a named constant becomes a
// parameter, numbered in order of first appearance.

import { readFlat } from "../common/wasm.mjs";

import { OP, UNARY, BINARY, MAX_DIM } from "./opcodes.mjs";
export { OP, MAX_DIM };

// `ln` is a spelling of log; the bytecode has one LOG opcode.
const FUNCS1 = { ...UNARY, ln: OP.LOG };
const FUNCS2 = BINARY;
const NAMED_CONSTS = { pi: Math.PI, e: Math.E };

class ParseError extends Error {}

const TOKEN_RE = /\s*(?:(\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)|([A-Za-z_]\w*)|(\*\*|[-+*/^(),]))/y;

function tokenize(src) {
  const toks = [];
  TOKEN_RE.lastIndex = 0;
  let pos = 0;
  while (pos < src.length) {
    if (/^\s*$/.test(src.slice(pos))) break;
    TOKEN_RE.lastIndex = pos;
    const m = TOKEN_RE.exec(src);
    if (!m || m.index !== pos) throw new ParseError(`unexpected character '${src[pos]}' at ${pos} in "${src}"`);
    pos = TOKEN_RE.lastIndex;
    if (m[1] !== undefined) toks.push({ kind: "num", value: parseFloat(m[1]) });
    else if (m[2] !== undefined) toks.push({ kind: "id", value: m[2] });
    else toks.push({ kind: "op", value: m[3] === "**" ? "^" : m[3] });
  }
  toks.push({ kind: "eof" });
  return toks;
}

class Emitter {
  constructor(env) {
    this.env = env;
    this.code = [];
  }
  constIdx(v) {
    const key = Object.is(v, -0) ? "0" : String(v);
    let i = this.env.constIndex.get(key);
    if (i === undefined) {
      this.env.consts.push(v);
      i = this.env.consts.length;
      this.env.constIndex.set(key, i);
    }
    return i;
  }
  paramIdx(name) {
    let i = this.env.params.get(name);
    if (i === undefined) {
      i = this.env.params.size + 1;
      this.env.params.set(name, i);
    }
    return i;
  }
}

// Precedence climbing: +,- (1, left)  *,/ (2, left)  unary - (3)  ^ (4, right).
// -x^2 parses as -(x^2), matching Julia and JS.
function parseExpr(toks, em) {
  let i = 0;
  const peek = () => toks[i];
  const next = () => toks[i++];
  const expectOp = (v) => {
    const t = next();
    if (t.kind !== "op" || t.value !== v) throw new ParseError(`expected '${v}'`);
  };

  function primary() {
    const t = next();
    if (t.kind === "num") {
      em.code.push(OP.CONST, em.constIdx(t.value));
      return;
    }
    if (t.kind === "id") {
      const name = t.value;
      if (peek().kind === "op" && peek().value === "(") {
        next();
        if (name in FUNCS1) {
          expr(0); expectOp(")");
          em.code.push(FUNCS1[name]);
          return;
        }
        if (name in FUNCS2) {
          expr(0); expectOp(","); expr(0); expectOp(")");
          em.code.push(FUNCS2[name]);
          return;
        }
        throw new ParseError(`unknown function '${name}'`);
      }
      if (name === "t") { em.code.push(OP.T); return; }
      if (em.env.states.has(name)) { em.code.push(OP.U, em.env.states.get(name)); return; }
      if (name in NAMED_CONSTS) { em.code.push(OP.CONST, em.constIdx(NAMED_CONSTS[name])); return; }
      em.code.push(OP.P, em.paramIdx(name));
      return;
    }
    if (t.kind === "op" && t.value === "(") {
      expr(0); expectOp(")");
      return;
    }
    if (t.kind === "op" && t.value === "-") {
      expr(3);
      em.code.push(OP.NEG);
      return;
    }
    if (t.kind === "op" && t.value === "+") {
      expr(3);
      return;
    }
    throw new ParseError(t.kind === "eof" ? "unexpected end of expression" : `unexpected '${t.value}'`);
  }

  const BIN = { "+": [1, OP.ADD], "-": [1, OP.SUB], "*": [2, OP.MUL], "/": [2, OP.DIV], "^": [4, OP.POW] };

  function expr(minPrec) {
    primary();
    for (;;) {
      const t = peek();
      if (t.kind !== "op" || !(t.value in BIN)) break;
      const [prec, op] = BIN[t.value];
      if (prec < minPrec) break;
      next();
      expr(t.value === "^" ? prec : prec + 1);
      em.code.push(op);
    }
  }

  expr(0);
  if (peek().kind !== "eof") throw new ParseError(`unexpected '${peek().value}' after expression`);
}

const LHS_RE = /^\s*(?:d([A-Za-z_]\w*)|([A-Za-z_]\w*)')\s*=\s*(.+?)\s*$/;

export function parseSystem(text) {
  const lines = text.split(/[\n;]/).map((s) => s.replace(/#.*$/, "").trim()).filter(Boolean);
  if (lines.length === 0) throw new ParseError("no equations");
  if (lines.length > MAX_DIM) throw new ParseError(`at most ${MAX_DIM} states are supported (got ${lines.length})`);

  const env = { states: new Map(), params: new Map(), consts: [], constIndex: new Map() };
  const rhsTexts = [];
  for (const line of lines) {
    const m = LHS_RE.exec(line);
    if (!m) throw new ParseError(`cannot read "${line}"; write it as "dx = ..." or "x' = ..."`);
    const name = m[1] ?? m[2];
    if (name === "t") throw new ParseError("'t' is the independent variable and cannot be a state");
    if (env.states.has(name)) throw new ParseError(`state '${name}' is defined twice`);
    env.states.set(name, env.states.size + 1);
    rhsTexts.push(m[3]);
  }

  const em = new Emitter(env);
  const starts = [];
  for (const rhs of rhsTexts) {
    starts.push(em.code.length + 1);
    parseExpr(tokenize(rhs), em);
    em.code.push(OP.END);
  }

  return {
    states: [...env.states.keys()],
    params: [...env.params.keys()],
    code: Int32Array.from(em.code),
    starts: Int32Array.from(starts),
    consts: Float64Array.from(env.consts),
  };
}

// Reference evaluator mirroring run_program in SciMLWasm.jl, including the
// small-integer pow rule, so wasm and JS can be compared bitwise.
function powi(x, y) {
  const n = Math.round(y);
  if (n === y && Math.abs(n) <= 16) {
    let k = n, b = x;
    if (k < 0) { b = 1 / x; k = -k; }
    let r = 1;
    for (let i = 0; i < k; i++) r *= b;
    return r;
  }
  return Math.pow(x, y);
}

export function evalBytecode(prog, k, u, params, t) {
  const { code, starts, consts } = prog;
  const st = new Float64Array(64);
  let pc = starts[k - 1] - 1, sp = -1;
  for (;;) {
    const op = code[pc++];
    switch (op) {
      case OP.CONST: st[++sp] = consts[code[pc++] - 1]; break;
      case OP.U:     st[++sp] = u[code[pc++] - 1]; break;
      case OP.P:     st[++sp] = params[code[pc++] - 1]; break;
      case OP.T:     st[++sp] = t; break;
      case OP.ADD:   st[sp - 1] = st[sp - 1] + st[sp]; sp--; break;
      case OP.SUB:   st[sp - 1] = st[sp - 1] - st[sp]; sp--; break;
      case OP.MUL:   st[sp - 1] = st[sp - 1] * st[sp]; sp--; break;
      case OP.DIV:   st[sp - 1] = st[sp - 1] / st[sp]; sp--; break;
      case OP.POW:   st[sp - 1] = powi(st[sp - 1], st[sp]); sp--; break;
      case OP.NEG:   st[sp] = -st[sp]; break;
      case OP.SIN:   st[sp] = Math.sin(st[sp]); break;
      case OP.COS:   st[sp] = Math.cos(st[sp]); break;
      case OP.TAN:   st[sp] = Math.tan(st[sp]); break;
      case OP.EXP:   st[sp] = Math.exp(st[sp]); break;
      case OP.LOG:   st[sp] = Math.log(st[sp]); break;
      case OP.SQRT:  st[sp] = Math.sqrt(st[sp]); break;
      case OP.ABS:   st[sp] = Math.abs(st[sp]); break;
      case OP.TANH:  st[sp] = Math.tanh(st[sp]); break;
      case OP.SINH:  st[sp] = Math.sinh(st[sp]); break;
      case OP.COSH:  st[sp] = Math.cosh(st[sp]); break;
      case OP.ATAN:  st[sp] = Math.atan(st[sp]); break;
      case OP.MIN:   st[sp - 1] = Math.min(st[sp - 1], st[sp]); sp--; break;
      case OP.MAX:   st[sp - 1] = Math.max(st[sp - 1], st[sp]); sp--; break;
      case OP.END:   return st[sp];
      default: return NaN;
    }
  }
}

// Wasm glue: copy JS arrays into wasm-side vectors and call solve_generic_N.
export function makeSolver(ex) {
  const pushF64 = (arr) => {
    const v = ex.alloc_f64(arr.length);
    for (let i = 0; i < arr.length; i++) ex.set_f64(v, i + 1, arr[i]);
    return v;
  };
  const pushI32 = (arr) => {
    const v = ex.alloc_i32(arr.length);
    for (let i = 0; i < arr.length; i++) ex.set_i32(v, i + 1, arr[i]);
    return v;
  };

  return {
    // Returns { t: Float64Array, u: Float64Array[] (one per state), nsteps }.
    // method: "atsit5" (explicit, adaptive SimpleATsit5) or "rb23" (stiff, Rosenbrock23).
    solve(prog, paramValues, u0, t0, tend, dt0, { abstol, reltol, method = "atsit5" }) {
      const N = prog.states.length;
      if (u0.length !== N) throw new Error(`u0 has ${u0.length} values, system has ${N} states`);
      if (paramValues.length !== prog.params.length) throw new Error("parameter count mismatch");
      const args = [pushI32(prog.code), pushI32(prog.starts), pushF64(prog.consts),
                    pushF64(paramValues), pushF64(u0), t0, tend, dt0];
      let sol;
      if (method === "rb23") {
        sol = ex.solve_generic_rb23(...args, abstol, reltol);
      } else if (method === "atsit5") {
        const fn = ex[`solve_generic_${N}`];
        if (!fn) throw new Error(`no compiled explicit solver for ${N} states`);
        if (abstol !== reltol) throw new Error("SimpleATsit5 export uses one tolerance for abstol and reltol");
        sol = fn(...args, reltol);
      } else {
        throw new Error(`unknown method ${method}`);
      }
      const { t, u, rows } = readFlat(ex, sol, N);
      return { t, u, nsteps: rows };
    },
    evalExpr(prog, k, uVals, paramValues, t) {
      return ex.eval_expr(pushI32(prog.code), pushI32(prog.starts), pushF64(prog.consts),
                          pushF64(paramValues), pushF64(uVals), t, k);
    },
  };
}
