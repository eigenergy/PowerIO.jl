# Ecosystem interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | [`to_powermodels`](@ref) / [`from_powermodels`](@ref) |
| BMOPFTools.jl | both | PowerIO backed OpenDSS / BMOPF conversion |
| ExaModelsPower.jl / ExaPowerIO.jl | out | [`to_powerdata`](@ref) / [`parse_ac_power_data`](@ref) |
| PowerGridPlanning.jl | out | [`to_powermodels`](@ref), `PowerIO.build_ref`, and angle repair helpers |
| stored `.pio.json` module | both | [`parse_file`](@ref) / [`write_json`](@ref) / `m.value` |
| GridFM (gridfm-datakit Parquet) | in | [`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| OpenDSS / PMD / IEEE BMOPF | both | [`parse_file`](@ref) / `to_format`; see [Distribution networks](distribution.md) |

## PowerModels.jl

[`to_powermodels`](@ref) converts a parsed network to a PowerModels network
data dictionary — the post-parse `Dict{String,Any}` layout PowerModels.jl
consumes. [`from_powermodels`](@ref) reads one back.

```julia
net = parse_file("case14.m").value
data = to_powermodels(net)      # Dict{String,Any} with "bus", "branch", "gen", ...
net2 = from_powermodels(data)
```

PowerIO also exposes the reference dict helpers that several PowerModels style
packages need:

```julia
data = to_powermodels(parse_file("case14.m").value)
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
data = PowerIO.to_powermodels(PowerIO.parse_file("case14.m").value)
ref = PowerIO.build_ref(data)
```

## `.pio.json` stored modules

Stored `.pio.json` modules carry one typed value beside the module's records
(sources, source maps, diagnostics, history), over the native `pio_module_*`
C ABI surface.

```julia
m = parse_file("case14.m")               # ::PioModule{BalancedNetwork}
doc = write_json(m)                      # the stored version 1 document
net = parse_bytes(codeunits(doc); name="case.pio.json").value

kind(m)                                  # "balanced_network"
diagnostics(m)                           # structured diagnostic records
history(m)                               # descriptive history entries
sources(m)                               # source descriptors
```

A released 0.9 document upgrades one way on read; a nonempty legacy study is
refused with the materialize instruction. Multiconductor modules preflight
and lower explicitly; see [Distribution networks](distribution.md).

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

