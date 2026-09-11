# Lorenz with fixed-step SimpleTsit5, compiled to WebAssembly.
# Run with: julia +1.12 --project=. examples/lorenz/compile.jl

using SimpleDiffEq, StaticArrays, SciMLBase
using SciMLWasm: build_example, flat_ref

lorenz(u, p, t) = SVector{3,Float64}(p[1] * (u[2] - u[1]),
                                     u[1] * (p[2] - u[3]) - u[2],
                                     u[1] * u[2] - p[3] * u[3])

# Rows are [x, y, z]; t is implied by the fixed step.
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

# Harmonic oscillator with exact solution (cos t, -sin t): the oracle that
# decides PASS/FAIL, since Lorenz itself is chaotic.
osc(u, p, t) = SVector{2,Float64}(u[2], -u[1])

function solve_osc(dt::Float64, tend::Float64)::Vector{Float64}
    prob = ODEProblem(osc, SVector{2,Float64}(1.0, 0.0), (0.0, tend), 0.0)
    sol = solve(prob, SimpleTsit5(); dt = dt)
    u = sol.u[end]
    return [u[1], u[2]]
end

build_example(@__DIR__, "lorenz",
              [(solve_lorenz, (Float64, Float64, Float64, Float64, Float64)),
               (solve_osc, (Float64, Float64))];
              ref = flat_ref(solve_lorenz(10.0, 28.0, 8 / 3, 0.01, 20.0), 3; tcol = false),
              demo = (args = [:σ => (10.0, 0.0, 30.0), :ρ => (28.0, 0.0, 60.0),
                              :β => (8 / 3, 0.1, 10.0), :dt => 0.01, :tend => (20.0, 1.0, 100.0)],
                      states = ["x", "y", "z"], tcol = false, tstep = :dt, phase = (1, 3),
                      title = "Lorenz / SimpleTsit5 in WebAssembly"))
