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
| `to_mc_ac_pf_instance`, `to_mc_ac_opf_instance` | `McAcPfInstance`, `McAcOpfInstance` over a `MulticonductorNetwork` |

A solution answers an instance. `solution.instance` is that instance,
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
AcScucInstance
DcPfSolution
AcPfSolution
DcOpfSolution
AcOpfSolution
SocwrOpfSolution
McAcPfSolution
McAcOpfSolution
AcScucSolution
time_count
to_dc_pf_instance
to_ac_pf_instance
to_dc_opf_instance
to_ac_opf_instance
to_mc_ac_pf_instance
to_mc_ac_opf_instance
```
