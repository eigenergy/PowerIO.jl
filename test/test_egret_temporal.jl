@testset "Egret electrical time series" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        text = """
        {"system":{"baseMVA":100,"time_keys":["morning","evening"],"time_period_length_minutes":15},
         "elements":{"bus":{"7":{"matpower_bustype":"ref"},"43":{}},
           "load":{"load_1":{"bus":"43","p_load":{"data_type":"time_series","values":[10,20]}}},
           "branch":{"1":{"from_bus":"7","to_bus":"43","reactance":0.1,
             "pf":{"data_type":"time_series","values":[10,-3]},"qf":-2,"pt":-9.8,"qt":2.2}}}}
        """
        original = parse(IOBuffer(text); format="egret-json")
        @test original isa PioModule{TimeSeries{BalancedNetwork}}
        @test emit(original, "egret-json").text == text
        restored = deserialize(IOBuffer(serialize(original).text))
        result = emit(restored, "egret-json")
        native = JSON3.read(result.text)
        @test native.system.time_keys == ["morning", "evening"]
        @test native.system.time_period_length_minutes == 15
        @test native.elements.branch[Symbol("1")].pf.values == [10, -3]
        series = parse(IOBuffer(result.text); format="egret-json").value
        @test [point.label for point in time_points(series)] == ["morning", "evening"]
        @test [point.duration_seconds for point in time_points(series)] == [900, 900]
        @test series[2].loads[1].p_mw == 20
        original = restored = nothing
        GC.gc()
        @test time_points(series)[2].label == "evening"
        @test series[1].loads[1].p_mw == 10
        unstated = parse(IOBuffer(replace(text, ",\"time_period_length_minutes\":15" => "")); format="egret-json").value
        @test all(point -> isnothing(point.duration_seconds), time_points(unstated))
    end
end
