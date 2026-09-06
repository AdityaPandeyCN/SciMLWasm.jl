# Phase 0: compile a Lorenz SimpleTsit5 solve to WebAssembly via WasmTarget.
# Run with: julia +1.12 --project=. examples/lorenz/compile.jl

using WasmTarget
using SimpleDiffEq
using StaticArrays
using SciMLBase
using SciMLWasm: write_demo

lorenz(u, p, t) = SVector{3,Float64}(p[1] * (u[2] - u[1]),
                          u[1] * (p[2] - u[3]) - u[2],
                          u[1] * u[2] - p[3] * u[3])

function solve_lorenz(σ::Float64, ρ::Float64, β::Float64, dt::Float64, tend::Float64)::Vector{Float64}
    prob = ODEProblem(lorenz, SVector{3,Float64}(1.0, 0.0, 0.0), (0.0, tend), (σ, ρ, β))
    sol = solve(prob, SimpleTsit5(); dt = dt)
    n = length(sol.u)
    out = Vector{Float64}(undef, 3 * n)
    for i in 1:n
        u = sol.u[i]
        out[3i - 2] = u[1]
        out[3i - 1] = u[2]
        out[3i]     = u[3]
    end
    return out
end

# Harmonic-oscillator oracle: exact solution is (cos t, -sin t), so the wasm
# result can be checked against Math.cos / Math.sin at a tight tolerance.
osc(u, p, t) = SVector{2,Float64}(u[2], -u[1])

function solve_osc(dt::Float64, tend::Float64)::Vector{Float64}
    prob = ODEProblem(osc, SVector{2,Float64}(1.0, 0.0), (0.0, tend), 0.0)
    sol = solve(prob, SimpleTsit5(); dt = dt)
    u = sol.u[end]
    return [u[1], u[2]]
end

vlen(v::Vector{Float64})::Int32 = Int32(length(v))
vget(v::Vector{Float64}, i::Int32)::Float64 = v[i]

const here = @__DIR__

bytes = compile_multi([
    (solve_lorenz, (Float64, Float64, Float64, Float64, Float64)),
    (solve_osc, (Float64, Float64)),
    (vlen, (Vector{Float64},)),
    (vget, (Vector{Float64}, Int32)),
])
wasm_path = joinpath(here, "lorenz.wasm")
write(wasm_path, bytes)
println("wrote $wasm_path ($(length(bytes)) bytes)")

# Native reference: {length, last3}
ref = solve_lorenz(10.0, 28.0, 8 / 3, 0.01, 20.0)
last3 = ref[end-2:end]
ref_path = joinpath(here, "ref.json")
open(ref_path, "w") do io
    print(io, "{\"length\": ", length(ref), ", \"last3\": [",
          join(string.(last3), ", "), "]}\n")
end
println("wrote $ref_path: length=$(length(ref)) last3=$last3")

# Browser page: sliders for the parameters, dt fixed; output rows are [x, y, z].
write_demo(here, solve_lorenz;
           args = [:σ => (10.0, 0.0, 30.0), :ρ => (28.0, 0.0, 60.0), :β => (8 / 3, 0.1, 10.0),
                   :dt => 0.01, :tend => (20.0, 1.0, 100.0)],
           states = ["x", "y", "z"], tcol = false, tstep = :dt, phase = (1, 3),
           title = "Lorenz / SimpleTsit5 in WebAssembly", wasm = "lorenz.wasm")
println("wrote $(joinpath(here, "index.html"))")
