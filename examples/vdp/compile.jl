# Van der Pol with adaptive SimpleATsit5 and dense output, compiled to WebAssembly.
# Run with: julia +1.12 --project=. examples/vdp/compile.jl

using SimpleDiffEq, StaticArrays, SciMLBase, DiffEqBase
using SciMLWasm: build_example, flat_ref

vdp(u, p, t) = SVector{2,Float64}(u[2], p * (1 - u[1]^2) * u[2] - u[1])

# `solve` builds Base.Pairs from a runtime NamedTuple, which WasmTarget cannot
# compile; `__solve` is the integrator entry point underneath it.
_solve(μ, tend, tol) = DiffEqBase.__solve(
    ODEProblem(vdp, SVector{2,Float64}(2.0, 0.0), (0.0, tend), μ),
    SimpleATsit5(); dt = 0.01, abstol = tol, reltol = tol)

# Rows are [t, u1, u2]: adaptive steps, so t has to be carried.
function solve_vdp(μ::Float64, tend::Float64, tol::Float64)::Vector{Float64}
    sol = _solve(μ, tend, tol)
    n = length(sol.u)
    out = Vector{Float64}(undef, 3 * n)
    for i in 1:n
        u = sol.u[i]
        out[3i - 2] = sol.t[i]
        out[3i - 1] = u[1]
        out[3i]     = u[2]
    end
    return out
end

# Dense output: the Tsit5 interpolant between accepted steps.
interp_vdp(μ::Float64, tend::Float64, tol::Float64, tq::Float64)::Float64 = _solve(μ, tend, tol)(tq)[1]

build_example(@__DIR__, "vdp",
              [(solve_vdp, (Float64, Float64, Float64)),
               (interp_vdp, (Float64, Float64, Float64, Float64))];
              ref = merge(flat_ref(solve_vdp(10.0, 30.0, 1e-8), 3),
                          (interp_u1_at_17p3 = interp_vdp(10.0, 30.0, 1e-8, 17.3),)),
              demo = (args = [:μ => (10.0, 0.1, 50.0), :tend => (30.0, 5.0, 100.0), :tol => 1e-8],
                      states = ["u1", "u2"], tcol = true,
                      title = "Van der Pol / adaptive SimpleATsit5 in WebAssembly"))
