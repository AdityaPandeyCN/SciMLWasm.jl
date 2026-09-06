# SciMLWasm.jl

SciML solvers compiled to WebAssembly via WasmTarget.jl. They run in the browser with no Julia server.

## Generic solver: type an equation, solve it

`examples/generic` is one compiled `.wasm` that solves any first-order ODE system
up to 8 states. The equations are not compiled in. The user types them, JS
parses them to bytecode for a small stack machine, and the compiled RHS
(`src/SciMLWasm.jl`) interprets that bytecode inside adaptive `SimpleATsit5`.
Change the equation, solve again, no recompilation.

```
dx = y
dy = mu*(1 - x^2)*y - x
```

Unknown identifiers on the right-hand side become parameters (with sliders in
the demo page). `t` is time. Functions: `sin cos tan exp log sqrt abs tanh sinh
cosh atan min max`; `^` (or `**`) is right-associative.

Build and test:

```sh
julia +1.12 --project=. -e 'using Pkg; Pkg.test()'      # native: interpreter and solver checks
julia +1.12 --project=. examples/generic/compile.jl      # writes examples/generic/generic.wasm
node examples/generic/parser_test.mjs                    # parser alone, no wasm needed
node examples/generic/run.mjs                            # wasm vs JS interpreter, vs ../vdp/ref.json
```

Then serve `examples/generic/` with any static file server and open `index.html`.

The native test asserts that the interpreted Van der Pol RHS is bit-identical to
the hand-written one (same 922 accepted steps, `===` on every value). `run.mjs`
asserts the same of the wasm build against `examples/vdp/ref.json`.

## Per-model examples

`examples/lorenz` (fixed-step `SimpleTsit5`) and `examples/vdp` (adaptive
`SimpleATsit5` with dense output) compile a specific right-hand side. Use this
path when the system is large enough that an interpreted RHS is too slow.
Each `compile.jl` writes the wasm, a native `ref.json`, and its browser page;
`run.mjs` checks the wasm against the reference in Node.

The page is not written by hand. `write_demo` generates it from the export's
argument list and output layout:

```julia
write_demo(dir, solve_vdp;
           args = [:μ => (10.0, 0.1, 50.0), :tend => (30.0, 5.0, 100.0), :tol => 1e-8],
           states = ["u1", "u2"], tcol = true, wasm = "vdp.wasm")
```

A `(value, min, max)` argument gets a slider; a plain number is fixed. `tcol`
says whether each output row starts with `t`; otherwise `tstep = :dt` names
the argument holding the step size. The page re-solves on every slider move.

To show the same page inline in a Jupyter or Pluto notebook, embed the module
bytes so no server is involved:

```julia
html = demo_html(:solve_vdp; args = ..., states = ..., embed = read("examples/vdp/vdp.wasm"))
display("text/html", html)
```

## Bytecode

Opcodes are defined in both `src/SciMLWasm.jl` and `examples/generic/parser.mjs`
and must stay in sync. Operands (`CONST`, `U`, `P`) follow the opcode as the
next word; all indices are 1-based. `x^n` for small integer `n` is evaluated by
repeated multiplication so that `x^2` matches Julia's `literal_pow` lowering.
