# Synthetic solutions deliberately are not AC feasibility certificates. They
# exercise the typed transport, ownership and fixed-topology correspondence.
function _ots_ac_result(fixed::PioModule{AcOpfInstance}; objective=40.0)
    doc = JSON3.read(serialize(fixed).text, Dict{String,Any})
    net = fixed.value.network
    nb, nl, ng = length(net.buses), length(net.branches), length(net.generators)
    data = Dict{String,Any}(
        "instance" => doc["value"]["data"], "termination" => Dict("kind" => "not_reported"),
        "residuals" => Dict("max_active_power_mismatch" => nothing, "max_reactive_power_mismatch" => nothing),
        "bus_voltage_magnitude" => fill(1.01, nb), "bus_voltage_angle" => zeros(nb),
        "bus_active_injection" => zeros(nb), "bus_reactive_injection" => zeros(nb),
        "branch_from_active_flow" => zeros(nl), "branch_to_active_flow" => zeros(nl),
        "branch_from_reactive_flow" => zeros(nl), "branch_to_reactive_flow" => zeros(nl),
        "generator_active_power" => fill(12.0, ng), "generator_reactive_power" => fill(3.0, ng),
        "three_winding_transformer_terminal_powers" => Any[], "objective" => objective)
    doc["value"] = Dict("type" => "powerio.AcOpfSolution", "data" => data)
    deserialize(Vector{UInt8}(codeunits(JSON3.write(doc)))), data
end

@testset "typed AC optimal transmission switching" begin
    @test BranchSelection(:none).select === :none
    @test BranchSelection(["line"]).identities == ["line"]
    @test_throws ArgumentError BranchSelection(:invalid)
    @test_throws ArgumentError BranchSelection(:all, ["line"])
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        network = parse(fixture("case9.m"))
        initial_id = network.value.branches[2].component_id
        @test initial_id !== nothing
        apply_updates!(network, [set_branch_in_service(ComponentId("branch", initial_id), false)])
        defaults = to_ac_ots_instance(network)
        @test defaults isa PioModule{AcOtsInstance}
        @test length(defaults.value.network.branches) == 9
        @test defaults.value.initial_closed == [i != 2 for i in 1:9]
        @test defaults.value.switchable_mask == defaults.value.initial_closed
        @test defaults.value.options.switchable.select === :only
        @test to_ac_ots_instance(defaults).value.branch_order == defaults.value.branch_order
        @test_throws PowerIOError validate_topology(defaults.value, trues(9))

        ids = defaults.value.branch_order
        options = AcOtsOptions(switchable=BranchSelection(:all), max_open=1, max_switched=2,
            switching_costs=[BranchSwitchingCost(ids[2], 4.0, 7.0), BranchSwitchingCost(ids[3], 2.0, 5.0)],
            current_limits=:stated, stated_current_limits=[BranchCurrentLimit(ids[2], 1.25, nothing)])
        m = to_ac_ots_instance(network; options)
        instance = m.value
        @test instance.options.max_open == 1
        @test instance.options.max_switched == 2
        @test instance.options.current_limits === :stated
        @test instance.options.islanding === :forbidden
        @test instance.options.switchable.select === :all
        @test all(instance.switchable_mask)
        @test instance.branches[2].current.from_pu == 1.25
        @test instance.branches[2].current.to_pu === nothing
        @test instance.branches[2].cost.close_cost == 7.0
        @test_throws BoundsError instance.branches[0]
        @test_throws BoundsError instance.branches[10]
        @test_throws PowerIOError switching_cost(instance, Bool[true])
        closed = trues(9); closed[3] = false
        @test switching_cost(instance, closed) == 9.0
        @test validate_topology(instance, closed) === nothing
        @test_throws PowerIOError validate_topology(instance, falses(9))
        @test_throws PowerIOError to_ac_ots_instance(defaults; options=AcOtsOptions(switchable=BranchSelection([ids[1], ids[1]])))
        @test_throws PowerIOError to_ac_ots_instance(defaults; options=AcOtsOptions(switchable=BranchSelection(["missing"])))
        @test_throws ArgumentError to_ac_ots_instance(defaults; options=AcOtsOptions(max_open=-1))
        @test_throws ArgumentError to_ac_ots_instance(defaults; options=AcOtsOptions(current_limits=:unknown))

        # Explicit typed base construction preserves the base objective (without
        # silently adding a switching term) and copies all caller-owned options.
        base = to_ac_opf_instance(network).value
        explicit = AcOtsInstance(base, options)
        @test explicit isa AcOtsInstance
        @test explicit.options.switching_costs[1].id == ids[2]
        derived = AcOtsInstance(base, AcOtsOptions(current_limits=:derive_from_rate_a))
        @test derived.branches[1].current.from_pu > 0
        @test derived.branches[1].current.to_pu > 0
        only = AcOtsInstance(base, AcOtsOptions(switchable=BranchSelection([ids[2]]), max_switched=1))
        @test only.switchable_mask == [i == 2 for i in 1:9]

        roundtrip = deserialize(Vector{UInt8}(codeunits(serialize(m).text)))
        @test roundtrip isa PioModule{AcOtsInstance}
        @test roundtrip.value.branch_order == ids
        @test roundtrip.value.initial_closed == instance.initial_closed
        fixed = fix_topology(instance, closed)
        @test fixed isa PioModule{AcOpfInstance}
        @test length(fixed.value.network.branches) == 9
        @test [b.in_service for b in fixed.value.network.branches] == closed
        @test !isempty(fixed.diagnostics)
        ac_module, ac_data = _ots_ac_result(fixed)
        solution = AcOtsSolution(instance, closed, ac_module.value)
        @test solution isa AcOtsSolution
        @test solution.branch_closed == closed
        @test solution.branches_open == 1
        @test solution.branches_switched == 2
        @test solution.switching_cost == 9.0
        @test solution.objective == 49.0
        @test solution.termination == "not_reported"
        @test solution.instance isa AcOtsInstance
        @test solution.instance.options.max_switched == 2
        @test !solution.network.branches[2].in_service
        @test solution.network.branches[3].in_service
        @test solution["bus_voltage_magnitude"] == fill(1.01, 9)
        @test solution["generator_active_power"] == fill(12.0, 3)
        @test_throws PowerIOError AcOtsSolution(instance, trues(9), ac_module.value)
        @test_throws PowerIOError solution["not_a_quantity"]
        materialized = materialize_ac_ots_solution(solution)
        @test materialized isa PioModule{BalancedNetwork}
        @test [b.in_service for b in materialized.value.branches] == closed
        @test parse(Vector{UInt8}(codeunits(emit(materialized, "matpower").text)); format="matpower").value.branches[3].in_service == false

        # IR loading validates the exact nested fixed-topology solution.
        document = JSON3.read(serialize(m).text, Dict{String,Any})
        document["value"] = Dict("type" => "powerio.AcOtsSolution", "data" => Dict(
            "instance" => document["value"]["data"], "branch_closed" => collect(closed), "ac_solution" => ac_data))
        restored_module = deserialize(Vector{UInt8}(codeunits(JSON3.write(document))))
        @test restored_module isa PioModule{AcOtsSolution}
        @test restored_module.value.objective == solution.objective
        @test deserialize(Vector{UInt8}(codeunits(serialize(restored_module).text))).value.branch_closed == closed
        document["value"]["data"]["branch_closed"][3] = true
        @test_throws PowerIOError deserialize(Vector{UInt8}(codeunits(JSON3.write(document))))

        # C handles, rather than Julia parent wrappers, root snapshots.
        child = solution.instance
        retained_network = solution.network
        PowerIO.release!(getfield(solution, :handle))
        PowerIO.release!(getfield(instance, :handle))
        PowerIO.release!(PowerIO._handle(m))
        PowerIO.release!(PowerIO._handle(defaults))
        PowerIO.release!(PowerIO._handle(ac_module))
        GC.gc()
        @test child.initial_closed == [i != 2 for i in 1:9]
        @test child.options.max_open == 1
        @test length(retained_network.branches) == 9
        @test !retained_network.branches[2].in_service
        @test [b.in_service for b in materialized.value.branches] == closed
    end
end
