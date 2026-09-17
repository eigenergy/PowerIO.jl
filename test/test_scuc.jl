@testset "AC SCUC instance inputs" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        m = parse(fixture("goc3", "goc3_small.json"))
        @test m isa PioModule{AcScucInstance}
        instance = m.value
        @test propertynames(instance) == (:network, :inputs)
        inputs = instance.inputs
        @test inputs isa ScucInputs

        @testset "dimensions and instance wide costs" begin
            @test inputs.dimensions == (period_count=2, device_count=2, producer_count=1,
                                        consumer_count=1, shunt_count=1,
                                        branch_switching_cost_count=3,
                                        transformer_control_count=1,
                                        active_reserve_zone_count=1,
                                        reactive_reserve_zone_count=1, contingency_count=3)
            @test inputs.interval_durations == [1.0, 1.0]
            @test inputs.violation_costs == ScucViolationCosts(1.0, 1.0, 1.0, 1.0)
            @test occursin("2 devices over 2 intervals", sprint(show, inputs))
        end

        @testset "devices" begin
            @test length(inputs.devices) == 2
            producer = inputs.devices[1]
            @test producer isa ScucDevice
            @test producer.id == ComponentId("generator", "sd_00")
            @test producer.kind == "producer"
            @test producer.initial_on_status
            @test producer.on_cost == 1.0
            @test producer.startup_cost == 2.0
            @test producer.shutdown_cost == 3.0
            @test producer.minimum_up_time_hours == 1.0
            @test producer.minimum_down_time_hours == 1.0
            @test producer.ramp_limits == ScucRampLimits(1.0, 1.0, 1.0, 1.0)
            @test producer.reserve_limits.synchronized_pu == 0.0
            @test producer.initial_commitment == ScucInitialCommitment(4.0, 0.0)

            # This fixture states no startup cost tiers, so the table is empty.
            @test producer.startup_cost_adjustments == ScucStartupCostAdjustment[]
            @test producer.startup_limits == [ScucStartupLimit(0.0, 2.0, 1)]
            @test producer.startup_limits[1].maximum_startups isa Int
            @test producer.energy_upper_bounds == [ScucEnergyRequirement(0.0, 2.0, 9.0)]
            @test producer.energy_lower_bounds == [ScucEnergyRequirement(0.0, 2.0, 1.0)]

            consumer = inputs.devices[2]
            @test consumer.id == ComponentId("load", "sd_01")
            @test consumer.kind == "consumer"
        end

        @testset "a device without reactive coupling states no bound" begin
            capability = inputs.devices[1].reactive_capability
            @test capability isa ScucReactiveCapability
            @test capability.kind == "none"
            @test capability.reactive_power_at_zero_active_power_pu === nothing
            @test capability.reactive_power_at_zero_active_power_min_pu === nothing
            @test capability.reactive_power_at_zero_active_power_max_pu === nothing
            @test capability.slope === nothing
            @test capability.slope_min === nothing
            @test capability.slope_max === nothing
        end

        @testset "device periods" begin
            periods = inputs.devices[1].periods
            @test length(periods) == 2
            @test periods[1] isa ScucDevicePeriod
            @test periods[1].on_status_min && periods[1].on_status_max
            @test !periods[2].on_status_min && periods[2].on_status_max
            @test periods[1].active_power_min_pu == 2.0
            @test periods[1].active_power_max_pu == 5.0
            @test periods[1].reactive_power_min_pu == -1.0
            @test periods[1].reactive_power_max_pu == 1.0
            @test periods[1].energy_cost_blocks == [ScucEnergyCostBlock(10.0, 5.0)]
            @test periods[2].energy_cost_blocks == [ScucEnergyCostBlock(11.0, 6.0)]
            @test periods[1].reserve_costs isa ScucReserveCosts
            @test periods[1].reserve_costs == ScucReserveCosts(0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                                                              0.0, 0.0, 0.0, 0.0)
        end

        @testset "shunts, switching costs, and transformer controls" begin
            @test length(inputs.shunts) == 1
            shunt = inputs.shunts[1]
            @test shunt isa ScucShunt
            @test shunt.id == ComponentId("shunt", "sh_00")
            @test shunt.conductance_per_step_pu == 0.0
            @test shunt.susceptance_per_step_pu == 3.0
            @test (shunt.step_min, shunt.initial_step, shunt.step_max) == (0, 1, 4)

            @test length(inputs.branch_switching_costs) == 3
            @test inputs.branch_switching_costs[1] isa ScucBranchSwitchingCost
            @test [c.id for c in inputs.branch_switching_costs] ==
                  [ComponentId("branch", "acl_00"), ComponentId("branch", "acl_01"),
                   ComponentId("transformer", "xf_00")]
            @test inputs.branch_switching_costs[1].connection_cost == 0.0
            @test inputs.branch_switching_costs[1].disconnection_cost == 0.0

            @test length(inputs.transformer_controls) == 1
            control = inputs.transformer_controls[1]
            @test control isa ScucTransformerControl
            @test control.id == ComponentId("transformer", "xf_00")
            @test (control.tap_ratio_min, control.tap_ratio_max) == (1.0, 1.0)
            @test (control.phase_shift_min_radians, control.phase_shift_max_radians) == (0.0, 0.0)
        end

        @testset "reserve zones" begin
            @test length(inputs.active_reserve_zones) == 1
            zone = inputs.active_reserve_zones[1]
            @test zone isa ScucActiveReserveZone
            @test zone.id == ComponentId("active_reserve_zone", "azr_00")
            @test zone.buses == [ComponentId("bus", "bus_00"), ComponentId("bus", "bus_01")]
            @test zone.regulation_up_requirement_fraction == 1.0
            @test zone.nonsynchronized_requirement_fraction == 1.0
            @test zone.ramping_up_violation_cost == 1.0
            @test zone.ramping_up_requirement_pu == [0.0, 0.0]
            @test zone.ramping_down_requirement_pu == [0.0, 0.0]

            @test length(inputs.reactive_reserve_zones) == 1
            reactive = inputs.reactive_reserve_zones[1]
            @test reactive isa ScucReactiveReserveZone
            @test reactive.id == ComponentId("reactive_reserve_zone", "rzr_00")
            @test reactive.buses == [ComponentId("bus", "bus_00"), ComponentId("bus", "bus_01")]
            @test reactive.reactive_up_violation_cost == 1.0
            @test reactive.reactive_down_violation_cost == 1.0
            @test reactive.reactive_up_requirement_pu == [0.0, 0.0]
            @test reactive.reactive_down_requirement_pu == [0.0, 0.0]
        end

        @testset "contingencies" begin
            @test length(inputs.contingencies) == 3
            @test inputs.contingencies[1] isa ScucContingency
            @test inputs.contingencies[1].id == ComponentId("contingency", "ctg_00")
            @test inputs.contingencies[1].components == [ComponentId("branch", "acl_00")]
            @test [c.id.local_id for c in inputs.contingencies] == ["ctg_00", "ctg_01", "ctg_02"]
            # A `Dict` over the table covers a lookup by source identity.
            by_uid = Dict(c.id.local_id => c for c in inputs.contingencies)
            @test by_uid["ctg_02"].components == [ComponentId("transformer", "xf_00")]
        end

        @testset "the inputs of the instance a solution answers" begin
            solution = parse(fixture("goc3")).value
            @test solution isa AcScucSolution
            other = solution.instance.inputs
            @test other isa ScucInputs
            @test other.dimensions == inputs.dimensions
            @test other.interval_durations == inputs.interval_durations
            @test other.violation_costs == inputs.violation_costs
            @test [d.id for d in other.devices] == [d.id for d in inputs.devices]
            @test other.devices[1].startup_cost == inputs.devices[1].startup_cost
            @test other.devices[1].initial_commitment == inputs.devices[1].initial_commitment
            @test [p.energy_cost_blocks for p in other.devices[1].periods] ==
                  [p.energy_cost_blocks for p in inputs.devices[1].periods]
            @test other.active_reserve_zones[1].buses == inputs.active_reserve_zones[1].buses
            @test [c.id => c.components for c in other.contingencies] ==
                  [c.id => c.components for c in inputs.contingencies]
        end

        @testset "only an AC SCUC instance carries inputs" begin
            dc = to_dc_opf_instance(parse(fixture("case9.m"))).value
            @test propertynames(dc) == (:network,)
            @test dc.network isa BalancedNetwork
            # `inputs` is not a field of another instance type, so reading it fails.
            @test_throws Exception dc.inputs
        end
    end
end
