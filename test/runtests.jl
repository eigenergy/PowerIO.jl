using PowerIO
using Test

@testset "PowerIO" begin
    @testset "loads and exposes its surface" begin
        # The module must load with no C library present (the binding is lazy),
        # and its public surface must exist.
        for sym in (:Network, :parse_case, :convert_case, :write_matpower)
            @test isdefined(PowerIO, sym)
        end
        @test PowerIO._lib() isa AbstractString
    end

    @testset "C ABI round trip" begin
        if !PowerIO.library_available()
            @info "libpowerio_capi not found (set POWERIO_CAPI to a local build); skipping ccall tests"
            @test_skip parse_case("case14.m")
        else
            data = joinpath(@__DIR__, "data")
            net = parse_case(joinpath(data, "case14.m"))
            @test PowerIO.n_buses(net) == 14
            @test PowerIO.base_mva(net) == 100.0
            text, warnings = convert_case(joinpath(data, "case14.m"), "matpower")
            @test occursin("mpc.bus", text)
            @test isempty(warnings)
        end
    end
end
