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
get(ENV, "POWERIO_REQUIRE_LIBRARY", "0") == "1" && !LIBRARY_AVAILABLE && error("A compatible C library is required for this test run")
LIBRARY_AVAILABLE || @info "PowerIO: no compatible libpowerio_capi resolved; ccall tests skip (set POWERIO_CAPI)"

const DATA = joinpath(@__DIR__, "data")
fixture(parts...) = joinpath(DATA, parts...)

@testset "PowerIO" begin
    include("test_release.jl")            # Project.toml and changelog release guard
    include("test_release_automation.jl") # reviewed intent and artifact state machine
    include("test_public_api.jl")         # the exported surface
    include("test_capi_coverage.jl")      # every generated entry point is bound or exempt
    include("test_operations.jl")         # parse, emit, serialize, deserialize
    include("test_network.jl")            # BalancedNetwork element tables
    include("test_geography.jl")
    include("test_dist.jl")               # MulticonductorNetwork element tables
    include("test_collections.jl")        # TimeSeries, ScenarioSet, instances, solutions
    include("test_lindist3flow.jl")
    include("test_handle_operations.jl")
    include("test_updates.jl")            # typed updates and apply_updates!
    include("test_connectivity.jl")       # DetailedConnectivity tables
    include("test_scuc.jl")               # AC SCUC instance inputs
    include("test_contingency.jl")        # PSS/E contingency, subsystem, monitored sets
    include("test_geo.jl")                # geographic layers
    include("test_matrix.jl")             # DC calculations and admittance matrices
    include("test_sensitivity.jl")         # deterministic PTDF sensitivity
    include("test_bridges.jl")            # PowerModels and ExaModelsPower bridges
    include("test_aqua.jl")               # Aqua quality checks
end
