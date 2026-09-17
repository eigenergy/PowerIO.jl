# Detailed connectivity

Node breaker formats such as XIIDM and CGMES describe a network through
substations, voltage levels, connectivity nodes, terminals, and switches. The
bus branch tables on [`BalancedNetwork`](@ref) are the solved view of that
description. [`DetailedConnectivity`](@ref) keeps the description itself, so a
reader can see which terminal of which equipment attached to which node, and a
writer can emit the source structure back.

`net.detailed_connectivity` is `nothing` for a bus branch source such as
MATPOWER, and a `DetailedConnectivity` for a source that carries the detail.

```julia
net = parse("grid.xiidm").value
details = net.detailed_connectivity

details.counts                      # a NamedTuple of all 28 table lengths
details.counts.voltage_levels       # 3
length(details.terminals)           # 3
details.substations[1].country      # "US"
```

Each table is an [`Elements`](@ref) vector, exactly like a balanced network
table: `length`, 1-based indexing, iteration, `filter`, `collect`, and
broadcasting work, and every index reads one row from the C library and
returns an immutable record.

```julia
[l.nominal_voltage_kv for l in details.voltage_levels]
filter(t -> t.connected, details.terminals)
collect(details.switches)
```

## The tables

`propertynames(details)` is `:counts` followed by the 28 tables in the order
`details.counts` reports them.

| Table | Record | Holds |
| --- | --- | --- |
| `omitted_fields` | [`OmittedField`](@ref) | fields the source left unstated |
| `component_metadata` | [`ComponentMetadata`](@ref) | names, aliases, external identifiers, properties |
| `subnetworks` | [`Subnetwork`](@ref) | the parts of a merged network |
| `substations` | [`Substation`](@ref) | country, operator, geographical tags |
| `voltage_levels` | [`VoltageLevel`](@ref) | nominal voltage, limits, topology kind |
| `bus_breaker_buses` | [`BusBreakerBus`](@ref) | configured buses of bus breaker levels |
| `calculated_buses` | [`CalculatedBus`](@ref) | buses the source computed from closed switches |
| `connectivity_nodes` | [`ConnectivityNode`](@ref) | nodes of node breaker levels |
| `busbar_sections` | [`BusbarSection`](@ref) | busbar sections at nodes |
| `junctions` | [`Junction`](@ref) | CIM junctions |
| `terminals` | [`DetailedTerminal`](@ref) | AC terminals of equipment |
| `switches` | [`TopologySwitch`](@ref) | node breaker switches |
| `internal_connections` | [`InternalConnection`](@ref) | permanent node to node links |
| `operational_limit_groups` | [`OperationalLimitGroup`](@ref) | current, active power, apparent power limits |
| `tap_changers` | [`TapChanger`](@ref) | transformer tap changers and their steps |
| `equipment_reactive_limits` | [`EquipmentReactiveLimits`](@ref) | reactive limits beyond the balanced bounds |
| `boundary_lines` | [`BoundaryLine`](@ref) | half lines ending at a boundary |
| `tie_lines` | [`TieLine`](@ref) | pairings of two boundary lines |
| `dc_converter_units` | [`DcConverterUnit`](@ref) | converter groupings |
| `dc_topological_nodes`, `dc_nodes` | [`DcNode`](@ref) | the DC topology |
| `dc_grounds`, `dc_busbars`, `dc_lines`, `dc_series_devices`, `dc_switches` | [`DcEquipment`](@ref) | DC equipment |
| `voltage_source_converters`, `line_commutated_converters` | [`AcDcConverter`](@ref) | AC/DC converter stations |

## One record per view

The C ABI fills one view struct for each group of related tables, and the
Julia records follow it, so several tables share a record type. Python's
`DetailedConnectivity` splits the same rows across one dictionary type per
table.

- [`DcEquipment`](@ref) serves `dc_grounds`, `dc_busbars`, `dc_lines`,
  `dc_series_devices`, and `dc_switches`. Its `kind` names the table the row
  came from, and only the fields that kind uses are filled: a line states
  `resistance_ohm`, a switch states `switch_kind` and `open`.
- [`DcNode`](@ref) serves `dc_topological_nodes` and `dc_nodes`, with `kind`
  distinguishing a calculated topological node from a physical one.
- [`AcDcConverter`](@ref) serves `voltage_source_converters` and
  `line_commutated_converters`, with `kind` naming the technology. A voltage
  source converter states `voltage_setpoint_kv` and `reactive_limits`, a line
  commutated converter the alpha and gamma firing angles. The C ABI reads
  reactive limit properties and capability points for voltage source
  converters only, so a line commutated converter's `reactive_limits` carries
  its `kind` and bounds with empty `properties` and `points`.

```julia
details.dc_lines[1].kind              # "line"
details.dc_lines[1].terminals[1].dc_node
details.voltage_source_converters[1].kind   # "voltage_source"
```

## Nested tables

Rows the C ABI reads through a second accessor are materialized into the
record, so one row is a complete value: a [`Substation`](@ref) carries its
`geographical_tags`, a [`TapChanger`](@ref) its `steps`, a
[`ReactiveLimits`](@ref) its `points`, an [`AcDcConverter`](@ref) its
`droop_curve`.

```julia
group = details.operational_limit_groups[1]
group.apparent_power_limits.permanent_limit          # 90.0
group.apparent_power_limits.temporary_limits[1].name # "emergency"

changer = details.tap_changers[1]
changer.winding                                      # 2
changer.steps[1].ratio_pu                            # 1.05

limits = details.equipment_reactive_limits[1].limits
limits.kind                                          # "capability_curve"
limits.points[1].maximum_reactive_power_mvar
```

An optional field is `nothing` when the source does not state it, so a tap
changer whose source declares steps without assigning one has
`tap_position === nothing` while `low_tap_position` still reads. An
[`AcDcConverter`](@ref) distinguishes an absent droop curve (`nothing`) from
an empty one (an empty vector).

[`TopologySwitch`](@ref) is the node breaker switch of this table.
[`Switch`](@ref) remains the balanced transmission switch between two buses.

```@docs
OmittedField
ComponentMetadata
ComponentAlias
ExternalIdentifier
Subnetwork
CaseMetadata
Substation
VoltageLevel
BusBreakerBus
CalculatedBus
ConnectivityNode
BusbarSection
Junction
DetailedTerminal
TopologySwitch
TopologyEndpoint
InternalConnection
OperationalLimitGroup
LoadingLimits
TemporaryLimit
TapChanger
TapChangerStep
EquipmentReactiveLimits
ReactiveLimits
ReactiveCapabilityCurvePoint
BoundaryLine
BoundaryLineGeneration
TieLine
DcConverterUnit
DcNode
DcEquipment
DcTerminal
AcDcConverter
DroopCurveSegment
```
