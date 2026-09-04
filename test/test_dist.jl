@testset "MulticonductorNetwork" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        m = parse(fixture("dist", "switch.dss"))
        net = m.value
        @test m isa PioModule{MulticonductorNetwork}

        @testset "properties" begin
            @test net.name == "switch_case"
            @test net.source_format == "dss"
            @test net.base_frequency == 60.0
            @test net.geo === nothing
            @test propertynames(net) == (:name, :base_frequency, :source_format, :geo,
                                         :buses, :line_codes, :lines, :switches, :transformers, :loads,
                                         :generators, :ibrs, :control_profiles, :shunts, :capacitors,
                                         :voltage_sources, :untyped_objects, :commands, :options)
            @test occursin("4 buses, 1 lines", sprint(show, net))
        end

        @testset "tables" begin
            @test net.buses isa AbstractVector{MulticonductorBus}
            @test [b.id for b in net.buses] == ["sourcebus", "mid", "loadbus", "stub"]
            @test net.buses[1].terminals == ["1", "2", "3", "4"]
            @test net.buses[2].terminals == ["1", "2", "3"]

            @test length(net.line_codes) == 1
            lc = net.line_codes[1]
            @test lc.name == "lc3"
            @test lc.conductor_count == 3
            @test size(lc.resistance) == (3, 3)
            @test lc.resistance[1, 1] == 0.00031
            @test lc.resistance == lc.resistance'
            @test size(lc.reactance) == (3, 3)
            @test lc.susceptance_from == lc.susceptance_to
            @test lc.current_limit_a == [600.0, 600.0, 600.0]
            @test lc.apparent_power_limit_va === nothing

            @test length(net.lines) == 1
            line = net.lines[1]
            @test line.name == "feeder"
            @test (line.bus_from, line.bus_to) == ("sourcebus", "mid")
            @test line.terminals_from == ["1", "2", "3"]
            @test line.line_code == "lc3"
            @test line.length_m == 1200.0
            @test line.route === nothing

            @test [s.name for s in net.switches] == ["sw_closed", "sw_open"]
            @test [s.open for s in net.switches] == [false, true]
            @test net.switches[2].bus_to == "stub"

            @test isempty(net.transformers)
            @test length(net.loads) == 1
            load = net.loads[1]
            @test load.name == "l1" && load.bus == "loadbus"
            @test load.terminals == ["1", "2", "3", "4"]   # three phases and the neutral
            @test length(load.active_power_nominal_w) == 3  # one entry per phase
            @test sum(load.active_power_nominal_w) == 500_000.0

            @test length(net.voltage_sources) == 1
            vs = net.voltage_sources[1]
            @test vs.bus == "sourcebus"
            @test length(vs.voltage_magnitude_v) == 4
            @test vs.voltage_magnitude_v[1] ≈ 12470 / sqrt(3)
            @test vs.voltage_angle_rad[2] ≈ -2pi / 3

            @test Dict(net.options) == Dict("defaultbasefrequency" => "60", "voltagebases" => "12.47")
            @test [c.verb for c in net.commands] == ["calcvoltagebases", "solve"]
            @test isempty(net.untyped_objects)
            @test isempty(net.generators) && isempty(net.ibrs) && isempty(net.control_profiles)
            @test isempty(net.shunts) && isempty(net.capacitors)
        end

        @testset "generators" begin
            gen_net = parse(fixture("dist", "generator.dss")).value
            @test length(gen_net.generators) == 1
            g = gen_net.generators[1]
            @test g.name == "g1"
            @test g.configuration == "single_phase"
            @test g.active_power_nominal_w == [10_000.0]
            @test g.reactive_power_nominal_var == [2_000.0]
            @test g.active_power_min_w === nothing
        end

        @testset "to_graph" begin
            g = to_graph(net)
            @test [b.id for b in g.buses] == ["sourcebus", "mid", "loadbus", "stub"]
            @test g.edges == [(kind = "line", index = 1, from = "sourcebus", to = "mid"),
                              (kind = "switch", index = 1, from = "mid", to = "loadbus")]
            @test to_graph(m) == g
        end

        @testset "emit" begin
            same = emit(m, "dss")
            @test same.fidelity == "exact_same_format"
            @test same.text == read(fixture("dist", "switch.dss"), String)
            pmd = emit(m, "pmd")
            @test pmd.fidelity == "canonical"
            @test occursin("bus", pmd.text)
            bmopf = emit(m, "bmopf")
            @test bmopf.fidelity == "canonical"
            @test JSON3.read(bmopf.text) isa JSON3.Object
            back = deserialize(Vector{UInt8}(serialize(m).text))
            @test back isa PioModule{MulticonductorNetwork}
            @test [b.id for b in back.value.buses] == [b.id for b in net.buses]
        end
    end
end
