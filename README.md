# SciMLWasm.jl

SciML solvers compiled to WebAssembly via WasmTarget.jl. They run in the browser with no Julia server.

## Layout

```
src/
  bytecode.jl      stack machine that evaluates user equations
  rosenbrock23.jl  stiff solver (Shampine-Reichelt 2(3) W-method)
  solvers.jl       solver entry points exported to wasm
  abi.jl           the JS boundary: allocate, fill, read back
  demo.jl          generates a browser page for a compiled export
  build.jl         one build step shared by every example
examples/
  generic/         the app: write equations, pick a solver, solve in the browser
  common/wasm.mjs  shared loader used by the app and every Node check
  lorenz/ vdp/ rober/   compiled-RHS validation harnesses (one system each)
```

`examples/generic` is the product. The three per-system directories each hold a
`compile.jl` with one right-hand side, a `run.mjs` that checks the wasm against
a native reference, and a generated page; they validate the compiled path and
are what the app's Node check compares itself against.

## Two ways to solve

**Interpreted.** `examples/generic` is one wasm module that solves any
first-order system up to 8 states. The equations are not compiled in: the user
types them, JS parses them to bytecode, and the compiled right-hand side
interprets that bytecode inside the integrator. Change the equation, solve
again, nothing recompiles.

```
dx = y
dy = mu*(1 - x^2)*y - x
```

Unknown identifiers on the right become parameters, with sliders on the page.
`t` is time. Functions: `sin cos tan exp log sqrt abs tanh sinh cosh atan min
max`; `^` (or `**`) is right-associative.

**Compiled.** `examples/lorenz`, `examples/vdp` and `examples/rober` compile one
specific right-hand side. Faster, but the equations are fixed. Use this when an
interpreted right-hand side is too slow.

## Two solvers

`SimpleATsit5` from SimpleDiffEq is an explicit Runge-Kutta method: cheap steps,
5th order, and the default for ordinary problems.

`rosenbrock23!(f!, u0, tspan, p; dt0, abstol, reltol)` is linearly implicit, the
same scheme as OrdinaryDiffEq's `Rosenbrock23()`, with a forward-difference
Jacobian and OrdinaryDiffEq's PI step controller. Each step forms and factors a
matrix, which costs more but stays stable on stiff systems where the explicit
method is forced into impossibly small steps. Robertson to `t = 1e5` takes 266
steps this way; `SimpleATsit5` would need on the order of 1e8.

The generic page has a selector for both. The stiff presets, Robertson and Van
der Pol at μ = 1000, show the difference: with the explicit solver they hit the
page's time budget.

`src/rosenbrock23.jl` is the only solver written out here rather than imported:
OrdinaryDiffEq's `Rosenbrock23` does not compile through WasmTarget yet, and the
file's header says what that would take.

## Build and test

WasmTarget 0.5.3 from the registry lacks the fast-math intrinsic lowering the
stiff solver needs, so `Project.toml` pins WasmTarget to the
`fastmath-intrinsics` branch of the fork through `[sources]`; `Pkg.instantiate`
fetches it. Julia 1.12 is required (1.13 has an open WasmTarget codegen bug).


```sh
julia +1.12 --project=. -e 'using Pkg; Pkg.test()'   # interpreter, solvers, page generator
julia +1.12 --project=. examples/rober/compile.jl    # wasm + ref.json + index.html
node examples/rober/run.mjs                          # wasm against the native reference
node examples/generic/parser_test.mjs                # parser alone, no wasm needed
```

Serve `examples/` with any static file server; the root page opens the app. The
test suite asserts that the interpreted Van der Pol right-hand side is
bit-identical to the hand-written one, and `examples/generic/run.mjs` asserts
the same of the wasm build against both compiled harnesses.

## Generated pages

`write_demo` builds the page from an export's argument list and output layout:

```julia
write_demo(dir, solve_vdp;
           args = [:μ => (10.0, 0.1, 50.0), :tend => (30.0, 5.0, 100.0), :tol => 1e-8],
           states = ["u1", "u2"], tcol = true, wasm = "vdp.wasm")
```

A `(value, min, max)` argument gets a slider; a plain number is fixed. `tcol`
says whether each output row starts with `t`; otherwise `tstep = :dt` names the
argument holding the step size. The page re-solves on every slider move.

For a Jupyter or Pluto notebook, embed the module bytes so no server is needed:

```julia
display("text/html", demo_html(:solve_vdp; args = ..., states = ...,
                               embed = read("examples/vdp/vdp.wasm")))
```

## Bytecode

Opcodes are defined in both `src/bytecode.jl` and `examples/generic/parser.mjs`
and must stay in sync. Operands (`CONST`, `U`, `P`) follow the opcode as the
next word; all indices are 1-based. `x^n` for small integer `n` is evaluated by
repeated multiplication so that `x^2` matches Julia's `literal_pow` lowering.
