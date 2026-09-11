# Robertson, the standard stiff test problem, with Rosenbrock23.
# Run with: julia +1.12 --project=. examples/rober/compile.jl

using SciMLWasm: rosenbrock23!, build_example, flat_ref

function rober!(du, u, p, t)
    k1, k2, k3 = p
    du[1] = -k1 * u[1] + k3 * u[2] * u[3]
    du[2] =  k1 * u[1] - k2 * u[2]^2 - k3 * u[2] * u[3]
    du[3] =  k2 * u[2]^2
    return nothing
end

# Rows are [t, y1, y2, y3].
solve_rober(k1::Float64, k2::Float64, k3::Float64, tend::Float64,
            reltol::Float64, abstol::Float64)::Vector{Float64} =
    rosenbrock23!(rober!, [1.0, 0.0, 0.0], (0.0, tend), (k1, k2, k3);
                  dt0 = 1.0e-6, abstol = abstol, reltol = reltol)

build_example(@__DIR__, "rober",
              [(solve_rober, (Float64, Float64, Float64, Float64, Float64, Float64))];
              ref = flat_ref(solve_rober(0.04, 3.0e7, 1.0e4, 1.0e5, 1.0e-6, 1.0e-8), 4),
              demo = (args = [:k1 => (0.04, 0.001, 0.2), :k2 => (3.0e7, 1.0e6, 1.0e8),
                              :k3 => (1.0e4, 1.0e3, 1.0e5), :tend => (1.0e5, 1.0, 1.0e6),
                              :reltol => 1.0e-6, :abstol => 1.0e-8],
                      states = ["y1", "y2", "y3"], tcol = true, phase = nothing, logx = true,
                      title = "Robertson / Rosenbrock23 in WebAssembly"))
