# One build step shared by every compiled-RHS example: compile the entry points
# to wasm, record a native reference, and generate the browser page. Each
# example's compile.jl then holds only its equations and its parameter ranges.

"""
    flat_ref(out, stride; tcol = true) -> NamedTuple

Summarise a flattened solver result as `(rows, final)`: the number of rows and
the last row's state components. `stride` is the row width; `tcol` says whether
each row leads with `t`, in which case it is excluded from `final`.
"""
function flat_ref(out::Vector{Float64}, stride::Int; tcol::Bool = true)
    rows = length(out) ÷ stride
    ncomp = tcol ? stride - 1 : stride
    return (rows = rows, final = out[(end - ncomp + 1):end])
end

"""
    build_example(dir, name, entries; ref, demo) -> NamedTuple

Compile `entries` plus the vector accessors into `<dir>/<name>.wasm`, write
`ref` as `<dir>/ref.json`, and generate `<dir>/index.html`.

  * `entries`: `(function, argtypes)` pairs to export, solver first.
  * `ref`: a `NamedTuple` of native reference values for the Node check.
  * `demo`: keyword arguments forwarded to [`write_demo`](@ref); the solver's
    name and wasm filename are filled in from `entries[1]` and `name`.

Returns `(wasm, ref, page)`, the three paths written.
"""
function build_example(dir::AbstractString, name::AbstractString, entries;
                       ref::NamedTuple, demo::NamedTuple)
    exports = Any[entries...]
    push!(exports, (vlen, (Vector{Float64},)))
    push!(exports, (vget, (Vector{Float64}, Int32)))

    bytes = compile_multi(exports)
    wasm = joinpath(dir, name * ".wasm")
    write(wasm, bytes)
    println("wrote $wasm ($(length(bytes)) bytes)")

    refpath = joinpath(dir, "ref.json")
    write(refpath, _json(ref) * "\n")
    println("wrote $refpath: ", _json(ref))

    page = write_demo(dir, nameof(first(first(entries))); wasm = name * ".wasm", demo...)
    println("wrote $page")

    return (wasm = wasm, ref = refpath, page = page)
end
