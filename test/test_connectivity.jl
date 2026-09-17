@testset "DetailedConnectivity" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        details(name) = parse(fixture("xiidm", name * ".xiidm"); format="xiidm").value.detailed_connectivity

        @testset "tables and properties" begin
            d = details("hierarchy")
            @test d isa DetailedConnectivity
            @test propertynames(d) == (:counts, :omitted_fields, :component_metadata, :subnetworks,
                                       :substations, :voltage_levels, :bus_breaker_buses,
                                       :calculated_buses, :connectivity_nodes, :busbar_sections,
                                       :junctions, :terminals, :switches, :internal_connections,
                                       :operational_limit_groups, :tap_changers,
                                       :equipment_reactive_limits, :boundary_lines, :tie_lines,
                                       :dc_converter_units, :dc_topological_nodes, :dc_nodes,
                                       :dc_grounds, :dc_busbars, :dc_lines, :dc_series_devices,
                                       :dc_switches, :voltage_source_converters,
                                       :line_commutated_converters)
            @test keys(d.counts) == propertynames(d)[2:end]
            @test all(n -> n isa Int, values(d.counts))
            @test d.counts.substations == 1
            @test d.counts.voltage_levels == 3
            @test d.counts.terminals == 3
            @test d.counts.operational_limit_groups == 1
            @test d.counts.tap_changers == 1

            # Every table is an `Elements` vector of its record type, of the
            # length the counts view reports.
            for table in propertynames(d)[2:end]
                rows = getproperty(d, table)
                @test rows isa AbstractVector
                @test length(rows) == getfield(d.counts, table)
                @test all(row -> row isa eltype(rows), rows)
            end

            @test eltype(d.substations) == Substation
            @test eltype(d.terminals) == DetailedTerminal
            @test eltype(d.switches) == TopologySwitch
            @test eltype(d.dc_lines) == DcEquipment
            @test eltype(d.dc_nodes) == DcNode
            @test eltype(d.voltage_source_converters) == AcDcConverter
            @test occursin("3-element Elements{DetailedTerminal}", summary(d.terminals))
            @test collect(d.voltage_levels) isa Vector{VoltageLevel}
            @test [l.nominal_voltage_kv for l in d.voltage_levels] == [132.0, 33.0, 11.0]
            @test length(filter(l -> l.nominal_voltage_kv > 100, d.voltage_levels)) == 1
            @test_throws BoundsError d.substations[2]
            @test_throws BoundsError d.substations[0]
            # Julia 1.12 raises FieldError here, 1.10 an ErrorException.
            @test_throws Exception d.no_such_table
        end

        @testset "substations, voltage levels, terminals, limits, tap changers" begin
            d = details("hierarchy")

            s = d.substations[1]
            @test s.component == ComponentId("substation", "S")
            @test s.country == "US"
            @test s.operator_name == "MISO"
            @test s.geographical_tags == ["east"]

            l = d.voltage_levels[1]
            @test l.component == ComponentId("voltage_level", "VL1")
            @test l.substation == ComponentId("substation", "S")
            @test l.topology_kind == "bus_breaker"
            @test l.nominal_voltage_kv == 132.0
            @test l.low_voltage_limit_kv === nothing
            @test l.buses == [1]

            b = d.bus_breaker_buses[1]
            @test b.component == ComponentId("bus", "B1")
            @test b.voltage_level == ComponentId("voltage_level", "VL1")
            @test b.calculated_bus_id == 1
            @test b.voltage_kv === nothing

            t = d.terminals[1]
            @test t.component === nothing
            @test t.connected
            @test t.equipment == ComponentId("transformer_3w", "T3")
            @test t.terminal == 1
            @test t.bus == ComponentId("bus", "B1")
            @test t.node === nothing
            @test [x.terminal for x in d.terminals] == [1, 2, 3]

            g = d.operational_limit_groups[1]
            @test g.equipment == ComponentId("transformer_3w", "T3")
            @test g.terminal == 1
            @test g.id == "normal"
            @test g.selected
            @test g.properties == Dict{String,String}()
            @test g.current_limits === nothing
            @test g.active_power_limits === nothing
            @test g.apparent_power_limits.permanent_limit == 90.0
            @test g.apparent_power_limits.permanent_limit_name === nothing
            @test g.apparent_power_limits.temporary_limits ==
                  [TemporaryLimit("emergency", 100.0, 600, false)]

            c = d.tap_changers[1]
            @test c.component === nothing
            @test c.transformer.local_id == "T3"
            @test c.winding == 2
            @test c.kind == "ratio"
            @test c.tap_position == 0
            @test c.solved_tap_position === nothing
            @test c.low_tap_position == 0
            @test !c.load_tap_changing_capabilities
            @test !c.regulating
            @test c.regulation_terminal === nothing
            @test length(c.steps) == 1
            @test c.steps[1].position == 0
            @test c.steps[1].ratio_pu == 1.05
            @test c.steps[1].phase_shift_degrees == 0.0
            @test c.steps[1].resistance_deviation_percent == 0.0

            # The metadata table names every component the source identifies.
            @test [m.component for m in d.component_metadata if m.component.component_type == "substation"] ==
                  [ComponentId("substation", "S")]
            @test all(m -> !m.fictitious && isempty(m.aliases) && isempty(m.properties),
                      d.component_metadata)
        end

        @testset "subnetworks, boundary lines, tie lines" begin
            d = details("merged")
            @test d.counts.subnetworks == 2
            @test d.counts.boundary_lines == 2
            @test d.counts.tie_lines == 1

            s = d.subnetworks[1]
            @test s.component == ComponentId("subnetwork", "A")
            @test s.parent.local_id == "Merged"
            @test s.case_metadata.case_date == "2026-01-01T01:00:00Z"
            @test s.case_metadata.forecast_distance == 1
            @test s.case_metadata.source_model_format == "part-a"
            @test s.case_metadata.minimum_validation_level == "STEADY_STATE_HYPOTHESIS"
            @test length(s.components) >= 4
            @test ComponentId("boundary_line", "DLA") in s.components
            @test d.subnetworks[2].case_metadata.forecast_distance == 2

            b = d.boundary_lines[1]
            @test b.component.local_id == "DLA"
            @test b.voltage_level.local_id == "VA"
            @test b.active_power_setpoint_mw == 5.0
            @test b.reactive_power_setpoint_mvar == 6.0
            @test b.resistance_ohm == 1.0
            @test b.reactance_ohm == 2.0
            @test b.conductance_siemens == 0.0
            @test b.pairing_key === nothing
            @test b.generation.voltage_regulation_on
            @test b.generation.minimum_active_power_mw == 0.0
            @test b.generation.maximum_active_power_mw == 20.0
            @test b.generation.target_active_power_mw == 10.0
            @test b.generation.target_reactive_power_mvar === nothing
            @test b.generation.target_voltage_kv == 100.0
            limits = b.generation.reactive_limits
            @test limits.kind == "capability_curve"
            @test limits.minimum_reactive_power_mvar === nothing
            @test limits.properties == Dict("owner" => "RTE")
            @test length(limits.points) == 2
            @test limits.points[2].active_power_mw == 10.0
            @test limits.points[2].maximum_reactive_power_mvar == 20.0
            @test limits.points[2].properties == Dict{String,String}()

            # The second boundary line states no generation.
            @test d.boundary_lines[2].component.local_id == "DLB"
            @test d.boundary_lines[2].generation === nothing

            t = d.tie_lines[1]
            @test t.component.local_id == "TL"
            @test t.boundary_line1.local_id == "DLA"
            @test t.boundary_line2.local_id == "DLB"
            @test t.calculation_branch.component_type == "branch"
        end

        @testset "node breaker topology" begin
            d = details("nodes")
            @test d.counts.connectivity_nodes == 3
            @test sort([n.node_number for n in d.connectivity_nodes]) == [0, 1, 2]
            @test all(n -> n.calculated_bus_id == 1, d.connectivity_nodes)
            @test all(n -> n.voltage_level == ComponentId("voltage_level", "VL"), d.connectivity_nodes)

            @test length(d.calculated_buses) == 1
            cb = d.calculated_buses[1]
            @test cb.calculated_bus_id == 1
            @test cb.voltage_kv == 110.0
            @test cb.angle_degrees == 0.0
            @test length(cb.nodes) == 3

            @test length(d.busbar_sections) == 1
            @test d.busbar_sections[1].component == ComponentId("busbar_section", "BBS")
            @test d.busbar_sections[1].node.local_id == "VL/2"

            @test length(d.switches) == 1
            sw = d.switches[1]
            @test sw.component == ComponentId("switch", "BR")
            @test sw.kind == "breaker"
            @test !sw.open
            @test !sw.retained
            @test sw.endpoint1.kind == "node"
            @test sw.endpoint1.component.local_id == "VL/1"
            @test sw.endpoint2.component.local_id == "VL/2"

            @test length(d.internal_connections) == 1
            ic = d.internal_connections[1]
            @test ic.voltage_level == ComponentId("voltage_level", "VL")
            @test (ic.node1.local_id, ic.node2.local_id) == ("VL/0", "VL/1")

            rl = d.equipment_reactive_limits[1]
            @test rl.equipment == ComponentId("generator", "G")
            @test rl.limits.kind == "min_max"
            @test rl.limits.minimum_reactive_power_mvar == -2.0
            @test rl.limits.maximum_reactive_power_mvar == 2.0
            @test isempty(rl.limits.points)
            @test rl.limits.properties == Dict{String,String}()

            @test isempty(d.junctions)
            @test isempty(d.bus_breaker_buses)
        end

        @testset "omitted fields and reactive capability curves" begin
            d = details("equipment")
            @test [f.field for f in d.omitted_fields] ==
                  ["active_power", "reactive_power", "voltage_setpoint", "rated_apparent_power"]
            @test d.omitted_fields[3].component == ComponentId("generator", "G")

            rl = d.equipment_reactive_limits[1]
            @test rl.equipment == ComponentId("generator", "G")
            @test rl.limits.kind == "capability_curve"
            @test rl.limits.curve_style == "straight_line_y_values"
            @test rl.limits.properties == Dict("curve" => "retained")
            @test length(rl.limits.points) == 2
            @test rl.limits.points[1].active_power_mw == 0.0
            @test rl.limits.points[1].minimum_reactive_power_mvar == -20.0
            @test rl.limits.points[1].maximum_reactive_power_mvar == 20.0
            @test rl.limits.points[1].properties == Dict("point" => "first")
            @test rl.limits.points[2].properties == Dict{String,String}()
        end

        @testset "DC equipment and converters" begin
            d = details("dc")
            @test d.counts.dc_nodes == 2
            @test d.counts.dc_grounds == 1
            @test d.counts.dc_lines == 1
            @test d.counts.dc_switches == 1
            @test d.counts.voltage_source_converters == 1

            n = d.dc_nodes[1]
            @test n.component == ComponentId("dc_node", "N1")
            @test n.kind == "node"
            @test n.nominal_voltage_kv == 500.0
            @test n.voltage_kv == 498.0
            @test n.dc_topological_node === nothing
            @test d.dc_nodes[2].voltage_kv === nothing

            line = d.dc_lines[1]
            @test line.component == ComponentId("dc_line", "L")
            @test line.kind == "line"
            @test line.resistance_ohm == 4.0
            @test line.length_km === nothing
            @test line.open === nothing
            @test length(line.terminals) == 2
            @test line.terminals[1].dc_node == ComponentId("dc_node", "N1")
            @test line.terminals[1].connected === true
            @test line.terminals[1].active_power_mw == 100.0
            @test line.terminals[1].current_a == 200.0
            @test line.terminals[2].active_power_mw == -98.0

            ground = d.dc_grounds[1]
            @test ground.kind == "ground"
            @test ground.resistance_ohm == 0.1
            @test length(ground.terminals) == 1
            @test ground.terminals[1].connected === false

            sw = d.dc_switches[1]
            @test sw.kind == "switch"
            @test sw.switch_kind == "disconnector"
            @test sw.open === true
            @test sw.terminals[1].connected === nothing

            vsc = d.voltage_source_converters[1]
            @test vsc.component == ComponentId("voltage_source_converter", "VSC")
            @test vsc.kind == "voltage_source"
            @test vsc.control_mode == "active_power_at_pcc_and_dc_voltage_droop_curve"
            @test vsc.voltage_regulator_on === true
            @test vsc.voltage_setpoint_kv == 397.0
            @test vsc.idle_loss_mw == 2.0
            @test vsc.switching_loss_mw_per_ampere == 0.2
            @test vsc.resistive_loss_ohm == 2.0e-6
            @test vsc.target_active_power_mw == 301.0
            @test vsc.target_dc_voltage_kv == 502.0
            @test vsc.pcc_terminal == TerminalReference(ComponentId("voltage_source_converter", "VSC"), 1)
            @test vsc.dc_terminal1.dc_node == ComponentId("dc_node", "N1")
            @test vsc.dc_terminal1.connected === true
            @test vsc.dc_terminal2.connected === false
            @test vsc.droop_curve == [DroopCurveSegment(-100.0, 100.0, -5.0)]
            @test vsc.reactive_limits.kind == "capability_curve"
            @test vsc.reactive_limits.properties == Dict("curve" => "retained")
            @test length(vsc.reactive_limits.points) == 2
            @test vsc.reactive_limits.points[1].active_power_mw == -200.0
            @test vsc.reactive_limits.points[1].properties == Dict("point" => "one")
            # A line commutated converter field the source does not state.
            @test vsc.alpha_degrees === nothing
            @test vsc.operating_mode === nothing

            # These fixtures state no converter unit, no topological node, and
            # no line commutated converter.
            @test isempty(d.dc_converter_units)
            @test isempty(d.dc_topological_nodes)
            @test isempty(d.dc_busbars)
            @test isempty(d.dc_series_devices)
            @test isempty(d.line_commutated_converters)
        end

        @testset "tables outlive the module and the network" begin
            d = details("hierarchy")
            GC.gc()
            @test d.substations[1].component == ComponentId("substation", "S")
            @test length(d.terminals) == 3
            PowerIO.release!(getfield(d, :handle))
            @test_throws ErrorException d.counts
        end
    end
end
