@testset "collections, instances, and solutions" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        @testset "TimeSeries" begin
            m = parse(fixture("pypsa", "series"))
            @test m isa PioModule{TimeSeries{BalancedNetwork}}
            series = m.value
            @test length(series) == 2
            @test size(series) == (2,)
            @test eltype(series) == BalancedNetwork
            @test firstindex(series) == 1 && lastindex(series) == 2
            @test series[1] isa BalancedNetwork
            @test [net.loads[1].p_mw for net in series] == [10.0, 20.0]
            @test series[2].loads[1].p_mw == 20.0
            @test length(series[1].buses) == 2
            @test_throws BoundsError series[0]
            @test_throws BoundsError series[3]
            @test collect(series) isa Vector{BalancedNetwork}
            @test occursin("TimeSeries{BalancedNetwork} with 2 values", sprint(show, series))
        end

        @testset "ScenarioSet" begin
            m = try
                parse(fixture("case14_gridfm_batch", "raw"))
            catch e
                e isa PowerIOError && occursin("gridfm", e.message) ? nothing : rethrow()
            end
            if m === nothing
                @test_skip "this libpowerio_capi was built without the gridfm feature"
            else
                @test m isa PioModule{ScenarioSet{BalancedNetwork}}
                scenarios = m.value
                @test length(scenarios) == 2
                @test keys(scenarios) == ["0", "1"]
                @test eltype(scenarios) == Pair{String,BalancedNetwork}
                @test haskey(scenarios, "0") && !haskey(scenarios, "missing")
                @test scenarios["0"] isa BalancedNetwork
                @test length(scenarios["1"].buses) == 14
                @test_throws KeyError scenarios["missing"]
                @test get(scenarios, "missing", nothing) === nothing
                @test [id for (id, _) in scenarios] == ["0", "1"]
                @test all(v -> v isa BalancedNetwork, values(scenarios))
                @test length(values(scenarios)) == 2
                @test occursin("ScenarioSet{BalancedNetwork} with 2 scenarios", sprint(show, scenarios))
            end
        end

        @testset "AcScucSolution from a GO Challenge 3 directory" begin
            m = parse(fixture("goc3"))
            @test m isa PioModule{AcScucSolution}
            solution = m.value
            @test propertynames(solution) == (:instance, :termination, :objective)
            @test solution.instance isa AcScucInstance
            @test solution.instance.network isa BalancedNetwork
            @test solution.instance.network.name == "goc3"
            @test length(solution.instance.network.buses) == 2
            @test solution.termination == "not_reported"
            @test solution.objective === nothing
            @test time_count(solution) == 2
            @test solution["bus_voltage_magnitude", 1] == [1.0, 0.99]
            @test length(solution["bus_voltage_magnitude", 2]) == 2
            @test_throws BoundsError solution["bus_voltage_magnitude", 3]
            @test_throws PowerIOError solution["not_a_quantity", 1]
        end

        @testset "AcOpfSolution from OPFData" begin
            m = parse(fixture("opfdataset", "example_0.json"))
            @test m isa PioModule{AcOpfSolution}
            solution = m.value
            @test solution.instance isa AcOpfInstance
            @test length(solution.instance.network.buses) == 14
            @test solution.termination == "not_reported"
            @test solution.objective isa Float64
            @test solution.objective > 0
            vm = solution["bus_voltage_magnitude"]
            @test length(vm) == 14
            @test all(0.9 .<= vm .<= 1.1)
            @test length(solution["generator_active_power"]) == 5
            e = try
                solution["not_a_quantity"]
            catch err
                err
            end
            @test e isa PowerIOError
            @test e.code == "REQUEST.CAPI.QUANTITY_UNKNOWN"
            @test occursin("AcOpfSolution(not_reported)", sprint(show, solution))
        end

        @testset "to_*_instance constructions" begin
            m = parse(fixture("case9.m"))
            dc = to_dc_opf_instance(m)
            @test dc isa PioModule{DcOpfInstance}
            @test dc.value.network isa BalancedNetwork
            @test length(dc.value.network.buses) == 9
            @test propertynames(dc.value) == (:network,)
            @test length(dc.history) == 1
            @test dc.history[1].name == "to_dc_opf_instance"
            @test dc.history[1].input_type == "powerio.BalancedNetwork"
            @test dc.history[1].output_type == "powerio.DcOpfInstance"
            @test to_dc_pf_instance(m) isa PioModule{DcPfInstance}
            @test to_ac_pf_instance(m) isa PioModule{AcPfInstance}
            @test to_ac_opf_instance(m) isa PioModule{AcOpfInstance}
            @test_throws PowerIOError to_mc_ac_pf_instance(m)

            feeder = parse(fixture("dist", "switch.dss"))
            mc = to_mc_ac_pf_instance(feeder)
            @test mc isa PioModule{McAcPfInstance}
            @test mc.value.network isa MulticonductorNetwork
            @test to_mc_ac_opf_instance(feeder) isa PioModule{McAcOpfInstance}
            @test_throws PowerIOError to_dc_pf_instance(feeder)

            # A calculation module serializes and deserializes like any other.
            back = deserialize(Vector{UInt8}(serialize(dc).text))
            @test back isa PioModule{DcOpfInstance}
            @test emit(dc, "matpower").fidelity == "canonical"
        end
    end
end
