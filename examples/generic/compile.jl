# Compile the generic bytecode-RHS solver to examples/generic/generic.wasm.
# Run with: julia +1.12 --project=. examples/generic/compile.jl

using WasmTarget
using SciMLWasm

SciMLWasm.write_opcodes_js(joinpath(@__DIR__, "opcodes.mjs"))
bytes = compile_multi(SciMLWasm.wasm_exports())
wasm_path = joinpath(@__DIR__, "generic.wasm")
write(wasm_path, bytes)
println("wrote $wasm_path ($(length(bytes)) bytes)")
