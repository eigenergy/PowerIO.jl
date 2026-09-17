#!/usr/bin/env julia
#
# Regenerate src/LibPowerIO.jl, the raw layer over the powerio C ABI, from
# powerio-capi/include/powerio.h.
#
#     julia --project=gen gen/generate.jl [path/to/powerio.h]
#
# The header comes from the first argument, else the POWERIO_HEADER environment
# variable, else a sibling powerio checkout. The output is deterministic: the
# same header produces the same file byte for byte.

using Clang.Generators

const ROOT = dirname(@__DIR__)

function header_path()
    isempty(ARGS) || return abspath(ARGS[1])
    env = get(ENV, "POWERIO_HEADER", "")
    isempty(env) || return abspath(env)
    return normpath(joinpath(ROOT, "..", "powerio", "powerio-capi", "include", "powerio.h"))
end

const HEADER = header_path()

isfile(HEADER) || error("""
    PowerIO.jl: no powerio C header at "$HEADER".
    Pass the path as the first argument, set POWERIO_HEADER, or check out
    eigenergy/powerio beside this repository so that
    ../powerio/powerio-capi/include/powerio.h exists.""")

options = load_options(joinpath(@__DIR__, "generator.toml"))
for key in ("output_file_path", "prologue_file_path")
    options["general"][key] = normpath(joinpath(@__DIR__, options["general"][key]))
end

args = get_default_args()
push!(args, "-I" * dirname(HEADER))

ctx = create_context([HEADER], args, options)
build!(ctx)

const OUTPUT = options["general"]["output_file_path"]
const ENTRY_POINTS = count(line -> startswith(line, "function pio_") && !endswith(line, "fptr)"),
                           readlines(OUTPUT))

println("header       : ", HEADER)
println("output       : ", OUTPUT)
println("entry points : ", ENTRY_POINTS)
