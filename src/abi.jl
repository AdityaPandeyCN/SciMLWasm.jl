# The JS boundary: JS cannot build a Julia Vector directly, so it allocates
# one here, fills it element by element, and reads results back the same way.

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
    push!(ex, (solve_generic_rb23, (SOLVE_ARGTYPES..., Float64)))
    return ex
end

