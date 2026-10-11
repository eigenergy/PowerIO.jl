@testset "Borrowed bounded distribution load laws" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        for (model, tail, kind) in [
            (1, "vminpu=.8 vmaxpu=1.2", "bounded_zip"),
            (3, "vminpu=.95 vmaxpu=1.05", "bounded_exponential"),
            (4, "cvrwatts=.8 cvrvars=1.7 vminpu=.95 vmaxpu=1.05", "bounded_exponential"),
            (8, "zipv=[0 .5 .5 0 .3 .7 .2] vminpu=.95 vmaxpu=1.05", "bounded_zip"),
        ]
            module_ = parse(IOBuffer("New Circuit.c phases=1 bus1=b.1 basekv=.24\nNew Load.l phases=1 bus1=b.1.0 kv=.24 kw=1 kvar=.5 model=$model $tail\n");
                            format="dss", name="bounded-$model.dss")
            network = module_.value
            load = network.loads[1]
            @test_throws PowerIOError PowerIO._with_network(network) do lib, p
                PowerIO._legacy_multiconductor_load(lib, p, 0)
            end
            @test load.voltage_model == kind
            @test load.active_power_nominal_w == [1000.0]
            @test load.reactive_power_nominal_var == [500.0]
            @test load.nominal_voltage_v == [240.0]
            @test load.voltage_min_pu == (model == 1 ? .8 : .95)
            @test load.voltage_max_pu == (model == 1 ? 1.2 : 1.05)
            if model == 4
                @test load.active_power_exponent == [.8]
                @test load.reactive_power_exponent == [1.7]
            elseif model == 8
                @test load.cutoff_pu == .2
                @test load.active_power_constant_current == [.5]
                @test load.reactive_power_constant_power == [.7]
            end
            instance = to_mc_ac_pf_instance(module_).value
            prescribed = instance.loads[1]
            @test prescribed.load == "l"
            @test length(prescribed.terminals) == 2
            @test prescribed.active_power_w == [1000.0]
            @test prescribed.voltage_model.model == kind
            @test prescribed.voltage_model.voltage_min_pu == load.voltage_min_pu
            @test_throws BoundsError instance.loads[2]
            module_ = nothing
            GC.gc()
            @test network.loads[1].voltage_model == kind
            old = MulticonductorLoad((getfield(load, f) for f in fieldnames(MulticonductorLoad)[1:16])...)
            @test old.voltage_min_pu === nothing
        end
    end
end

@testset "Ordinary load legacy-view compatibility" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        module_ = parse(IOBuffer("New Circuit.c phases=1 bus1=b.1 basekv=.24
New Load.l phases=1 bus1=b.1.0 kv=.24 kw=1 kvar=.5 model=2
");
                        format="dss", name="ordinary-load.dss")
        network = module_.value
        modern = network.loads[1]
        legacy = PowerIO._with_network(network) do lib, p
            PowerIO._legacy_multiconductor_load(lib, p, 0)
        end
        for field in fieldnames(MulticonductorLoad)
            @test getfield(modern, field) == getfield(legacy, field)
        end
        module_ = nothing
        GC.gc()
        @test legacy.name == "l"
        @test legacy.nominal_voltage_v == [240.0]
        @test legacy.voltage_min_pu === nothing
    end
end
