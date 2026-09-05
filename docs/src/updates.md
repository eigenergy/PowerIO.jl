# Updates

Typed updates change a module in place. Each update names a component by
[`ComponentId`](@ref) and gives an absolute value with an explicit unit. You
apply updates as a batch, and the batch is validated as a whole before
anything changes.

```julia
case = parse("case9.m")
load = ComponentId("load", case.value.loads[1].component_id)   # "bus-5"

report = apply_updates!(case, [
    set_load_active_power(load, ActivePower(megawatts=91.5)),
    set_load_reactive_power(load, ReactivePower(megavars=31.0)),
])

report.connectivity_changed        # false
report.changes[1].component_id     # ComponentId("load", "bus-5")
report.changes[1].field            # "load_active_power"
case.value.loads[1].p_mw           # 91.5
```

The quantity types [`ActivePower`](@ref), [`ReactivePower`](@ref), and
[`ApparentPower`](@ref) take exactly one unit keyword: `ActivePower(watts=...)`
or `ActivePower(megawatts=...)`, `ReactivePower(vars=...)` or
`ReactivePower(megavars=...)`, `ApparentPower(volt_amperes=...)` or
`ApparentPower(megavolt_amperes=...)`.

## Update constructors

Operating point updates:

| Function | Field changed |
|---|---|
| [`set_load_active_power`](@ref), [`set_load_reactive_power`](@ref) | a load's demand |
| [`set_generator_active_power`](@ref), [`set_generator_reactive_power`](@ref) | a generator's dispatch |
| [`set_generator_voltage_magnitude`](@ref) | a generator's voltage setpoint, per unit |
| [`set_generator_in_service`](@ref), [`set_branch_in_service`](@ref) | service status |
| [`set_transformer_tap_ratio`](@ref), [`set_transformer_phase_shift_degrees`](@ref) | a transformer branch |
| [`set_switch_closed`](@ref) | a switch position |

The network update is [`set_branch_thermal_rating`](@ref). The power setters
accept `terminal=` to address one terminal of a multiconductor element.

## Applying a batch

[`apply_updates!`](@ref) validates every update before changing anything, so a
batch with an unknown component or an invalid value throws
[`PowerIOError`](@ref) and leaves the module as it was. On success the module's
value is refreshed and `case.value` reflects the change; a `BalancedNetwork`
you obtained before the call keeps the data from before it. The returned
[`UpdateReport`](@ref) lists every [`UpdateChange`](@ref) and says whether a
service status or switch change altered the energized topology.

Component ids for MATPOWER sources follow the reader's convention: loads and
generators are `"bus-N"`, branches are `"F-T"`. Read the `component_id` field
of the element rather than assuming a convention.

```@docs
ActivePower
ReactivePower
ApparentPower
OperatingPointUpdate
NetworkUpdate
set_load_active_power
set_load_reactive_power
set_generator_active_power
set_generator_reactive_power
set_generator_voltage_magnitude
set_generator_in_service
set_branch_in_service
set_transformer_tap_ratio
set_transformer_phase_shift_degrees
set_switch_closed
set_branch_thermal_rating
apply_updates!
UpdateReport
UpdateChange
```
