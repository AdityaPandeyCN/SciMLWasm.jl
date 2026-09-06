"""
    SciMLWasm

ODE solvers compiled to WebAssembly via WasmTarget.jl. The generic solver takes
the right-hand side as bytecode for a small stack machine, so one compiled
module solves any first-order system a user types at runtime.
"""
module SciMLWasm

using StaticArrays
using SciMLBase
using SimpleDiffEq
using DiffEqBase
using Base64: base64encode

export Program, run_program, eval_expr
export demo_html, write_demo
export alloc_f64, alloc_i32, set_f64, set_i32, vlen, vget

# Opcodes must match examples/generic/parser.mjs. CONST, U and P take the
# next word as a 1-based operand.
const OP_CONST = Int32(0)
const OP_U     = Int32(1)
const OP_P     = Int32(2)
const OP_T     = Int32(3)
const OP_ADD   = Int32(4)
const OP_SUB   = Int32(5)
const OP_MUL   = Int32(6)
const OP_DIV   = Int32(7)
const OP_POW   = Int32(8)
const OP_NEG   = Int32(9)
const OP_SIN   = Int32(10)
const OP_COS   = Int32(11)
const OP_TAN   = Int32(12)
const OP_EXP   = Int32(13)
const OP_LOG   = Int32(14)
const OP_SQRT  = Int32(15)
const OP_ABS   = Int32(16)
const OP_TANH  = Int32(17)
const OP_SINH  = Int32(18)
const OP_COSH  = Int32(19)
const OP_ATAN  = Int32(20)
const OP_MIN   = Int32(21)
const OP_MAX   = Int32(22)
const OP_END   = Int32(23)

const STACK_DEPTH = 64
const MAX_DIM = 8

"""
    Program(code, starts, consts, params, stack, du)

A bytecode system. `code` holds all equations back to back and `starts[k]` is
the index in `code` where equation `k` begins. `stack` and `du` are scratch
buffers allocated once per solve.
"""
struct Program
    code::Vector{Int32}
    starts::Vector{Int32}
    consts::Vector{Float64}
    params::Vector{Float64}
    stack::Vector{Float64}
    du::Vector{Float64}
end

# Small integer exponents by repeated multiplication so `x^2` matches Julia's
# `literal_pow` lowering bit for bit.
@inline function powi(x::Float64, y::Float64)::Float64
    n = round(y)
    if n == y && abs(n) <= 16.0
        k = Int(n)
        b = x
        if k < 0
            b = 1.0 / x
            k = -k
        end
        r = 1.0
        for _ in 1:k
            r *= b
        end
        return r
    end
    return x^y
end

"""
    run_program(p::Program, k, u, t)

Evaluate equation `k` of `p` at state `u` and time `t`.
"""
function run_program(p::Program, k::Int, u, t::Float64)::Float64
    code = p.code
    st = p.stack
    pc = Int(p.starts[k])
    sp = 0
    while true
        op = code[pc]
        pc += 1
        if op == OP_CONST
            sp += 1
            st[sp] = p.consts[code[pc]]
            pc += 1
        elseif op == OP_U
            sp += 1
            st[sp] = u[code[pc]]
            pc += 1
        elseif op == OP_P
            sp += 1
            st[sp] = p.params[code[pc]]
            pc += 1
        elseif op == OP_T
            sp += 1
            st[sp] = t
        elseif op == OP_ADD
            st[sp - 1] = st[sp - 1] + st[sp]
            sp -= 1
        elseif op == OP_SUB
            st[sp - 1] = st[sp - 1] - st[sp]
            sp -= 1
        elseif op == OP_MUL
            st[sp - 1] = st[sp - 1] * st[sp]
            sp -= 1
        elseif op == OP_DIV
            st[sp - 1] = st[sp - 1] / st[sp]
            sp -= 1
        elseif op == OP_POW
            st[sp - 1] = powi(st[sp - 1], st[sp])
            sp -= 1
        elseif op == OP_NEG
            st[sp] = -st[sp]
        elseif op == OP_SIN
            st[sp] = sin(st[sp])
        elseif op == OP_COS
            st[sp] = cos(st[sp])
        elseif op == OP_TAN
            st[sp] = tan(st[sp])
        elseif op == OP_EXP
            st[sp] = exp(st[sp])
        elseif op == OP_LOG
            st[sp] = log(st[sp])
        elseif op == OP_SQRT
            st[sp] = sqrt(st[sp])
        elseif op == OP_ABS
            st[sp] = abs(st[sp])
        elseif op == OP_TANH
            st[sp] = tanh(st[sp])
        elseif op == OP_SINH
            st[sp] = sinh(st[sp])
        elseif op == OP_COSH
            st[sp] = cosh(st[sp])
        elseif op == OP_ATAN
            st[sp] = atan(st[sp])
        elseif op == OP_MIN
            st[sp - 1] = min(st[sp - 1], st[sp])
            sp -= 1
        elseif op == OP_MAX
            st[sp - 1] = max(st[sp - 1], st[sp])
            sp -= 1
        elseif op == OP_END
            return st[sp]
        else
            return NaN
        end
    end
end

"""
    eval_expr(code, starts, consts, params, u, t, k)

Evaluate equation `k` from raw bytecode arrays. Exported to wasm so the JS
side can check the interpreter against its own evaluator.
"""
function eval_expr(code::Vector{Int32}, starts::Vector{Int32}, consts::Vector{Float64},
                   params::Vector{Float64}, u::Vector{Float64}, t::Float64, k::Int32)::Float64
    p = Program(code, starts, consts, params,
                Vector{Float64}(undef, STACK_DEPTH), Vector{Float64}(undef, 1))
    return run_program(p, Int(k), u, t)
end

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

alloc_f64(n::Int32)::Vector{Float64} = Vector{Float64}(undef, Int(n))
alloc_i32(n::Int32)::Vector{Int32}   = Vector{Int32}(undef, Int(n))
set_f64(v::Vector{Float64}, i::Int32, x::Float64)::Int32 = (v[i] = x; Int32(0))
set_i32(v::Vector{Int32}, i::Int32, x::Int32)::Int32     = (v[i] = x; Int32(0))
vlen(v::Vector{Float64})::Int32 = Int32(length(v))
vget(v::Vector{Float64}, i::Int32)::Float64 = v[i]

const SOLVE_ARGTYPES = (Vector{Int32}, Vector{Int32}, Vector{Float64}, Vector{Float64},
                        Vector{Float64}, Float64, Float64, Float64, Float64)

"""
    wasm_exports()

The `(function, argtypes)` list for `WasmTarget.compile_multi`.
"""
function wasm_exports()
    ex = Any[
        (eval_expr, (Vector{Int32}, Vector{Int32}, Vector{Float64}, Vector{Float64},
                     Vector{Float64}, Float64, Int32)),
        (alloc_f64, (Int32,)),
        (alloc_i32, (Int32,)),
        (set_f64, (Vector{Float64}, Int32, Float64)),
        (set_i32, (Vector{Int32}, Int32, Int32)),
        (vlen, (Vector{Float64},)),
        (vget, (Vector{Float64}, Int32)),
    ]
    for N in 1:MAX_DIM
        push!(ex, (getfield(@__MODULE__, Symbol(:solve_generic_, N)), SOLVE_ARGTYPES))
    end
    return ex
end

include("demo.jl")

end # module
