@testset "RAVENS profiles and PMD MATHEMATICAL through ABI 7" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        @testset "balanced RAVENS" begin
            original = parse(fixture("case9.m"))
            result = emit(original, "ravens-json")
            back = parse(IOBuffer(result.text); name="case9.json")
            @test back isa PioModule{BalancedNetwork}
            @test length(back.value.buses) == length(original.value.buses)
            @test length(back.value.branches) == length(original.value.branches)
            @test back.sources[1].format == "ravens-json"
            @test emit(back, "ravens-json").text == result.text
            @test emit(back, "ravens-json").fidelity == "exact_same_format"
            restored = deserialize(Vector{UInt8}(serialize(back).text))
            @test restored isa PioModule{BalancedNetwork}
            # IR assigns stable ids to findings that arrived without one.
            @test [filter(p -> first(p) != "id", d) for d in diagnostic_records(restored.diagnostics)] ==
                  [filter(p -> first(p) != "id", d) for d in diagnostic_records(back.diagnostics)]
            @test length(parse(IOBuffer(emit(restored, "psse").text); format="psse").value.buses) == 9
        end

        # A small four-wire feeder keeps the physical load and source explicit.
        feeder = """
        Clear
        New Circuit.ravens basekv=0.4 bus1=source.1.2.3 pu=1 phases=3
        New Line.l1 bus1=source.1.2.3.4 bus2=loadbus.1.2.3.4 phases=4 length=0.1 units=km rmatrix=[0.2 | 0 0.2 | 0 0 0.2 | 0 0 0 0.2] xmatrix=[0.1 | 0 0.1 | 0 0 0.1 | 0 0 0 0.1]
        New Load.l1 bus1=loadbus.1.2.3.4 phases=3 conn=wye kv=0.4 kw=12 kvar=3 model=1
        """
        original = parse(IOBuffer(feeder); format="dss", name="feeder.dss")
        for format in ("ravens-json", "pmd-math-json")
            @testset "$format multiconductor" begin
                result = emit(original, format)
                back = parse(IOBuffer(result.text); name="feeder.json")
                @test back isa PioModule{MulticonductorNetwork}
                @test back.sources[1].format == format
                @test sum(sum(l.active_power_nominal_w) for l in back.value.loads) ≈ 12_000.0
                @test sum(sum(l.reactive_power_nominal_var) for l in back.value.loads) ≈ 3_000.0
                @test emit(back, format).text == result.text
                @test emit(back, format).fidelity == "exact_same_format"
                @test parse(MulticonductorNetwork, IOBuffer(result.text); format=format) isa MulticonductorNetwork
                @test_throws ArgumentError parse(BalancedNetwork, IOBuffer(result.text); format=format)
                restored = deserialize(Vector{UInt8}(serialize(back).text))
                @test restored isa PioModule{MulticonductorNetwork}
                # IR assigns stable ids to findings that arrived without one.
            @test [filter(p -> first(p) != "id", d) for d in diagnostic_records(restored.diagnostics)] ==
                  [filter(p -> first(p) != "id", d) for d in diagnostic_records(back.diagnostics)]
                converted = emit(restored, "pmd-json")
                again = parse(IOBuffer(converted.text); format="pmd-json")
                @test sum(sum(l.active_power_nominal_w) for l in again.value.loads) ≈ 12_000.0
                network = back.value
                back = nothing
                GC.gc()
                @test sum(sum(l.active_power_nominal_w) for l in network.loads) ≈ 12_000.0
            end
        end
    end
end
