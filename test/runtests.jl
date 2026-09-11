using SciMLWasm
using SciMLWasm: OP_CONST, OP_U, OP_P, OP_T, OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_POW,
                 OP_NEG, OP_SIN, OP_EXP, OP_END, STACK_DEPTH
using StaticArrays, SciMLBase, SimpleDiffEq, DiffEqBase
using Test

# Hand-assembled bytecode in the layout examples/generic/parser.mjs emits.
function program(eqs::Vector{Vector{Int32}}, consts::Vector{Float64}, params::Vector{Float64}, N::Int)
    code = Int32[]
    starts = Int32[]
    for eq in eqs
        push!(starts, Int32(length(code) + 1))
        append!(code, eq)
        push!(code, OP_END)
    end
    Program(code, starts, consts, params, Vector{Float64}(undef, STACK_DEPTH), Vector{Float64}(undef, N))
end

# mu*(1 - x^2)*y - x with x = u1, y = u2, mu = p1, consts = [1.0, 2.0]
const VDP_EQ2 = Int32[OP_P, 1, OP_CONST, 1, OP_U, 1, OP_CONST, 2, OP_POW, OP_SUB, OP_MUL,
                      OP_U, 2, OP_MUL, OP_U, 1, OP_SUB]

@testset "SciMLWasm" begin
    @testset "interpreter" begin
        p = program([Int32[OP_U, 2], VDP_EQ2], [1.0, 2.0], [10.0], 2)
        u = SVector(0.3, -1.7)
        @test run_program(p, 1, u, 0.0) === u[2]
        @test run_program(p, 2, u, 0.0) === 10.0 * (1 - u[1]^2) * u[2] - u[1]

        # sin(t)*x + exp(-k*t)
        e = Int32[OP_T, OP_SIN, OP_U, 1, OP_MUL, OP_P, 1, OP_NEG, OP_T, OP_MUL, OP_EXP, OP_ADD]
        p2 = program([e], Float64[], [0.7], 1)
        t = 1.3
        @test run_program(p2, 1, SVector(2.5), t) ≈ sin(t) * 2.5 + exp(-0.7 * t)

        @test eval_expr(p.code, p.starts, p.consts, p.params, [0.3, -1.7], 0.0, Int32(2)) ===
              run_program(p, 2, u, 0.0)
    end

    @testset "generic solver == hand-written RHS" begin
        p = program([Int32[OP_U, 2], VDP_EQ2], [1.0, 2.0], [10.0], 2)
        out = SciMLWasm.solve_generic_2(p.code, p.starts, p.consts, p.params,
                                        [2.0, 0.0], 0.0, 30.0, 0.01, 1e-8)

        vdp(u, μ, t) = SVector{2,Float64}(u[2], μ * (1 - u[1]^2) * u[2] - u[1])
        prob = ODEProblem(vdp, SVector{2,Float64}(2.0, 0.0), (0.0, 30.0), 10.0)
        ref = DiffEqBase.__solve(prob, SimpleATsit5(); dt = 0.01, abstol = 1e-8, reltol = 1e-8)

        n = length(ref.u)
        @test length(out) == 3n
        @test n == 922
        for i in 1:n
            @test out[3i - 2] === ref.t[i]
            @test out[3i - 1] === ref.u[i][1]
            @test out[3i]     === ref.u[i][2]
        end
    end

    @testset "harmonic oscillator oracle" begin
        osc = [Int32[OP_U, 2], Int32[OP_U, 1, OP_NEG]]
        p = program(osc, Float64[], Float64[], 2)
        out = SciMLWasm.solve_generic_2(p.code, p.starts, p.consts, p.params,
                                        [1.0, 0.0], 0.0, 10.0, 0.01, 1e-10)
        @test abs(out[end - 1] - cos(10.0)) < 1e-7
        @test abs(out[end] + sin(10.0)) < 1e-7
    end

    @testset "demo page" begin
        html = demo_html(:solve_vdp; args = [:μ => (10.0, 0.1, 50.0), :tol => 1e-8],
                         states = ["u1", "u2"], title = "VdP <demo>")
        @test occursin("<title>VdP &lt;demo&gt;</title>", html)
        @test occursin("main { max-width: 720px; margin: 0 auto; }", html)
        @test occursin("\"fn\":\"solve_vdp\"", html)
        @test occursin("\"wasm\":\"solve_vdp.wasm\"", html)
        @test occursin("{\"name\":\"μ\",\"value\":10.0,\"min\":0.1,\"max\":50.0,\"fixed\":false}", html)
        @test occursin("\"name\":\"tol\",\"value\":1.0e-8,\"min\":0.0,\"max\":0.0,\"fixed\":true", html)
        @test occursin("\"phase\":[1,2]", html)
        @test occursin("\"logx\":false", html)
        @test !occursin("</script>", SciMLWasm._json("</script>"))

        embedded = demo_html(:f; args = [], states = ["x"], embed = UInt8[0, 0x61, 0x73, 0x6d])
        @test occursin("\"wasmB64\":\"AGFzbQ==\"", embedded)
        @test occursin("\"wasm\":null", embedded)
        @test_throws ArgumentError demo_html(:f; args = [:a => (1.0, 0.0)], states = ["x"])
        @test_throws ArgumentError demo_html(:f; args = [:a => 1.0], states = ["x"], tstep = :dt)

        mktempdir() do dir
            path = write_demo(dir, :f; args = [], states = ["x"])
            @test path == joinpath(dir, "index.html")
            @test isfile(path)
        end
    end

    @testset "generic stiff path == rosenbrock23! on hand-written RHS" begin
        # -k1*y1 + k3*y2*y3 ; k1*y1 - k2*y2^2 - k3*y2*y3 ; k2*y2^2   (params k1,k2,k3; consts [2.0])
        e1 = Int32[OP_P, 1, OP_NEG, OP_U, 1, OP_MUL, OP_P, 3, OP_U, 2, OP_MUL, OP_U, 3, OP_MUL, OP_ADD]
        e2 = Int32[OP_P, 1, OP_U, 1, OP_MUL, OP_P, 2, OP_U, 2, OP_CONST, 1, OP_POW, OP_MUL, OP_SUB,
                   OP_P, 3, OP_U, 2, OP_MUL, OP_U, 3, OP_MUL, OP_SUB]
        e3 = Int32[OP_P, 2, OP_U, 2, OP_CONST, 1, OP_POW, OP_MUL]
        p = program([e1, e2, e3], [2.0], [0.04, 3e7, 1e4], 3)
        out = SciMLWasm.solve_generic_rb23(p.code, p.starts, p.consts, p.params,
                                           [1.0, 0.0, 0.0], 0.0, 1e5, 1e-6, 1e-8, 1e-6)
        function rober!(du, u, q, t)
            k1, k2, k3 = q
            du[1] = -k1 * u[1] + k3 * u[2] * u[3]
            du[2] =  k1 * u[1] - k2 * u[2]^2 - k3 * u[2] * u[3]
            du[3] =  k2 * u[2]^2
            nothing
        end
        ref = rosenbrock23!(rober!, [1.0, 0.0, 0.0], (0.0, 1e5), (0.04, 3e7, 1e4);
                            dt0 = 1e-6, abstol = 1e-8, reltol = 1e-6)
        @test length(out) == length(ref)
        @test all(i -> out[i] === ref[i], eachindex(out))
    end

    @testset "rosenbrock23" begin
        # LU against a known solve
        A = [4.0 3.0 2.0; 2.0 1.0 3.0; 6.0 5.0 4.0]
        b = [1.0, 2.0, 3.0]
        Aflat = vec(copy(A)); piv = zeros(Int, 3); x = copy(b)
        SciMLWasm.lu_factor!(Aflat, piv, 3)
        SciMLWasm.lu_solve!(Aflat, piv, x, 3)
        @test A * x ≈ b atol = 1e-12

        # linear stiff problem with exact solution; error falls with tolerance
        lin!(du, u, p, t) = (du[1] = -1000.0 * (u[1] - cos(t)); nothing)
        a = 1e6 / (1e6 + 1); c = 1e3 / (1e6 + 1)
        exact(t) = a * cos(t) + c * sin(t) + (1.0 - a) * exp(-1000.0 * t)
        errs = map((1e-3, 1e-5, 1e-7)) do tol
            out = rosenbrock23!(lin!, [1.0], (0.0, 5.0), nothing; dt0 = 1e-4, abstol = tol, reltol = tol)
            @test out[1] == 0.0 && out[end - 1] == 5.0
            abs(out[end] - exact(5.0))
        end
        @test errs[1] < 1e-6 && errs[2] < errs[1] && errs[3] < errs[2]

        # Robertson: stiff, mass conserved, known long-time limit
        function rober!(du, u, p, t)
            k1, k2, k3 = p
            du[1] = -k1 * u[1] + k3 * u[2] * u[3]
            du[2] =  k1 * u[1] - k2 * u[2]^2 - k3 * u[2] * u[3]
            du[3] =  k2 * u[2]^2
            nothing
        end
        out = rosenbrock23!(rober!, [1.0, 0.0, 0.0], (0.0, 1e5), (0.04, 3e7, 1e4);
                            dt0 = 1e-6, abstol = 1e-8, reltol = 1e-6)
        n = length(out) ÷ 4
        @test 100 < n < 2000
        @test all(i -> out[4i - 3] <= out[4i + 1], 1:(n - 1))      # t increasing
        @test abs(sum(out[end - 2:end]) - 1.0) < 1e-12
        @test 0.01 < out[end - 2] < 0.03 && out[end] > 0.97

        # blow-up terminates quickly with a partial result, not a hang
        blow!(du, u, p, t) = (du[1] = u[1]^2; nothing)
        tm = @elapsed part = rosenbrock23!(blow!, [1.0], (0.0, 5.0), nothing; dt0 = 0.01, abstol = 1e-6, reltol = 1e-6)
        @test part[end - 1] < 5.0 && part[end - 1] > 0.99
        @test tm < 2.0

        # against OrdinaryDiffEq's Rosenbrock23 with a finite-difference Jacobian
        if Base.find_package("OrdinaryDiffEqRosenbrock") !== nothing
            @eval using OrdinaryDiffEqRosenbrock, ADTypes
            prob = ODEProblem(rober!, [1.0, 0.0, 0.0], (0.0, 1e5), (0.04, 3e7, 1e4))
            tight = solve(prob, Rodas5P(); abstol = 1e-14, reltol = 1e-14).u[end]
            theirs = solve(prob, Rosenbrock23(autodiff = AutoFiniteDiff());
                           dt = 1e-6, abstol = 1e-8, reltol = 1e-6)
            relerr(v) = maximum(abs.(v .- tight) ./ abs.(tight))
            @test relerr(out[end - 2:end]) < 10 * max(relerr(theirs.u[end]), 1e-8)
            @test n < 5 * theirs.stats.naccept
        else
            @warn "OrdinaryDiffEqRosenbrock not available; skipping reference comparison"
        end
    end

    @testset "bytecode contract is generated" begin
        committed = joinpath(@__DIR__, "..", "examples", "generic", "opcodes.mjs")
        @test isfile(committed)
        @test read(committed, String) == SciMLWasm.opcodes_js()
        @test occursin("END: $(Int(SciMLWasm.OP_END)),", SciMLWasm.opcodes_js())
        @test length(SciMLWasm.OPCODES) == Int(SciMLWasm.OP_END) + 1     # dense 0..END
        @test allunique(values(SciMLWasm.OPCODES))
    end

    @testset "accessors" begin
        v = alloc_f64(Int32(3))
        set_f64(v, Int32(2), 4.5)
        @test vlen(v) == 3
        @test vget(v, Int32(2)) == 4.5
        w = alloc_i32(Int32(2))
        set_i32(w, Int32(1), Int32(7))
        @test w[1] == 7
    end
end
