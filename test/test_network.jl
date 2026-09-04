@testset "BalancedNetwork" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        m = parse(fixture("case9.m"))
        net = m.value

        @testset "properties" begin
            @test net.name == "case9"
            @test net.base_mva == 100.0
            @test net.base_frequency == 60.0
            @test net.geo === nothing
            @test net.detailed_connectivity === nothing
            @test propertynames(net) == (:name, :base_mva, :base_frequency, :geo, :detailed_connectivity,
                                         :buses, :branches, :generators, :loads, :shunts,
                                         :static_var_compensators, :storage, :switches, :hvdc,
                                         :transformers_3w, :areas)
            @test occursin("9 buses, 9 branches, 3 generators", sprint(show, net))
        end

        @testset "element collections" begin
            @test net.buses isa AbstractVector{Bus}
            @test length(net.buses) == 9
            @test size(net.buses) == (9,)
            @test eltype(net.buses) == Bus
            @test firstindex(net.buses) == 1
            @test net.buses[1] isa Bus
            @test net.buses[end].id == 9
            @test_throws BoundsError net.buses[10]
            @test_throws BoundsError net.buses[0]
            @test [b.id for b in net.buses] == 1:9
            @test collect(net.buses) isa Vector{Bus}
            @test count(b -> b.bus_type == "PQ", net.buses) == 6
            @test length(filter(br -> br.reactance_pu > 0.1, net.branches)) == 3
            @test sum(br.rate_a_mva for br in net.branches) == 2100.0
            @test getproperty.(net.loads, :bus_id) == [5, 7, 9]
            @test isempty(net.shunts) && isempty(net.storage) && isempty(net.hvdc)
            @test isempty(net.switches) && isempty(net.transformers_3w) && isempty(net.areas)
            @test isempty(net.static_var_compensators)
            @test occursin("9-element Elements{Bus}", summary(net.buses))
        end

        @testset "element values match the MATPOWER source" begin
            b1 = net.buses[1]
            @test b1.id == 1
            @test b1.bus_type == "REF"
            @test b1.vm_pu == 1.0 && b1.va_degrees == 0.0
            @test b1.base_kv == 345.0
            @test b1.vmax_pu == 1.1 && b1.vmin_pu == 0.9
            @test b1.emergency_vmax_pu === nothing
            @test b1.area == 1 && b1.zone == 1
            @test b1.location === nothing
            @test [b.bus_type for b in net.buses] == ["REF", "PV", "PV", "PQ", "PQ", "PQ", "PQ", "PQ", "PQ"]
            @test reference_bus_ids(net) == [1]

            br = net.branches[2]
            @test (br.from_bus_id, br.to_bus_id) == (4, 5)
            @test br.resistance_pu == 0.017
            @test br.reactance_pu == 0.092
            @test br.total_charging_susceptance_pu == 0.158
            @test br.from_susceptance_pu + br.to_susceptance_pu ≈ 0.158
            @test br.rate_a_mva == 250.0 && br.rate_b_mva == 250.0 && br.rate_c_mva == 250.0
            @test isempty(br.ratings)
            @test br.current_ratings === nothing
            @test br.tap_ratio == 0.0 && br.effective_tap_ratio == 1.0
            @test br.phase_shift_degrees == 0.0
            @test br.in_service
            @test (br.angle_min_degrees, br.angle_max_degrees) == (-360.0, 360.0)
            @test br.control === nothing && br.route === nothing

            g = net.generators[1]
            @test g.bus_id == 1
            @test g.active_power_mw == 72.3 && g.reactive_power_mvar == 27.03
            @test g.active_power_max_mw == 250.0 && g.active_power_min_mw == 10.0
            @test g.reactive_power_max_mvar == 300.0 && g.reactive_power_min_mvar == -300.0
            @test g.voltage_setpoint_pu == 1.04
            @test g.machine_base_mva == 100.0
            @test g.in_service
            @test g.cost isa GeneratorCost
            @test g.cost.model == 2 && g.cost.startup == 1500.0 && g.cost.ncost == 3
            @test g.cost.coefficients == [0.11, 5.0, 150.0]
            @test g.regulated_bus_id === nothing
            @test [c.name for c in g.capabilities] == ["pc1", "pc2", "qc1min", "qc1max", "qc2min", "qc2max",
                                                        "ramp_agc", "ramp_10", "ramp_30", "ramp_q", "apf"]

            l = net.loads[1]
            @test l.bus_id == 5 && l.p_mw == 90.0 && l.q_mvar == 30.0 && l.in_service
            @test l.voltage_model.kind == "constant_power"
            @test l.voltage_model.p_constant_power_mw == 90.0
        end

        @testset "to_dense and to_graph" begin
            d = to_dense(net)
            @test (d.n, d.m, d.ng, d.ns) == (9, 9, 3, 0)
            @test d.base_mva == 100.0
            @test d.bus_ids == 1:9
            @test d.branch.from == [1, 4, 5, 3, 6, 7, 8, 8, 9]
            @test d.branch.x[1] == 0.0576
            @test d.branch.b[2] == 0.158
            @test d.branch.b_fr[2] + d.branch.b_to[2] ≈ 0.158
            @test all(d.branch.in_service)
            @test d.gen.pg == [72.3, 163.0, 85.0]
            @test d.demand.pd == [0, 0, 0, 0, 90, 0, 100, 0, 125]
            @test d.demand.qd[9] == 50.0
            @test d.shunt.gs == zeros(9) && d.shunt.bs == zeros(9)
            @test d.reference_bus == 1
            @test isempty(d.switch.from)
            @test to_dense(m) == d

            g = to_graph(net)
            @test length(g.buses) == 9
            @test g.buses[1] == (; id = 1, index = 1, kind = "REF", name = "")
            @test length(g.edges) == 9
            @test g.edges[1] == (; kind = "branch", index = 1, from = 1, to = 4)
            @test to_graph(m) == g
        end

        @testset "PSS/E three winding transformers" begin
            raw = parse(fixture("psse", "case3_3w_v33.raw")).value
            @test raw.name == "case3_3w"
            @test length(raw.transformers_3w) == 1
            t = raw.transformers_3w[1]
            @test t isa ThreeWindingTransformer
            @test t.component_id == "1-2-3"
            @test t.name == "T3W"
            @test [w.bus_id for w in t.windings] == [1, 2, 3]
            @test [w.tap_ratio for w in t.windings] == [1.0, 1.025, 0.95]
            @test t.windings[3].phase_shift_degrees == 30.0
            @test [w.nominal_voltage_kv for w in t.windings] == [230.0, 138.0, 13.8]
            @test length(t.impedances) == 3
            @test t.impedances[1] == TransformerImpedance(0.01, 0.1, 100.0)
            @test t.star_voltage_magnitude_pu == 0.98
            @test t.star_voltage_angle_degrees == -1.5
            @test t.in_service
            @test length(raw.areas) == 1
            @test raw.areas[1].number == 1
            @test raw.areas[1].area_type == "ControlArea"
            @test raw.areas[1].slack_bus_id === nothing
        end

        @testset "network handles outlive the module" begin
            net2 = parse(fixture("case9.m")).value
            GC.gc()
            @test length(net2.buses) == 9
            @test net2.buses[5].id == 5
        end
    end
end
