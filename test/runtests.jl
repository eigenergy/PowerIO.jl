using PowerIO
using Test
using JSON3

@testset "PowerIO" begin
    @testset "loads and exposes its surface" begin
        # The module must load with no C library present (the binding is lazy),
        # and its public surface must exist.
        for sym in (:Network, :parse_case, :convert_case, :write_matpower)
            @test isdefined(PowerIO, sym)
        end
        # The accessor surface the ecosystem bridges read is unexported but must exist.
        for sym in (:n_buses, :n_branches, :n_gens, :base_mva, :network_name,
                    :source_format, :reference_bus_id, :bus_type_code,
                    :buses, :generators, :branches, :loads, :shunts, :storage, :hvdc)
            @test isdefined(PowerIO, sym)
        end
        @test PowerIO._lib() isa AbstractString
    end

    @testset "pure-Julia accessors (no binary)" begin
        # `reference_bus_id` and `bus_type_code` are pure functions of the parsed JSON,
        # so build a `Network` straight from a JSON3 object and exercise every branch
        # without the native library.
        mk(buses) = PowerIO.Network(JSON3.read(JSON3.write((; buses = buses))))

        # REF at id 2 / position 2 distinguishes "returns the id" from "returns the index".
        one_ref = mk([(id = 1, kind = "PQ"), (id = 2, kind = "REF"), (id = 3, kind = "PV")])
        @test PowerIO.reference_bus_id(one_ref) == 2
        @test PowerIO.reference_bus_id(mk([(id = 1, kind = "REF"), (id = 2, kind = "REF")])) === nothing
        @test PowerIO.reference_bus_id(mk([(id = 1, kind = "PQ"), (id = 2, kind = "PV")])) === nothing

        @test PowerIO.bus_type_code("PQ") == 1
        @test PowerIO.bus_type_code("PV") == 2
        @test PowerIO.bus_type_code("REF") == 3
        @test PowerIO.bus_type_code("ISOLATED") == 4
        @test_throws ArgumentError PowerIO.bus_type_code("SLACK")
    end

    @testset "C ABI round trip" begin
        if !PowerIO.library_available()
            @info "libpowerio_capi not found (set POWERIO_CAPI to a local build); skipping ccall tests"
            @test_skip parse_case("case14.m")
        else
            data = joinpath(@__DIR__, "data")
            net = parse_case(joinpath(data, "case14.m"))
            @test PowerIO.n_buses(net) == 14
            @test PowerIO.n_gens(net) == 5
            @test PowerIO.base_mva(net) == 100.0
            @test PowerIO.source_format(net) == "Matpower"
            @test PowerIO.reference_bus_id(net) == 1
            @test isempty(PowerIO.storage(net))
            @test isempty(PowerIO.hvdc(net))

            # `from` hint threads through to pio_parse.
            net_hinted = parse_case(joinpath(data, "case14.m"); from = "matpower")
            @test PowerIO.n_buses(net_hinted) == 14

            # EGRET and PowerModels both use .json; the `from` hint is what tells them
            # apart. The fixtures were produced by convert_case from case14.m.
            egret = parse_case(joinpath(data, "case14.egret.json"); from = "egret")
            @test PowerIO.n_buses(egret) == 14
            @test PowerIO.source_format(egret) == "EgretJson"
            pm = parse_case(joinpath(data, "case14.pm.json"); from = "powermodels")
            @test PowerIO.n_buses(pm) == 14
            @test PowerIO.source_format(pm) == "PowerModelsJson"

            # Same-format conversion is byte-exact and warning-free.
            text, warnings = convert_case(joinpath(data, "case14.m"), "matpower")
            @test occursin("mpc.bus", text)
            @test isempty(warnings)

            # A cross-format target exercises a second writer and the warnings vector.
            psse_text, psse_warnings = convert_case(joinpath(data, "case14.m"), "psse")
            @test !isempty(psse_text)
            @test psse_warnings isa AbstractVector{<:AbstractString}
        end
    end
end
