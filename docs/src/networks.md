# Networks

A [`BalancedNetwork`](@ref) is a positive sequence network. Its tables and
scalars are properties.

```julia
net = parse("case118.m").value

net.name                       # "case118"
net.base_mva                   # 100.0
net.base_frequency             # 60.0

net.buses                      # 118-element Elements{Bus}
net.branches                   # Elements{Branch}
net.generators                 # Elements{Generator}
net.loads                      # Elements{Load}
net.shunts                     # Elements{Shunt}
net.static_var_compensators
net.storage
net.switches
net.hvdc
net.transformers_3w            # Elements{ThreeWindingTransformer}
net.areas
```

Each table is an [`Elements`](@ref) vector: `length`, 1-based indexing,
iteration, `filter`, `collect`, and broadcasting work as on any Julia vector.
Every index reads one element from the C library and returns an immutable
struct, so `collect(net.buses)` materializes a table once when it will be read
many times.

```julia
length(net.buses)
net.buses[1].vm_pu
[b.id for b in net.buses if b.bus_type == "REF"]
filter(br -> br.in_service && br.tap_ratio != 0, net.branches)
sum(g.active_power_max_mw for g in net.generators)
```

## Element structs

Field names follow the C view names in `powerio.h`, with units in the name:
`vm_pu`, `va_degrees`, `base_kv`, `resistance_pu`, `active_power_mw`,
`reactive_power_mvar`. An optional field is `nothing` when the source does not
state it.

- [`Bus`](@ref): `id` (the source bus number), `bus_type` (`"PQ"`, `"PV"`,
  `"REF"`, `"ISOLATED"`), voltage and limits, `area`, `zone`, `name`,
  `location`.
- [`Branch`](@ref): `from_bus_id`, `to_bus_id`, series impedance, total and
  per terminal charging, ratings A, B, C and further named `ratings`,
  `tap_ratio` (the source value; 0 means 1) and `effective_tap_ratio`,
  `phase_shift_degrees`, angle limits, `in_service`, transformer `control`,
  geographic `route`.
- [`Generator`](@ref): dispatch, limits, `voltage_setpoint_pu`,
  `machine_base_mva`, `cost`, `regulated_bus_id`, `capabilities`,
  `active_power_control`.
- [`Load`](@ref) and [`Shunt`](@ref): one row per element at `bus_id`; several
  can share a bus. `Shunt.control` carries switched shunt blocks.
- [`StaticVarCompensator`](@ref), [`Storage`](@ref), [`Switch`](@ref),
  [`Hvdc`](@ref), [`ThreeWindingTransformer`](@ref) (with `windings` and
  pairwise `impedances`), [`Area`](@ref).

Bus references in every table are source bus ids, not positions. Build the map
once when positions are needed:

```julia
row = Dict(b.id => k for (k, b) in enumerate(net.buses))
from = [row[br.from_bus_id] for br in net.branches]
```

An element's `component_id` is its local identity; `ComponentId("load",
load.component_id)` names it in an [update](updates.md).

## Dense tables

[`to_dense`](@ref) returns the tables as dense arrays for code that wants
columns: `bus_ids`, per branch `from`, `to`, `r`, `x`, `b`, `tap`, `shift`,
per generator `pg`, `pmax`, and per bus demand and shunt sums.
[`to_graph`](@ref) returns the bus graph as `buses` and `edges`.
[`reference_bus_ids`](@ref) lists the `"REF"` buses.

## Detailed connectivity

Node breaker formats (XIIDM, CGMES) carry substations, voltage levels,
terminals, switches, and operational limits beyond the bus branch tables.
`net.detailed_connectivity` is `nothing` for a bus branch source and a
[`DetailedConnectivity`](@ref) otherwise; its `counts` property lists the
table lengths. The typed tables are not bound in this release.

```@docs
BalancedNetwork
Elements
Bus
Branch
Generator
Load
Shunt
StaticVarCompensator
Storage
Switch
Hvdc
ThreeWindingTransformer
Area
Location
Geo
ComponentId
TerminalReference
LoadVoltageModel
ShuntBlock
ShuntControl
TransformerControl
BranchRating
GeneratorCost
GeneratorCapability
ActivePowerControl
HvdcConverter
TransformerWinding
TransformerImpedance
DetailedConnectivity
reference_bus_ids
to_dense
to_graph
```
