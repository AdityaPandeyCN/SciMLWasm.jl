# Rung 1 of the stiff-solver ladder: adaptive SimpleATsit5 on the Van der Pol
# oscillator, compiled to WebAssembly via WasmTarget.
# Run with: julia +1.12 --project=. examples/vdp/compile.jl

using WasmTarget, SimpleDiffEq, StaticArrays, SciMLBase
using DiffEqBase

vdp(u, p, t) = SVector{2,Float64}(u[2], p * (1 - u[1]^2) * u[2] - u[1])

function solve_vdp(μ::Float64, tend::Float64, tol::Float64)::Vector{Float64}
    prob = ODEProblem(vdp, SVector{2,Float64}(2.0, 0.0), (0.0, tend), μ)
    # Bypass the generic `solve` entrypoint (which builds Base.Pairs from a runtime
    # NamedTuple) and call the integrator directly, as WasmTarget's SimpleDiffEq
    # extension does for the fixed-step solvers.
    sol = DiffEqBase.__solve(prob, SimpleATsit5(); dt = 0.01, abstol = tol, reltol = tol)
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

# Dense output: evaluate the SimpleATsit5 interpolant at tq and return u1.
function interp_vdp(μ::Float64, tend::Float64, tol::Float64, tq::Float64)::Float64
    prob = ODEProblem(vdp, SVector{2,Float64}(2.0, 0.0), (0.0, tend), μ)
    sol = DiffEqBase.__solve(prob, SimpleATsit5(); dt = 0.01, abstol = tol, reltol = tol)
    return sol(tq)[1]
end

vlen(v::Vector{Float64})::Int32 = Int32(length(v))
vget(v::Vector{Float64}, i::Int32)::Float64 = v[i]

const here = @__DIR__

bytes = compile_multi([
    (solve_vdp, (Float64, Float64, Float64)),
    (interp_vdp, (Float64, Float64, Float64, Float64)),
    (vlen, (Vector{Float64},)),
    (vget, (Vector{Float64}, Int32)),
])
wasm_path = joinpath(here, "vdp.wasm")
write(wasm_path, bytes)
println("wrote $wasm_path ($(length(bytes)) bytes)")

# Native reference: {nsteps, final_u1, final_u2}
ref = solve_vdp(10.0, 30.0, 1e-8)
nsteps = length(ref) ÷ 3
final_u1 = ref[end-1]
final_u2 = ref[end]
ref_path = joinpath(here, "ref.json")
interp_ref = interp_vdp(10.0, 30.0, 1e-8, 17.3)
open(ref_path, "w") do io
    print(io, "{\"nsteps\": ", nsteps,
              ", \"final_u1\": ", final_u1,
              ", \"final_u2\": ", final_u2,
              ", \"interp_u1_at_17p3\": ", interp_ref, "}\n")
end
println("wrote $ref_path: nsteps=$nsteps final_u1=$final_u1 final_u2=$final_u2 interp_u1(17.3)=$interp_ref")
