using PowerIO
using Test
using JSON3
using Aqua
using Libdl
using SparseArrays
using Logging
using SHA

# The message a call refuses with, or "" when it did not refuse at all. Reading
# a refusal this way keeps the assertion on the line that makes it: `err = try
# ...; nothing; catch e; e end` took six lines to produce a value whose failure
# printed `nothing !== nothing` and named neither the call nor the message.
# `occursin` against "" is false, so a call that stops throwing still fails —
# except against a *negative* `occursin`, which needs its own `!isempty`.
refusal(f) = try
    f()
    ""
catch e
    sprint(showerror, e)
end

@testset "PowerIO" begin
    include("test_release.jl")    # Project.toml and changelog release guard
    include("test_release_automation.jl") # reviewed intent and artifact state machine
    include("test_public_api.jl") # module API and pure-Julia accessors
    include("test_goc3.jl")       # GO Challenge 3 JSON helpers
    include("test_goc3_static.jl") # GO Challenge 3 SCOPF static index sets
    include("test_scopf.jl")      # native SCOPF instance JSON (feature prob)
    include("test_roundtrip.jl")  # C ABI round trip, adapters, packages
    include("test_powermodels_ref.jl") # PowerModels reference utilities
    include("test_transforms.jl") # PyPSA writer, parse dispatch, to_normalized, to_dense
    include("test_solver_index.jl") # normalized source rows
    include("test_loadseries.jl") # LoadSeries multiperiod bus loads
    include("test_arrow.jl")      # Arrow export (feature arrow)
    include("test_matrix.jl")     # Rust computed sparse matrices
    include("test_dc_power_flow.jl") # PowerModels DC matrix definitions
    include("test_memory_safety.jl")
    include("test_gridfm.jl")     # gridfm reader (feature gridfm)
    include("test_dist.jl")       # distribution API (feature dist)
    include("test_aqua.jl")       # Aqua quality checks
end
