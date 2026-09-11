# Rosenbrock23: the Shampine-Reichelt 2(3) W-method (ode23s), mirroring
# OrdinaryDiffEq's `Rosenbrock23()` with a finite-difference Jacobian and its
# PI step-size controller. Everything lives on flat `Vector{Float64}` storage
# with a hand-written pivoted LU, so WasmTarget can lower it.
#
# Why this is written out rather than imported. Every explicit solver in this
# package is imported from SimpleDiffEq, which WasmTarget supports through a
# dedicated extension. No such extension exists for OrdinaryDiffEq, and its
# `Rosenbrock23` does not compile through WasmTarget as is: problem
# construction, logging, keyword sorters, matrix allocation and the linear
# solve each need overlays or compiler changes. That work is parked on the
# `ordinarydiffeq-gaps-wip` branch of the WasmTarget fork; until it lands, this
# file is the stiff solver.

const RB23_C32 = 6.0 + sqrt(2.0)
const RB23_D   = 1.0 / (2.0 + sqrt(2.0))
const RB23_BETA1 = 7.0 / 20.0      # 7 / (10 * order), order 2
const RB23_BETA2 = 1.0 / 5.0       # 2 / (5 * order)
const RB23_QMIN = 0.2
const RB23_QMAX = 10.0
const RB23_GAMMA = 0.9
const RB23_QOLDINIT = 1.0e-4
const FD_EPS = sqrt(eps(Float64))

# In-place LU with partial pivoting on column-major `A` (n×n, flat).
function lu_factor!(A::Vector{Float64}, piv::Vector{Int}, n::Int)
    for k in 1:n
        pk = k
        amax = abs(A[(k - 1) * n + k])
        for i in (k + 1):n
            a = abs(A[(k - 1) * n + i])
            if a > amax
                amax = a
                pk = i
            end
        end
        piv[k] = pk
        if pk != k
            for j in 1:n
                cj = (j - 1) * n
                A[cj + k], A[cj + pk] = A[cj + pk], A[cj + k]
            end
        end
        akk = A[(k - 1) * n + k]
        if akk != 0.0
            for i in (k + 1):n
                A[(k - 1) * n + i] /= akk
            end
        end
        for j in (k + 1):n
            cj = (j - 1) * n
            ajk = A[cj + k]
            if ajk != 0.0
                for i in (k + 1):n
                    A[cj + i] -= A[(k - 1) * n + i] * ajk
                end
            end
        end
    end
    return A
end

# Solve LU x = b in place (b becomes x).
function lu_solve!(A::Vector{Float64}, piv::Vector{Int}, b::Vector{Float64}, n::Int)
    for k in 1:n
        pk = piv[k]
        if pk != k
            b[k], b[pk] = b[pk], b[k]
        end
    end
    for j in 1:n
        bj = b[j]
        if bj != 0.0
            cj = (j - 1) * n
            for i in (j + 1):n
                b[i] -= A[cj + i] * bj
            end
        end
    end
    for j in n:-1:1
        b[j] /= A[(j - 1) * n + j]
        bj = b[j]
        if bj != 0.0
            cj = (j - 1) * n
            for i in 1:(j - 1)
                b[i] -= A[cj + i] * bj
            end
        end
    end
    return b
end

"""
    rosenbrock23!(f!, u0, tspan, p; dt0, abstol, reltol, maxiters) -> Vector{Float64}

Solve `du/dt = f(u, p, t)` with `f!(du, u, p, t)` in place, from `tspan[1]` to
`tspan[2]`, starting with step `dt0`. Returns `[t, u...]` per accepted step,
flattened. The Jacobian is a forward difference; `dt` is controlled by the same
PI controller as OrdinaryDiffEq's `Rosenbrock23`. Integration stops early (last
`t` below `tspan[2]`) if the error estimate becomes NaN, the step underflows, or
`maxiters` is reached.
"""
function rosenbrock23!(f!::F, u0::Vector{Float64}, tspan::Tuple{Float64,Float64}, p;
                       dt0::Float64 = 1.0e-4, abstol::Float64 = 1.0e-6, reltol::Float64 = 1.0e-3,
                       maxiters::Int = 1_000_000)::Vector{Float64} where {F}
    n = length(u0)
    t, tend = tspan
    dt = dt0
    uprev = copy(u0)
    u    = similar(u0)
    utmp = similar(u0)
    f0 = similar(u0); f1 = similar(u0); f2 = similar(u0); fe = similar(u0)
    k1 = similar(u0); k2 = similar(u0); k3 = similar(u0)
    dT = similar(u0); b = similar(u0)
    J = Vector{Float64}(undef, n * n)
    W = Vector{Float64}(undef, n * n)
    piv = Vector{Int}(undef, n)

    # Output buffer with geometric growth: WasmTarget's `push!` reallocates on
    # every call, which made long solves quadratic.
    stride = n + 1
    cap = 256 * stride
    out = Vector{Float64}(undef, cap)
    len = 0
    out[1] = t
    for i in 1:n
        out[1 + i] = uprev[i]
    end
    len = stride

    f!(f0, uprev, p, t)
    errold = RB23_QOLDINIT
    iters = 0
    while t < tend
        iters += 1
        iters > maxiters && break
        if t + dt > tend
            dt = tend - t
        end
        dtγ = dt * RB23_D

        # Forward-difference Jacobian J[:, i] = (f(u + ε eᵢ) - f(u)) / ε.
        for i in 1:n
            copyto!(utmp, uprev)
            ε = max(FD_EPS * abs(uprev[i]), FD_EPS)
            utmp[i] += ε
            f!(fe, utmp, p, t)
            ci = (i - 1) * n
            for r in 1:n
                J[ci + r] = (fe[r] - f0[r]) / ε
            end
        end
        # Time derivative by forward difference.
        εt = max(FD_EPS * abs(t), FD_EPS)
        f!(fe, uprev, p, t + εt)
        for r in 1:n
            dT[r] = (fe[r] - f0[r]) / εt
        end

        # W = I - dtγ J, factored once per step.
        for j in 1:n
            cj = (j - 1) * n
            for i in 1:n
                W[cj + i] = -dtγ * J[cj + i]
            end
            W[cj + j] += 1.0
        end
        lu_factor!(W, piv, n)

        # Stage 1: W k₁ = f₀ + dtγ dT
        for r in 1:n
            b[r] = f0[r] + dtγ * dT[r]
        end
        lu_solve!(W, piv, b, n)
        copyto!(k1, b)

        # Stage 2: W (k₂ - k₁) = f(u₀ + dt/2 k₁) - k₁
        for r in 1:n
            u[r] = uprev[r] + (dt / 2) * k1[r]
        end
        f!(f1, u, p, t + dt / 2)
        for r in 1:n
            b[r] = f1[r] - k1[r]
        end
        lu_solve!(W, piv, b, n)
        for r in 1:n
            k2[r] = b[r] + k1[r]
        end

        # Solution and error estimate.
        for r in 1:n
            u[r] = uprev[r] + dt * k2[r]
        end
        f!(f2, u, p, t + dt)
        for r in 1:n
            b[r] = f2[r] - RB23_C32 * (k2[r] - f1[r]) - 2.0 * (k1[r] - f0[r]) + dt * dT[r]
        end
        lu_solve!(W, piv, b, n)
        copyto!(k3, b)

        sumsq = 0.0
        for r in 1:n
            err = (dt / 6) * (k1[r] - 2.0 * k2[r] + k3[r])
            sc = abstol + reltol * max(abs(uprev[r]), abs(u[r]))
            sumsq += (err / sc)^2
        end
        eest = sqrt(sumsq / n)
        eest == eest || break                      # NaN: give up, return what we have

        # PI controller (OrdinaryDiffEq PIController semantics).
        if eest == 0.0
            q11 = 1.0
            q = 1.0 / RB23_QMAX
        else
            q11 = eest^RB23_BETA1
            q = q11 / errold^RB23_BETA2
            q = max(1.0 / RB23_QMAX, min(1.0 / RB23_QMIN, q / RB23_GAMMA))
        end

        if eest <= 1.0
            t += dt
            copyto!(uprev, u)
            copyto!(f0, f2)
            if len + stride > cap
                cap *= 2
                grown = Vector{Float64}(undef, cap)
                for i in 1:len
                    grown[i] = out[i]
                end
                out = grown
            end
            out[len + 1] = t
            for r in 1:n
                out[len + 1 + r] = u[r]
            end
            len += stride
            errold = max(eest, RB23_QOLDINIT)
            dt = dt / q
        else
            dt = dt / min(1.0 / RB23_QMIN, q11 / RB23_GAMMA)
        end
        t + dt == t && break                       # step underflow
    end
    res = Vector{Float64}(undef, len)
    for i in 1:len
        res[i] = out[i]
    end
    return res
end
