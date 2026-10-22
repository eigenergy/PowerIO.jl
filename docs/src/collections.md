# Collections and instances

## Time series and scenario sets

A PyPSA folder with several snapshots parses into a
[`TimeSeries`](@ref)`{BalancedNetwork}`; a GridFM dataset parses into a
[`ScenarioSet`](@ref)`{BalancedNetwork}`. Both hold typed values and follow
Julia's collection conventions, a `TimeSeries` indexed by position and a
`ScenarioSet` by string key.

```julia
series = parse("pypsa_folder/").value    # TimeSeries{BalancedNetwork}
length(series)
series[1]                                # BalancedNetwork, 1-based
for net in series
    sum(l.p_mw for l in net.loads)
end

scenarios = parse("gridfm_case14/").value  # ScenarioSet{BalancedNetwork}
keys(scenarios)                            # ["0", "1", ...]
scenarios["0"]                             # BalancedNetwork
haskey(scenarios, "7")
for (id, net) in scenarios
    println(id, ": ", length(net.buses), " buses")
end
```

Reading an entry does not copy the network. An [`OperatingPoint`](@ref) has a
`network` property.

## Calculation instances and solutions

A calculation instance pairs a network with the specification of one
calculation, and `instance.network` gives you that network back. You construct
one from a network module:

```julia
case = parse("case9.m")
opf = to_dc_opf_instance(case)           # PioModule{DcOpfInstance}
opf.value.network                        # the BalancedNetwork
opf.history[1].name                      # "to_dc_opf_instance"
emit(opf, "matpower")                    # writes the network; diagnoses the rest
serialize(opf, "case9_dcopf.pio.json")
```

| Constructor | Result |
|---|---|
| `to_dc_pf_instance`, `to_ac_pf_instance` | `DcPfInstance`, `AcPfInstance` |
| `to_dc_opf_instance`, `to_ac_opf_instance` | `DcOpfInstance`, `AcOpfInstance` |
| `to_ac_ots_instance` | `AcOtsInstance` over the complete physical branch table |
| `to_mc_ac_pf_instance`, `to_mc_ac_opf_instance` | `McAcPfInstance`, `McAcOpfInstance` over a `MulticonductorNetwork` |
| `to_lindist3flow_opf_instance` | `LinDist3FlowOpfInstance` over a radial `MulticonductorNetwork` |

`McAcPfInstance.source_boundaries` is a lazy vector of `VoltageSource` records.
Each row supplies the source bus, phase terminals, phasors and optional
`reference_terminal`; a named reference is the other voltage endpoint on
that bus and does not imply grounding. The vector retains its instance owner.

A `LinDist3FlowOpfInstance` uses fixed reference phasors and lossless,
linearized voltage drops. Its `metadata` property returns owned node and
conductor identities, root nodes, and reference voltages in volts and radians.
Conductor records identify parent and child terminals, reversal relative to
the source line, and source line rows and conductor positions using Julia's
1-based indexing. Positive line power flows from parent to child.

`LinDist3FlowOpfSolution` quantities include `terminal_voltage_squared` in
squared volts, and `line_active_power`, `line_reactive_power`,
`source_active_power`, `source_reactive_power`, `generator_active_power`, and
`generator_reactive_power` in watts and vars. Each vector follows its instance
axes. These types use PowerIO IR generation 2 with distinct structural type
names. Readers without LinDist3Flow support reject those types; existing types
retain their representation.

A solution answers an instance. `solution.instance` is that instance,
`solution.network` is the network the solution is defined over,
`solution.termination` is the solver status (`"converged"`, `"iteration_limit"`,
`"infeasible"`, `"unbounded"`, `"failed"`, `"not_reported"`), and
`solution.objective` is the reported objective or `nothing`. You read a named
quantity by indexing with its name and get one `Vector{Float64}` in table
order:

```julia
solution = parse("example_0.json").value  # AcOpfSolution from OPFData
solution.instance.network
solution["bus_voltage_magnitude"]
solution["bus_voltage_angle"]
solution["generator_active_power"]
solution["branch_from_active_flow"]

scuc = parse("scenario_002/").value       # AcScucSolution from a GO Challenge 3 pair
time_count(scuc)
scuc["bus_voltage_magnitude", 1]          # time position 1
```

An unknown quantity name throws [`PowerIOError`](@ref) with code
`REQUEST.CAPI.QUANTITY_UNKNOWN`. A [`SocwrOpfSolution`](@ref) comes from a
second order cone relaxation of an AC OPF instance, so it reports an
`objective_lower_bound` and is not an AC feasible point.

## AC optimal transmission switching

AC OTS values retain every physical branch and its immutable initial status.
The default conversion selects initially in-service branches. Explicit options
can select `:all` (including initially open branches), `:none`, or a list of
stable identities:

```julia
case = parse("case9.m")
ots = to_ac_ots_instance(case)
ids = ots.value.branch_order
options = AcOtsOptions(
    switchable=BranchSelection(:all),
    switching_costs=[BranchSwitchingCost(ids[2], 2.0, 7.0)],
    max_open=1, max_switched=1,
)
ots = to_ac_ots_instance(ots; options)
initial = ots.value.initial_closed
ots.value.branches[2]             # lazy typed branch settings and current bounds
switching_cost(ots.value, initial)
fixed = fix_topology(ots.value, initial)  # PioModule{AcOpfInstance}
fixed.diagnostics                # switching/current policy losses are explicit
```

`max_open` counts every final-open physical branch, including fixed-open rows.
`max_switched` counts differences from initial status. `islanding=:forbidden`
requires global final AC connectivity. `:allowed` retains every load and chooses
one deterministic zero-angle reference per final island; it does not imply
load shedding or certify dispatch feasibility.

Current limits are independent from MVA constraints. `:stated` uses explicit
`BranchCurrentLimit(id, from_pu, to_pu)` records. Each terminal uses per unit on
system MVA and its own nominal voltage base; `nothing` is unbounded. Legacy
source-unit current ratings are not converted implicitly. `:derive_from_rate_a`
uses active thermal and voltage limits to derive necessary current bounds, not
equivalent MVA constraints.

`to_ac_ots_instance(module; options)` selects the switching objective term once.
The lower-level `AcOtsInstance(base::AcOpfInstance, options)` constructor preserves
the base objective exactly. Opening and closing costs apply only to transitions;
unchanged branches cost zero.

Attach an externally computed fixed-topology `AcOpfSolution` with
`AcOtsSolution(instance, branch_closed, ac_solution)`. Typed properties include
`branch_closed`, `branches_open`, `branches_switched`, and `switching_cost`, in
addition to the generic solution properties and named AC quantity vectors.
Construction checks exact fixed-instance correspondence, finite values and zero
open-branch flows, but not power-flow residuals or optimality. `solution.network`
is the original candidate-complete network. Use
`materialize_ac_ots_solution(solution)` to obtain a separate network module with
final statuses, solved voltages, dispatch and branch flows before grid emission.

Typed access is owner-rooted and does not serialize the value. Branch metadata is
indexed once per C handle, so a complete table traversal is not quadratic.
No solver, big-M formulation, DC OTS type, SCUC period projection, or GO Challenge
3 solution writer is provided by this API.

```@docs
AcOtsInstance
AcOtsSolution
AcOtsOptions
BranchSelection
BranchSwitchingCost
BranchCurrentLimit
to_ac_ots_instance
validate_topology
switching_cost
fix_topology
materialize_ac_ots_solution
```

## AC SCUC inputs

An [`AcScucInstance`](@ref) also carries the scheduling data of the unit
commitment problem. `instance.inputs` reads it into a [`ScucInputs`](@ref)
record: the collection sizes, the interval durations in hours, the input
tables, and the instance wide violation costs. Times are hours, powers and
energies per unit, and phase shifts radians.

```julia
instance = parse("goc3_small.json").value   # AcScucInstance
inputs = instance.inputs
inputs.dimensions.period_count              # 2
inputs.interval_durations                   # [1.0, 1.0] hours

device = inputs.devices[1]                  # ScucDevice
device.id                                   # ComponentId("generator", "sd_00")
device.kind                                 # "producer"
device.minimum_up_time_hours
device.periods[1].active_power_max_pu       # bounds in interval 1
device.periods[1].energy_cost_blocks        # the piecewise energy price

inputs.active_reserve_zones[1].buses        # Vector{ComponentId}
inputs.contingencies[1].components          # what the contingency takes out
inputs.violation_costs.active_power_balance
```

Every table is a plain `Vector`, so `filter`, `map`, and indexing all work, and
a lookup by source identity is a `Dict` over the table:

```julia
by_uid = Dict(d.id.local_id => d for d in inputs.devices)
by_uid["sd_00"].startup_cost
```

A device's [`ScucReactiveCapability`](@ref) states how its reactive range
depends on its active power. `kind` selects which fields the input sets:
`"none"` leaves all of them `nothing`, `"linear"` sets the intercept and
`slope`, and `"bounded"` sets the two intercept bounds and the two slope
bounds. The same reading is available through the instance a solution answers,
as `solution.instance.inputs`.

```@docs
ScucInputs
ScucDevice
ScucDevicePeriod
ScucEnergyCostBlock
ScucReserveCosts
ScucRampLimits
ScucReserveLimits
ScucInitialCommitment
ScucReactiveCapability
ScucStartupCostAdjustment
ScucStartupLimit
ScucEnergyRequirement
ScucShunt
ScucBranchSwitchingCost
ScucTransformerControl
ScucActiveReserveZone
ScucReactiveReserveZone
ScucContingency
ScucViolationCosts
```

```@docs
TimeSeries
ScenarioSet
OperatingPoint
DcPfInstance
AcPfInstance
DcOpfInstance
AcOpfInstance
McAcPfInstance
McAcOpfInstance
LinDist3FlowOpfInstance
AcScucInstance
DcPfSolution
AcPfSolution
DcOpfSolution
AcOpfSolution
SocwrOpfSolution
McAcPfSolution
McAcOpfSolution
LinDist3FlowOpfSolution
AcScucSolution
time_count
to_dc_pf_instance
to_ac_pf_instance
to_dc_opf_instance
to_ac_opf_instance
to_mc_ac_pf_instance
to_mc_ac_opf_instance
to_lindist3flow_opf_instance
```
