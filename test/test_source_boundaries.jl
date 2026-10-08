@testset "Referenced voltage source boundaries" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        text = """
        {"meta":{"frequency":50},
         "terminal_conventions":{"phase":["a"],"neutral":["n"]},
         "bus":{"b":{"terminal_names":["a","n"]}},
         "voltage_source":{"s":{"bus":"b","terminal_map":["a"],
                                  "v_magnitude":[230],"v_angle":[0.2]}}}
        """
        earth = parse(IOBuffer(text); format="bmopf", name="source-boundary.json")
        @test earth.value.voltage_sources[1].reference_terminal === nothing
        @test to_mc_ac_pf_instance(earth).value.source_boundaries[1].reference_terminal === nothing
        @test VoltageSource("s", "b", ["a"], [230.0], [0.2], nothing).reference_terminal === nothing

        # Construct the additive IR record without adding a native fixture or
        # teaching an exchange writer a reference it cannot yet represent.
        doc = JSON3.read(serialize(earth).text, Dict{String,Any})
        data = doc["value"]["data"]
        source = data["sources"][1]
        source["reference_terminal"] = "n"
        data["sources"][1] = Dict("type" => "powerio.ReferencedVoltageSource", "value" => source)
        floating = deserialize(Vector{UInt8}(JSON3.write(doc)))
        net = floating.value
        src = net.voltage_sources[1]
        @test src.reference_terminal == "n"
        @test src.bus == "b"
        @test src.terminals == ["a"]
        @test src.voltage_magnitude_v == [230.0]
        @test src.voltage_angle_rad == [0.2]

        pf = to_mc_ac_pf_instance(floating)
        @test :source_boundaries in propertynames(pf.value)
        table = pf.value.source_boundaries
        @test table isa AbstractVector{VoltageSource}
        @test size(table) == (1,)
        @test_throws BoundsError table[0]
        @test_throws BoundsError table[2]
        boundary = only(table)
        @test boundary.name == src.name
        @test boundary.bus == src.bus
        @test boundary.terminals == src.terminals
        @test boundary.reference_terminal == "n"
        @test boundary.voltage_magnitude_v == src.voltage_magnitude_v
        @test boundary.voltage_angle_rad == src.voltage_angle_rad

        restored = deserialize(Vector{UInt8}(serialize(pf).text))
        @test restored.value.source_boundaries[1].reference_terminal == "n"
        @test restored.value.network.voltage_sources[1].reference_terminal == "n"
        floating = pf = net = nothing
        GC.gc()
        @test table[1].reference_terminal == "n"
        @test table[1].voltage_magnitude_v == [230.0]
    end
end
