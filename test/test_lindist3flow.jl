@testset "LinDist3Flow typed values" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        module_value = deserialize(fixture("dist", "lindist3flow-solution.pio.json"))
        @test module_value isa PioModule{LinDist3FlowOpfSolution}
        solution = module_value.value
        instance = solution.instance
        @test instance isa LinDist3FlowOpfInstance
        @test instance.network isa MulticonductorNetwork
        @test solution.termination == "converged"
        @test solution.objective == 1.0
        @test solution["line_active_power"] == [1000.0]
        @test solution["generator_active_power"] == Float64[]
        @test_throws PowerIOError solution["missing"]
        values = solution["line_active_power"]
        values[1] = 0.0
        @test solution["line_active_power"] == [1000.0]
        PowerIO.release!(getfield(module_value, :handle))
        PowerIO.release!(getfield(solution, :handle))
        GC.gc()
        metadata = instance.metadata
        @test Set(metadata.nodes) == Set([("source", "a"), ("load", "a")])
        @test metadata.roots == [("source", "a")]
        @test metadata.reference_voltages == [(230.0, 0.0), (230.0, 0.0)]
        conductor = only(metadata.conductors)
        @test conductor.parent == ("source", "a")
        @test conductor.child == ("load", "a")
        @test conductor.reversed
        @test conductor.source_line_row == conductor.conductor_position == 1
        @test length(instance.network.buses) == 2
        PowerIO.release!(getfield(instance, :handle))
        GC.gc()
        @test conductor.parent == ("source", "a")

        document = JSON3.read(read(fixture("dist", "lindist3flow-solution.pio.json")), Dict{String,Any})
        network = document["value"]["data"]["instance"]["base"]["network"]
        document["version"] = 2
        document["value"] = Dict("type" => "powerio.MulticonductorNetwork", "data" => network)
        network_module = deserialize(Vector{UInt8}(JSON3.write(document)))
        constructed = to_lindist3flow_opf_instance(network_module)
        @test constructed isa PioModule{LinDist3FlowOpfInstance}
        @test constructed.value.metadata.roots == [("source", "a")]
        @test JSON3.read(serialize(constructed).text).version == 2
        document = JSON3.read(serialize(constructed).text, Dict{String,Any})
        @test deserialize(Vector{UInt8}(JSON3.write(document))) isa PioModule{LinDist3FlowOpfInstance}
        document["version"] = 3
        @test_throws PowerIOError deserialize(Vector{UInt8}(JSON3.write(document)))
    end
end
