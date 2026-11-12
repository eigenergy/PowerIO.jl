@testset "Geographic data" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        source = raw"""{
          "meta":{"schema_version":"0.2.0"},
          "bus":{
            "a":{"terminal_names":["1"],"geo":{"type":"Point","coordinates":[-83.7,42.3]}},
            "b":{"terminal_names":["1"],"geo":{"type":"Point","coordinates":[-83.6,42.4]}}
          },
          "line":{"ab":{"bus_from":"a","bus_to":"b",
            "terminal_map_from":["1"],"terminal_map_to":["1"],
            "R_series_1_1":0.1,"X_series_1_1":0.2,
            "geo":{"type":"LineString","coordinates":[[-83.7,42.3],[-83.68,42.36],[-83.6,42.4]]}}}
        }"""
        m = parse(IOBuffer(source); format="bmopf-json", name="geo.bmopf.json")
        @test m.value.geo.space == "geographic"
        @test m.value.buses[1].location.x == -83.7
        @test length(m.value.lines[1].route) == 3
        @test m.value.lines[1].route[2].y == 42.36
        ir = JSON3.read(serialize(m).text, Dict{String,Any})
        ir["value"]["data"]["buses"][1]["location"]["x"] = -83.72
        edited = deserialize(Vector{UInt8}(JSON3.write(ir)))
        written = emit(edited, "bmopf-json")
        doc = JSON3.read(written.text)
        # BMOPF carries geometry in its typed slots, with no
        # `extras.geojson` layer.
        @test doc.bus.a.geo.coordinates == [-83.72, 42.3]
        @test doc.line.ab.geo.coordinates[2] == [-83.68, 42.36]
        @test !haskey(doc, :extras) || !haskey(doc.extras, :geojson)
        again = parse(IOBuffer(written.text); format="bmopf-json", name="edited.bmopf.json")
        @test again.value.buses[1].location.x == -83.72
        @test again.value.lines[1].route[2].y == 42.36
        dataset = get(ENV, "POWERIO_GEO_DATASET", "")
        if !isempty(dataset)
            case = parse(dataset)
            @test case isa PioModule{BalancedNetwork}
            @test length(case.value.buses) == 250
            @test all(bus -> bus.location !== nothing, case.value.buses)
            restored = deserialize(Vector{UInt8}(serialize(case).text))
            @test [(b.id, b.location.x, b.location.y) for b in restored.value.buses] ==
                  [(b.id, b.location.x, b.location.y) for b in case.value.buses]
        end
    end
end
