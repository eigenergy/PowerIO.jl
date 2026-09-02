using PowerIO
using Test
using JSON3
using Aqua
using Libdl
using Logging
using SHA
using SparseArrays

# The C library under test. Every ccall test skips when no library resolves;
# CI sets `POWERIO_CAPI` to a fresh `powerio-capi` build.
const LIBRARY_AVAILABLE = PowerIO.library_available()
LIBRARY_AVAILABLE || @info "PowerIO: no compatible libpowerio_capi resolved; ccall tests skip (set POWERIO_CAPI)"

const DATA = joinpath(@__DIR__, "data")
fixture(parts...) = joinpath(DATA, parts...)

@testset "PowerIO" begin
    include("test_release.jl")            # Project.toml and changelog release guard
    include("test_release_automation.jl") # reviewed intent and artifact state machine
    include("test_public_api.jl")         # the exported surface
    include("test_operations.jl")         # parse, emit, serialize, deserialize
    include("test_network.jl")            # BalancedNetwork element tables
    include("test_dist.jl")               # MulticonductorNetwork element tables
    include("test_collections.jl")        # TimeSeries, ScenarioSet, instances, solutions
    include("test_updates.jl")            # typed updates and apply_updates!
    include("test_aqua.jl")               # Aqua quality checks
end
