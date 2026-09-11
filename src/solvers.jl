# Solver entry points exported to wasm. Both take the same bytecode Program
# as the right-hand side; they differ only in the integrator behind it.

# One RHS and one solve entry point per state dimension, on the SVector
# out-of-place path WasmTarget's SimpleDiffEq extension supports.
for N in 1:MAX_DIM
    rhs_name   = Symbol(:rhs_, N)
    solve_name = Symbol(:solve_generic_, N)
    sv_from_du = Expr(:call, :(SVector{$N,Float64}), [:(d[$i]) for i in 1:N]...)
    sv_from_u0 = Expr(:call, :(SVector{$N,Float64}), [:(u0[$i]) for i in 1:N]...)
    @eval begin
        function $rhs_name(u::SVector{$N,Float64}, p::Program, t::Float64)::SVector{$N,Float64}
            d = p.du
            for k in 1:$N
                d[k] = run_program(p, k, u, t)
            end
            return $sv_from_du
        end

        # Returns [t, u1..uN] per accepted step, flattened.
        function $solve_name(code::Vector{Int32}, starts::Vector{Int32},
                             consts::Vector{Float64}, params::Vector{Float64},
                             u0::Vector{Float64}, t0::Float64, tend::Float64,
                             dt0::Float64, tol::Float64)::Vector{Float64}
            p = Program(code, starts, consts, params,
                        Vector{Float64}(undef, STACK_DEPTH), Vector{Float64}(undef, $N))
            u0s = $sv_from_u0
            prob = ODEProblem($rhs_name, u0s, (t0, tend), p)
            # `solve` builds Base.Pairs from a runtime NamedTuple, which
            # WasmTarget cannot compile; `__solve` skips that.
            sol = DiffEqBase.__solve(prob, SimpleATsit5(); dt = dt0, abstol = tol, reltol = tol)
            n = length(sol.u)
            out = Vector{Float64}(undef, ($N + 1) * n)
            for i in 1:n
                base = ($N + 1) * (i - 1)
                out[base + 1] = sol.t[i]
                ui = sol.u[i]
                for j in 1:$N
                    out[base + 1 + j] = ui[j]
                end
            end
            return out
        end
    end
end

# Stiff path: the same bytecode RHS evaluated in place for `rosenbrock23!`.
# Dimension-generic, so one export covers every N.
function rhs_generic!(du::Vector{Float64}, u::Vector{Float64}, p::Program, t::Float64)
    for k in 1:length(du)
        du[k] = run_program(p, k, u, t)
    end
    return nothing
end

# Returns [t, u1..uN] per accepted step, flattened, like solve_generic_N.
function solve_generic_rb23(code::Vector{Int32}, starts::Vector{Int32},
                            consts::Vector{Float64}, params::Vector{Float64},
                            u0::Vector{Float64}, t0::Float64, tend::Float64,
                            dt0::Float64, abstol::Float64, reltol::Float64)::Vector{Float64}
    n = length(u0)
    p = Program(code, starts, consts, params,
                Vector{Float64}(undef, STACK_DEPTH), Vector{Float64}(undef, n))
    return rosenbrock23!(rhs_generic!, u0, (t0, tend), p; dt0 = dt0, abstol = abstol, reltol = reltol)
end
