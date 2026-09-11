"""
    SciMLWasm

ODE solvers compiled to WebAssembly via WasmTarget.jl, to run in a browser with
no Julia server.

Two ways to use it:

  * **Interpreted.** The right-hand side arrives as bytecode for a small stack
    machine ([`Program`](@ref)), so one compiled module solves any first-order
    system typed at runtime. See `examples/generic`.
  * **Compiled.** A specific right-hand side is compiled into the module, which
    is faster but fixes the equations. See [`build_example`](@ref) and
    `examples/lorenz`, `examples/vdp`, `examples/rober`.

Either way the integrator is [`rosenbrock23!`](@ref) for stiff systems or
SimpleDiffEq's `SimpleATsit5` for the rest.
"""
module SciMLWasm

using StaticArrays
using SciMLBase
using SimpleDiffEq
using DiffEqBase
using WasmTarget: compile_multi
using Base64: base64encode

export Program, run_program, eval_expr, write_opcodes_js
export rosenbrock23!
export alloc_f64, alloc_i32, set_f64, set_i32, vlen, vget
export demo_html, write_demo, build_example

include("bytecode.jl")
include("rosenbrock23.jl")
include("solvers.jl")
include("abi.jl")
include("demo.jl")
include("build.jl")

end # module
