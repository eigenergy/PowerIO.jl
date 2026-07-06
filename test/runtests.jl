using PowerIO
using Test
using JSON3
using Aqua
using Libdl

@testset "PowerIO" begin
    include("test_public_api.jl") # module API and pure-Julia accessors
    include("test_goc3.jl")       # GO Challenge 3 JSON helpers
    include("test_roundtrip.jl")  # C ABI round trip, adapters, packages
    include("test_powermodels_ref.jl") # PowerModels reference utilities
    include("test_transforms.jl") # PyPSA writer, parse dispatch, to_normalized, to_dense
    include("test_arrow.jl")      # Arrow export (feature arrow)
    include("test_matrix.jl")     # Rust computed sparse matrices
    include("test_memory_safety.jl")
    include("test_gridfm.jl")     # gridfm reader (feature gridfm)
    include("test_dist.jl")       # distribution API (feature dist)
    include("test_aqua.jl")       # Aqua quality checks
end
