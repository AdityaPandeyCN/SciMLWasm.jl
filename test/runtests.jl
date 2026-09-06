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
