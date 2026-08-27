# Ecosystem interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | [`to_powermodels`](@ref) / [`from_powermodels`](@ref) |
| BMOPFTools.jl | both | PowerIO backed OpenDSS / BMOPF conversion |
| ExaModelsPower.jl / ExaPowerIO.jl | out | [`to_powerdata`](@ref) / [`parse_ac_power_data`](@ref) |
| PowerGridPlanning.jl | out | [`to_powermodels`](@ref), `PowerIO.build_ref`, and angle repair helpers |
| `.pio.json` stored modules | in | [`PowerIO.parse`](@ref) / [`parse_module_bytes`](@ref) / [`as_network`](@ref) |
| GridFM (gridfm-datakit Parquet) | in | [`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| OpenDSS / PMD / IEEE BMOPF | both | format-routed `PowerIO.parse` / `to_format`; see [Distribution networks](distribution.md) |

## PowerModels.jl

[`to_powermodels`](@ref) converts a parsed network to a PowerModels network
data dictionary — the post-parse `Dict{String,Any}` layout PowerModels.jl
consumes. [`from_powermodels`](@ref) reads one back.

```julia
net = PowerIO.parse("case14.m"; value_type=BalancedNetwork)
data = to_powermodels(net)      # Dict{String,Any} with "bus", "branch", "gen", ...
net2 = from_powermodels(data)
```

PowerIO also exposes the reference dict helpers that several PowerModels style
packages need:

```julia
data = to_powermodels(PowerIO.parse("case14.m"; value_type=BalancedNetwork))
PowerIO.correct_voltage_angle_differences!(data)
ref = PowerIO.build_ref(data)
```

## BMOPFTools.jl

BMOPFTools uses the distribution side for OpenDSS and BMOPF exchange. Keep
PowerIO at 0.6.1 or newer when relying on transformer neutral impedance,
core shunt/leakage fields, n-winding transformer data, and generator handling.

```julia
using BMOPFTools

net = BMOPFTools.from_dss("Master.dss")
BMOPFTools.to_dss(net, "out/")
```

## ExaModelsPower.jl

[`to_powerdata`](@ref) returns a NamedTuple in ExaPowerIO's `PowerData`
layout; [`parse_ac_power_data`](@ref) returns the NamedTuple-of-arrays layout
consumed by ExaModelsPower's `build_polar_opf`, `build_rect_opf`, and
`build_dcopf` — GPU-ready struct-of-arrays with per unit conversion applied.

```julia
pd = to_powerdata("case14.m")
ac = parse_ac_power_data("case14.m")
ac.bus, ac.gen, ac.branch, ac.arc, ac.ref_buses
```

ExaModelsPower can use that parser path directly and keep ExaPowerIO for test
data artifacts:

```julia
using ExaModelsPower

model, vars, cons = ExaModelsPower.ac_opf_model("case14.m")
model, vars, cons = ExaModelsPower.dcopf_model("case.raw")
```

## PowerGridPlanning.jl

PowerGridPlanning can preserve its `load_network` API while delegating parser
semantics, PowerModels reference construction, and branch angle repair to
PowerIO.

```julia
using PowerGridPlanning

network = PowerGridPlanning.load_network("case14.m")
data = PowerIO.to_powermodels(PowerIO.parse("case14.m"; value_type=PowerIO.BalancedNetwork))
ref = PowerIO.build_ref(data)
```

## `.pio.json` stored modules

A `.pio.json` document is a stored module: a typed value with provenance,
validation, and diagnostics. [`PowerIO.parse`](@ref) reads one from a path or
bytes ([`parse_module_bytes`](@ref) is the explicit byte entry), and
[`as_network`](@ref) / [`as_dist_network`](@ref) open the live handle for a
network-valued module.

```julia
m = PowerIO.parse("case14.pio.json")
module_kind(m)                           # "balanced_network"
net = as_network(m)                      # live BalancedNetwork
```

## GridFM

[`read_gridfm`](@ref) reads a gridfm-datakit Parquet dataset back into a
`BalancedNetwork` — the ML to classical return leg (needs `--features
gridfm`; [`gridfm_available`](@ref) reports it). The read is lossy but
complete enough for power flow; what the schema can't round trip comes back
in `warnings`.

```julia
r = read_gridfm("out/case14/raw")                # (; network, scenario, warnings)
to_matpower(r.network)                           # gridfm -> any classical format
reads = read_gridfm_scenarios("out/case14/raw")  # one result per scenario id
```

