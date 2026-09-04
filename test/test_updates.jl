@testset "typed updates" begin
    @testset "quantities" begin
        @test ActivePower(megawatts=42.0) == ActivePower(megawatts=42)
        @test ActivePower(watts=1e6).unit == :watts
        @test ActivePower(megawatts=1.0).value == 1.0
        @test_throws ArgumentError ActivePower()
        @test_throws ArgumentError ActivePower(watts=1.0, megawatts=1.0)
        @test ReactivePower(megavars=3.0).unit == :megavars
        @test ReactivePower(vars=3.0).unit == :vars
        @test_throws ArgumentError ReactivePower()
        @test ApparentPower(megavolt_amperes=250.0).unit == :megavolt_amperes
        @test ApparentPower(volt_amperes=250.0).unit == :volt_amperes
        @test_throws ArgumentError ApparentPower()
        @test occursin("megawatts=42.0", sprint(show, ActivePower(megawatts=42.0)))
        @test ComponentId("load", "bus-5") == ComponentId("load", "bus-5")
        @test ComponentId("load", "bus-5") != ComponentId("generator", "bus-5")
    end

    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        @testset "operating point update refreshes the module value" begin
            m = parse(fixture("case9.m"))
            before = m.value
            @test before.loads[1].p_mw == 90.0
            update = set_load_active_power(ComponentId("load", "bus-5"), ActivePower(watts=91_500_000.0))
            @test update isa OperatingPointUpdate
            @test occursin("load bus-5", sprint(show, update))

            report = apply_updates!(m, [update])
            @test report isa UpdateReport
            @test length(report) == 1
            @test report[1] === report.changes[1]
            @test !report.connectivity_changed
            @test report.changes[1].component_id == ComponentId("load", "bus-5")
            @test report.changes[1].field == "load_active_power"
            @test report.changes[1].terminal === nothing
            @test collect(report) == report.changes
            @test m.value.loads[1].p_mw == 91.5
            # The value borrowed before the update keeps the pre-update data.
            @test before.loads[1].p_mw == 90.0
            @test emit(m, "matpower").fidelity == "canonical"
        end

        @testset "network update" begin
            m = parse(fixture("case9.m"))
            update = set_branch_thermal_rating(ComponentId("branch", "1-4"), ApparentPower(megavolt_amperes=333.0))
            @test update isa NetworkUpdate
            report = apply_updates!(m, [update])
            @test [c.field for c in report.changes] == ["branch_thermal_rating"]
            @test !report.connectivity_changed
            @test m.value.branches[1].rate_a_mva == 333.0
        end

        @testset "a failed batch leaves the module unchanged" begin
            m = parse(fixture("case9.m"))
            valid = set_load_active_power(ComponentId("load", "bus-5"), ActivePower(megawatts=91.5))
            invalid = set_load_active_power(ComponentId("load", "missing"), ActivePower(megawatts=1.0))
            e = try
                apply_updates!(m, [valid, invalid])
            catch err
                err
            end
            @test e isa PowerIOError
            @test e.code == "VALIDATE.UPDATE.COMPONENT_UNKNOWN"
            @test m.value.loads[1].p_mw == 90.0
            @test_throws ArgumentError apply_updates!(m, [Dict("load" => "bus-5")])
            @test m.value.loads[1].p_mw == 90.0
        end

        @testset "service changes report connectivity" begin
            m = parse(fixture("case9.m"))
            report = apply_updates!(m, [set_branch_in_service(ComponentId("branch", "1-4"), false)])
            @test report.connectivity_changed
            @test report.changes[1].field == "branch_in_service"
            @test !m.value.branches[1].in_service
            report = apply_updates!(m, [set_generator_in_service(ComponentId("generator", "bus-2"), false),
                                        set_generator_voltage_magnitude(ComponentId("generator", "bus-1"), 1.05)])
            @test length(report) == 2
            @test !m.value.generators[2].in_service
            @test m.value.generators[1].voltage_setpoint_pu == 1.05
        end

        @testset "every constructor builds an update" begin
            id = ComponentId("branch", "1-4")
            @test set_load_reactive_power(ComponentId("load", "bus-5"), ReactivePower(megavars=1.0)) isa OperatingPointUpdate
            @test set_generator_active_power(ComponentId("generator", "bus-1"), ActivePower(megawatts=1.0)) isa OperatingPointUpdate
            @test set_generator_reactive_power(ComponentId("generator", "bus-1"), ReactivePower(megavars=1.0)) isa OperatingPointUpdate
            @test set_transformer_tap_ratio(id, 1.02) isa OperatingPointUpdate
            @test set_transformer_phase_shift_degrees(id, 3.0) isa OperatingPointUpdate
            @test set_switch_closed(ComponentId("switch", "s1"), true) isa OperatingPointUpdate
            @test set_branch_thermal_rating(id, ApparentPower(volt_amperes=1e8); terminal="1") isa NetworkUpdate
        end
    end
end
